# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "../steer"
require "securerandom"
require "time"
require "rack/utils"
require_relative "../atomic_file"
require_relative "../config"
require_relative "../log"
require_relative "../participant_name"
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
      NAME_MAX = ParticipantName::MAX
      ID_RE = /\Ap_[0-9a-f]{8}\z/
      # D7: what a participant's turns (and the side calls they cause) may
      # cost the owner, in dollars, unless chi share --cap says otherwise
      # (config web.participants.cap); at most MAX_CAP.
      DEFAULT_CAP = 2.0
      MAX_CAP = 1000.0
      # How many of a participant's turns may wait behind their running one
      # (config web.participants.queue); at most MAX_QUEUE.
      DEFAULT_QUEUE = 3
      MAX_QUEUE = 20
      # chi share --expires and config web.participants.expires: Nh or Nd.
      EXPIRES_RE = /\A(\d+)([hd])\z/

      # The store's folder or file can be read by others (chi web refuses to
      # start), or a grant can't be made from what was given.
      class Insecure < StandardError; end
      # Not ArgumentError: the session commands read that as "no such
      # session".
      class Invalid < StandardError; end

      # The store is there but doesn't read (not JSON, a grant without its
      # digest or expiry): its grants find nothing (fail closed), and
      # nothing writes over it, which would lose every other grant.
      class Corrupt < StandardError
        def initialize(path, reason)
          super("#{path} can't be read (#{reason}): chi won't write over it; fix it, or move it aside to end " \
                "every participant's link")
        end
      end

      # One participant's access to one session. +id+ (p_<8 hex>) names the
      # participant too: a turn they send is authored "p:<id>" (P3).
      # +revoked_by+ why it was revoked: "owner", "archive", "delete",
      # "gone" (the session was pruned).
      # +cap+ (dollars) and +queue+ (turns waiting) as issued; nil in a
      # grant from before them, which takes the config's (#spend_cap,
      # #queue_limit).
      Grant = Data.define(:id, :session_id, :digest, :kind, :name, :role, :created_at, :expires_at, :revoked_at,
                          :revoked_by, :last_used_at, :cap, :queue, :identity) do
        # identity: the proxy identity (an email, lower case) the grant is
        # bound to, nil for any (ProxyGate; issued from shared-sessions P6).
        def initialize(cap: nil, queue: nil, identity: nil, **) = super

        def self.from_h(hash)
          new(**members.to_h { |key| [key, hash[key.to_s]] })
        end

        # The dollars this participant may cost the owner.
        def spend_cap = cap.is_a?(Numeric) ? cap.to_f : Grants.default_cap

        # How many of their turns may wait behind their running one.
        def queue_limit = queue.is_a?(Integer) ? queue : Grants.default_queue

        # The author a participant's turn carries (Principal#author).
        def author = Steer.author_for(id)

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
            state: state(now).to_s, cap: spend_cap, queue: queue_limit }
        end

        # A grant bound to no identity is stored as before identity existed.
        def to_store = to_h.transform_keys(&:to_s).tap { |hash| hash.delete("identity") if identity.nil? }

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

      # Seconds for +words+ (Nh or Nd, 1 hour to MAX_TTL), nil for none,
      # false for words that aren't that.
      def self.parse_ttl(words)
        return nil if words.nil?

        match = EXPIRES_RE.match(words.to_s.strip) or return false
        seconds = match[1].to_i * (match[2] == "h" ? 3600 : DAY)
        seconds.between?(3600, MAX_TTL) ? seconds : false
      end

      # A new grant's lifetime: config web.participants.expires, else
      # DEFAULT_TTL (a value that isn't Nh/Nd in range too).
      def self.default_ttl
        parse_ttl(Config.get("web.participants.expires")) || DEFAULT_TTL
      end

      # A grant's cap without its own: config web.participants.cap, else
      # DEFAULT_CAP (a value out of range too).
      def self.default_cap
        value = Config.get("web.participants.cap")
        cap?(value) ? value.to_f : DEFAULT_CAP
      end

      # A grant's queue limit without its own: config
      # web.participants.queue, else DEFAULT_QUEUE.
      def self.default_queue
        value = Config.get("web.participants.queue")
        value.is_a?(Integer) && value.between?(0, MAX_QUEUE) ? value : DEFAULT_QUEUE
      end

      def self.cap?(value) = value.is_a?(Numeric) && value.to_f.finite? && value.to_f.between?(0, MAX_CAP)

      def self.token?(value) = value.is_a?(String) && value.start_with?(PREFIX)

      # One line, at most NAME_MAX characters, no brackets (a name can't
      # forge the "[Review contribution from …]" header; ParticipantName).
      # @raise [Invalid] nothing left
      def self.clean_name(name)
        clean = ParticipantName.clean(name)
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
        @corrupt = nil
        @touched = {}
      end

      def now = @clock.call

      # A new grant for +session_id+, written before the token is handed out.
      # @param ttl [Integer, nil] seconds (nil: Grants.default_ttl; at most MAX_TTL)
      # @param cap [Numeric, nil] dollars (nil: Grants.default_cap)
      # @param on_write [#call, nil] see #update
      # @return [Issued]
      # @raise [Invalid]
      def issue(session_id:, name:, kind: "human", role: "reviewer", ttl: nil, cap: nil, on_write: nil)
        Session.check_id!(session_id)
        ttl ||= Grants.default_ttl
        cap = Grants.default_cap if cap.nil?
        raise Invalid, "kind is human or agent, not #{kind}" unless KINDS.include?(kind)
        raise Invalid, "role is reviewer, not #{role}" unless ROLES.include?(role)
        raise Invalid, "a grant lasts 1 hour to 30 days" unless ttl.is_a?(Integer) && ttl.between?(3600, MAX_TTL)
        raise Invalid, CAP_RANGE unless Grants.cap?(cap)

        clean = Grants.clean_name(name)
        token = "#{PREFIX}#{SecureRandom.urlsafe_base64(BYTES)}"
        issued = now
        update(on_write) do |grants|
          id = fresh_id(grants)
          grant = Grant.new(id: id, session_id: session_id, digest: Grants.digest(token), kind: kind, name: clean,
                            role: role, created_at: stamp(issued), expires_at: stamp(issued + ttl), revoked_at: nil,
                            revoked_by: nil, last_used_at: nil, cap: cap.to_f, queue: Grants.default_queue)
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
      # @raise [Corrupt] (the owner's view: an empty list would hide it)
      def list(session_id: nil)
        current!.select { |grant| session_id.nil? || grant.session_id == session_id }
      end

      # Revokes the active grants of +session_id+ (just +id+ when given), or
      # every session's when +session_id+ is nil.
      # @param by [String] why: "owner", "archive", "delete", "gone"
      # @param on_write [#call, nil] see #update
      # @return [Array<Grant>] the grants it revoked (already ended ones are
      #   left as they were)
      def revoke(session_id: nil, id: nil, by: "owner", on_write: nil)
        at = now
        matches = lambda do |grant|
          grant.active?(at) && (session_id.nil? || grant.session_id == session_id) && (id.nil? || grant.id == id)
        end
        # Nothing to revoke (an archive of a session nobody was invited to):
        # no write, no store made.
        return [] unless current!.any?(&matches)

        update(on_write) do |grants|
          revoked = []
          grants = grants.map do |grant|
            next grant unless matches.call(grant)

            grant.with(revoked_at: stamp(at), revoked_by: by).tap { |ended| revoked << ended }
          end
          [grants, revoked]
        end
      end

      CAP_RANGE = "a cap is $0 to $#{MAX_CAP.to_i}".freeze

      # Sets the active grant +id+'s cap to +cap+ dollars.
      # @return [Grant, nil] the changed grant; nil when +id+ isn't an
      #   active grant (of +session_id+, when given)
      # @param on_write [#call, nil] see #update
      # @raise [Invalid] a cap out of range
      def set_cap(id, cap, session_id: nil, on_write: nil)
        raise Invalid, CAP_RANGE unless Grants.cap?(cap)

        at = now
        update(on_write) do |grants|
          changed = nil
          grants = grants.map do |grant|
            next grant unless grant.id == id && grant.active?(at) && (session_id.nil? || grant.session_id == session_id)

            changed = grant.with(cap: cap.to_f)
          end
          [grants, changed]
        end
      end

      # Records a use of grant +id+, at most once per TOUCH_INTERVAL; not
      # while the store doesn't read (it found no grant then anyway).
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
      rescue Corrupt
        nil
      end

      private

      # The grants on disk, re-read when the file changed (one stat a call);
      # none while it doesn't read (logged once per change of the file).
      def current
        stamp = begin
          stat = File.stat(@path)
          [stat.mtime, stat.size, stat.ino]
        rescue Errno::ENOENT
          nil
        end
        @mutex.synchronize do
          unless stamp == @stamp
            reload(stamp)
            @stamp = stamp
          end
          @grants
        end
      end

      # #current, raising Corrupt for a store that doesn't read.
      def current!
        grants = current
        corrupt = @mutex.synchronize { @corrupt }
        raise corrupt if corrupt

        grants
      end

      def reload(stamp)
        @grants = stamp ? read : []
        @corrupt = nil
      rescue Corrupt => e
        @grants = []
        @corrupt = e
        Log.warn(:web, "grants_unreadable", echo: "[chi web] #{e.message}", path: @path)
      end

      # @raise [Corrupt] the file is there but isn't a grants store
      def read
        data = begin
          JSON.parse(File.read(@path))
        rescue Errno::ENOENT
          return []
        rescue JSON::ParserError
          raise Corrupt.new(@path, "not JSON")
        end
        rows = data.is_a?(Hash) ? data["grants"] : nil
        raise Corrupt.new(@path, "no grants list") unless rows.is_a?(Array)

        rows.each_with_index.map { |hash, index| grant_from(hash, index) }
      end

      # A stored grant the gate can compare and date, else Corrupt.
      def grant_from(hash, index)
        raise Corrupt.new(@path, "grant #{index + 1} isn't an object") unless hash.is_a?(Hash)

        grant = Grant.from_h(hash)
        problem = if !grant.id.is_a?(String) || !grant.session_id.is_a?(String) then "no id or session"
                  elsif !grant.digest.is_a?(String) || grant.digest.empty? then "no digest"
                  elsif !time?(grant.expires_at) then "no expiry"
                  elsif !grant.revoked_at.nil? && !time?(grant.revoked_at) then "a bad revoked_at"
                  end
        raise Corrupt.new(@path, "grant #{index + 1} has #{problem}") if problem

        grant
      end

      def time?(value)
        value.is_a?(String) && Time.iso8601(value)
      rescue ArgumentError
        false
      end

      # Read, change and write the store under its lock (another process
      # may write it too). The block takes the grants and returns
      # [new grants, result]. Ended grants older than KEEP_ENDED go.
      # +on_write+ is called with (the grants written, result) once the store
      # is written, still under the lock: Participants writes the sidecars
      # there, so two writers can't finish out of order and lose a revoke in
      # one.
      def update(on_write = nil)
        dir = File.dirname(@path)
        FileUtils.mkdir_p(dir, mode: 0o700)
        File.chmod(0o700, dir)
        File.open(File.join(dir, LOCK), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          # Never over a store that didn't read (Corrupt): the next write
          # would keep only this one's change.
          grants, result = yield(read)
          at = now
          kept = grants.reject { |grant| (ended = grant.ended_at(at)) && at - ended > KEEP_ENDED }
          body = JSON.pretty_generate({ "version" => 1, "grants" => kept.map(&:to_store) })
          AtomicFile.write(@path, "#{body}\n", perm: 0o600)
          @mutex.synchronize { @stamp = nil }
          on_write&.call(kept, result)
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
