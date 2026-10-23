# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "rack/utils"
require_relative "../atomic_file"
require_relative "../session"
require_relative "../redacted_inspect"

module Samagotchi
  module Web
    # Participants' access to one session each (the shared-sessions plan,
    # security model §1): a grant binds one random token to one session, one
    # participant and one role, until it expires or is revoked. Only the
    # token's SHA-256 digest is kept, in
    # $XDG_STATE_HOME/samagotchi/web-grants/grants.json (0600, in its own 0700
    # folder): the token is shown once, when it is issued, and a leaked file
    # grants nothing. The owner's Web::Token is a different credential and
    # never touches this file. See docs/internals/participants.md.
    #
    # One object per process (chi web, a chi share run): writes take a lock
    # file next to the store, so the two never lose each other's grants; the
    # reads follow the file's mtime, as Token::Source does.
    class Grants
      include RedactedInspect

      DIR = "web-grants"
      FILE = "grants.json"
      LOCK = "grants.lock"
      # What a participant token starts with: the gate looks up only these,
      # and a leaked one is recognisable (an owner token never has it).
      PREFIX = "chp_"
      # 32 random bytes, as Web::Token's.
      BYTES = 32
      DAY = 86_400
      # D8: a grant lasts a week unless chi share --expires says otherwise,
      # and never more than MAX_TTL.
      DEFAULT_TTL = 7 * DAY
      MAX_TTL = 30 * DAY
      # Ended grants (revoked, expired) are kept this long, so their token
      # answers token_revoked / token_expired rather than a bare 401.
      KEEP_ENDED = 30 * DAY
      # last_used_at is written at most this often per grant.
      TOUCH_INTERVAL = 60
      KINDS = %w[human agent].freeze
      # The only role in v1: a reviewer reads and (P3) comments.
      ROLES = %w[reviewer].freeze
      NAME_MAX = 64
      ID_RE = /\Ap_[0-9a-f]{8}\z/

      # The store's folder or file can be read by others (chi web refuses to
      # start), or a grant can't be made from what was given.
      class Insecure < StandardError; end
      class Invalid < ArgumentError; end

      # One participant's access to one session. +id+ (p_<8 hex>) names the
      # participant too: a turn they send is authored "p:<id>" (P3).
      # +revoked_by+ why it was revoked: "owner", "archive", "delete",
      # "gone" (the session was pruned).
      Grant = Data.define(:id, :session_id, :digest, :kind, :name, :role, :created_at, :expires_at, :revoked_at,
                          :revoked_by, :last_used_at) do
        def self.from_h(hash)
          new(**members.to_h { |key| [key, hash[key.to_s]] })
        end

        # The author a participant's turn carries (Principal#author).
        def author = "p:#{id}"

        # :active, :revoked or :expired at +now+ (a Time).
        def state(now)
          return :revoked if revoked_at
          return :expired if Time.iso8601(expires_at) <= now

          :active
        end

        def active?(now) = state(now) == :active

        # When it stopped working (revoked or expired), nil while active.
        def ended_at(now)
          return Time.iso8601(revoked_at) if revoked_at

          expiry = Time.iso8601(expires_at)
          expiry <= now ? expiry : nil
        end

        # Never the digest: what chi share ls and the owner's routes show.
        def public_h(now)
          { id: id, session_id: session_id, kind: kind, name: name, role: role, created_at: created_at,
            expires_at: expires_at, revoked_at: revoked_at, revoked_by: revoked_by, last_used_at: last_used_at,
            state: state(now).to_s }
        end

        def to_store = to_h.transform_keys(&:to_s)

        def inspect = "#<Grant #{id} #{session_id[0, 8]} #{name.inspect}>"
        alias_method :to_s, :inspect
      end

      # A new grant and its token: the only time the token exists outside
      # the participant's hands.
      Issued = Data.define(:grant, :token) do
        def inspect = "#<Issued #{grant.id}>"
        alias_method :to_s, :inspect
      end

      # $XDG_STATE_HOME/samagotchi/web-grants/grants.json, next to web-token;
      # +state_dir+ is the sessions dir (Session.default_state_dir).
      def self.path(state_dir: nil, env: ENV)
        File.join(File.dirname(state_dir || Session.default_state_dir(env: env)), DIR, FILE)
      end

      def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

      def self.token?(value) = value.is_a?(String) && value.start_with?(PREFIX)

      # One line, at most NAME_MAX characters, no brackets (a name can't
      # forge P3's "[Review contribution from …]" header).
      # @raise [Invalid] nothing left
      def self.clean_name(name)
        clean = name.to_s.gsub(/[[:cntrl:]\[\]]/, " ").squeeze(" ").strip[0, NAME_MAX].to_s.strip
        raise Invalid, "a participant needs a name" if clean.empty?

        clean
      end

      # Refuses a store others could read: the grants folder must be 0700
      # and the file 0600, both this user's. Only these two: the state dir
      # above them is often 0755, and that is fine. A folder not made yet
      # passes (it is made 0700).
      # @raise [Insecure]
      def self.check_permissions!(path)
        [File.dirname(path), path].each do |target|
          stat = File.stat(target)
          next if stat.mode.nobits?(0o077) && stat.uid == Process.uid

          raise Insecure, "#{target} can be read by other users: chmod 700 #{File.dirname(path)} and 600 #{path} " \
                          "(it holds the participants' grants)"
        rescue Errno::ENOENT
          next
        end
      end

      attr_reader :path

      # @param clock [#call] the Time now (specs inject one)
      def initialize(path = Grants.path, clock: -> { Time.now })
        @path = path
        @clock = clock
        @mutex = Mutex.new
        @stamp = nil
        @grants = []
        @touched = {}
      end

      def now = @clock.call

      # A new grant for +session_id+, written before the token is handed out.
      # @param ttl [Integer] seconds (DEFAULT_TTL; at most MAX_TTL)
      # @return [Issued]
      # @raise [Invalid]
      def issue(session_id:, name:, kind: "human", role: "reviewer", ttl: DEFAULT_TTL)
        Session.check_id!(session_id)
        raise Invalid, "kind is human or agent, not #{kind}" unless KINDS.include?(kind)
        raise Invalid, "role is reviewer, not #{role}" unless ROLES.include?(role)
        raise Invalid, "a grant lasts 1 hour to 30 days" unless ttl.is_a?(Integer) && ttl.between?(3600, MAX_TTL)

        clean = Grants.clean_name(name)
        token = "#{PREFIX}#{SecureRandom.urlsafe_base64(BYTES)}"
        issued = now
        update do |grants|
          id = fresh_id(grants)
          grant = Grant.new(id: id, session_id: session_id, digest: Grants.digest(token), kind: kind, name: clean,
                            role: role, created_at: stamp(issued), expires_at: stamp(issued + ttl), revoked_at: nil,
                            revoked_by: nil, last_used_at: nil)
          [grants + [grant], Issued.new(grant: grant, token: token)]
        end
      end

      # The grant +token+ was issued for, in any state (an ended one too, so
      # the gate can say why it's refused); nil for anything else.
      # @return [Grant, nil]
      def lookup(token)
        return nil unless Grants.token?(token)

        digest = Grants.digest(token)
        # Every grant is compared, whatever matches first.
        current.select { |grant| Rack::Utils.secure_compare(grant.digest, digest) }.first
      end

      # @return [Grant, nil] the grant with this id
      def find(id) = current.find { |grant| grant.id == id }

      # Whether grant +id+ still works (a participant stream's running check).
      def active?(id) = !!find(id)&.active?(now)

      # @param session_id [String, nil] one session's, or every grant
      # @return [Array<Grant>]
      def list(session_id: nil)
        current.select { |grant| session_id.nil? || grant.session_id == session_id }
      end

      # Revokes the active grants of +session_id+ (just +id+ when given), or
      # every session's when +session_id+ is nil.
      # @param by [String] why: "owner", "archive", "delete", "gone"
      # @return [Array<Grant>] the grants it revoked (already ended ones are
      #   left as they were)
      def revoke(session_id: nil, id: nil, by: "owner")
        at = now
        update do |grants|
          revoked = []
          grants = grants.map do |grant|
            next grant unless grant.active?(at) && (session_id.nil? || grant.session_id == session_id) &&
                              (id.nil? || grant.id == id)

            grant.with(revoked_at: stamp(at), revoked_by: by).tap { |ended| revoked << ended }
          end
          [grants, revoked]
        end
      end

      # Records a use of grant +id+, at most once per TOUCH_INTERVAL.
      def touch(id)
        at = now
        @mutex.synchronize do
          last = @touched[id]
          return if last && at - last < TOUCH_INTERVAL

          @touched[id] = at
        end
        update do |grants|
          [grants.map { |grant| grant.id == id ? grant.with(last_used_at: stamp(at)) : grant }, nil]
        end
      end

      private

      # The grants on disk, re-read when the file changed (one stat a call).
      def current
        stamp = begin
          stat = File.stat(@path)
          [stat.mtime, stat.size, stat.ino]
        rescue Errno::ENOENT
          nil
        end
        @mutex.synchronize do
          unless stamp == @stamp
            @grants = stamp ? read : []
            @stamp = stamp
          end
          @grants
        end
      end

      def read
        data = JSON.parse(File.read(@path))
        Array(data.is_a?(Hash) ? data["grants"] : nil).filter_map { |hash| Grant.from_h(hash) if hash.is_a?(Hash) }
      rescue Errno::ENOENT, JSON::ParserError, ArgumentError
        []
      end

      # Read, change and write the store under its lock (another process
      # may write it too). The block takes the grants and returns
      # [new grants, result]. Ended grants older than KEEP_ENDED go.
      def update
        dir = File.dirname(@path)
        FileUtils.mkdir_p(dir, mode: 0o700)
        File.chmod(0o700, dir)
        File.open(File.join(dir, LOCK), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          grants, result = yield(read)
          at = now
          kept = grants.reject { |grant| (ended = grant.ended_at(at)) && at - ended > KEEP_ENDED }
          body = JSON.pretty_generate({ "version" => 1, "grants" => kept.map(&:to_store) })
          AtomicFile.write(@path, "#{body}\n", perm: 0o600)
          @mutex.synchronize { @stamp = nil }
          result
        end
      end

      def fresh_id(grants)
        loop do
          id = "p_#{SecureRandom.hex(4)}"
          return id unless grants.any? { |grant| grant.id == id }
        end
      end

      def stamp(time) = time.utc.iso8601
    end
  end
end
