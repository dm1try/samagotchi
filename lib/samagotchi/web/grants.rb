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
require_relative "private_files"
require_relative "participant_exposure"

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

      # An identity to bind a grant to that isn't one email address.
      class BadIdentity < Invalid
        def initialize(msg = "a link is bound to one email address (name@domain: one @, no spaces or commas, ASCII " \
                             "only)") = super
      end

      # An identity asked of a chi web that can't check one: no auth proxy
      # naming the signed-in user (ProxyGate), so the link would never open.
      class Unbindable < Invalid
        def initialize(msg = "a link can be bound to an email only on a chi web behind an auth proxy that names the " \
                             "signed-in user (web.public_url with web.proxy.identity_header, or chi web --tunnel " \
                             "tailscale): bound here it would never open") = super
      end

      # The store's version: 1, and BOUND_VERSION once a grant is bound to
      # an identity, so a chi that knows only 1 and checks (from this one
      # on) doesn't rewrite it. MAX_VERSION is the newest this chi reads
      # and writes; a newer store it reads but never writes (Newer).
      VERSION = 1
      BOUND_VERSION = 2
      MAX_VERSION = 2

      # A store chi won't write over (Corrupt, Newer): the owner's invite,
      # cap and revoke are refused with its message.
      class Unwritable < StandardError; end

      # The store is there but doesn't read (not JSON, a grant without its
      # digest or expiry): its grants find nothing (fail closed), and
      # nothing writes over it, which would lose every other grant.
      class Corrupt < Unwritable
        def initialize(path, reason)
          super("#{path} can't be read (#{reason}): chi won't write over it; fix it, or move it aside to end " \
                "every participant's link")
        end
      end

      # The store was written by a newer chi (its version above
      # MAX_VERSION): its grants still work here (read as this chi knows
      # them), but nothing writes over it, which would drop what that chi
      # added to them.
      class Newer < Unwritable
        def initialize(path, version)
          super("#{path} was written by a newer chi (grants store version #{version}; this chi knows up to " \
                "#{MAX_VERSION}): chi won't write over it, which would drop what that chi added; update chi " \
                "(chi update)")
        end
      end

      # One participant's access to one session. +id+ (p_<8 hex>) names the
      # participant too: a turn they send is authored "p:<id>" (P3).
      # +revoked_by+ why it was revoked: "owner", "archive", "delete",
      # "gone" (the session was pruned).
      # +cap+ (dollars) and +queue+ (turns waiting) as issued; nil in a
      # grant from before them, which takes the config's (#spend_cap,
      # #queue_limit).
      # +exposure+: what the participant learns of the review's usage
      # (ParticipantExposure; "own" for every grant today, and for one from
      # before it). Kept as stored: a level this chi doesn't know reads as
      # the narrowest, and is written back as it was.
      # +extra+: the stored keys this chi doesn't know (a newer chi's,
      # such as a field added to a grant without a version bump), written
      # back as they were, so a rewrite here never drops them.
      Grant = Data.define(:id, :session_id, :digest, :kind, :name, :role, :created_at, :expires_at, :revoked_at,
                          :revoked_by, :last_used_at, :cap, :queue, :identity, :exposure, :extra) do
        # identity: the proxy identity (an email, lower case) the grant is
        # bound to, nil for any (ProxyGate; issued from shared-sessions P6).
        def initialize(cap: nil, queue: nil, identity: nil, exposure: nil, extra: {}, **)
          super(cap: cap, queue: queue, identity: identity, extra: extra,
                exposure: exposure.nil? ? ParticipantExposure::DEFAULT : exposure, **)
        end

        def self.from_h(hash)
          known = members - [:extra]
          extra = hash.reject { |key, _| known.include?(key.to_s.to_sym) }
          new(**known.to_h { |key| [key, hash[key.to_s]] }, extra: extra)
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
            state: state(now).to_s, cap: spend_cap, queue: queue_limit, identity: identity }
        end

        # A grant bound to no identity, with the default exposure, is stored
        # as before either existed; the keys this chi doesn't know come
        # after, as they were.
        #
        # A non-default exposure needs no version bump (identity's
        # BOUND_VERSION): a chi that ignores it shows the participant the
        # narrowest level, so it fails closed, and one that knows Grant#extra
        # keeps it on a rewrite. A bump would only make that chi refuse the
        # owner's invite, cap and revoke (Newer) for no safety gain.
        def to_store
          hash = to_h.except(:extra).transform_keys(&:to_s)
          hash.delete("identity") if identity.nil?
          hash.delete("exposure") if exposure == ParticipantExposure::DEFAULT
          hash.merge(extra.reject { |key, _| hash.key?(key) })
        end

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

      # What a proxy identity header carries: an email, or a login such as
      # Tailscale's alex@github (one @, a domain without a dot).
      IDENTITY_RE = /\A[^@,<>"\\]+@[^@,<>"\\]+\z/
      # No space or control character anywhere (a header can't carry one,
      # and a name with one could mislead in a listing).
      IDENTITY_BAD_RE = /\p{Space}|\p{Cc}/
      IDENTITY_MAX = 254

      # +identity+ as the gate compares it (ProxyGate#proxy_identity: strip,
      # lower case).
      # @raise [BadIdentity] not one email address
      def self.clean_identity(identity)
        # ASCII only, as ProxyGate#proxy_identity: its lower case is the same
        # whatever the string's encoding.
        clean = identity.is_a?(String) && identity.ascii_only? ? identity.strip.downcase : ""
        raise BadIdentity unless clean.length <= IDENTITY_MAX && IDENTITY_RE.match?(clean) && !IDENTITY_BAD_RE.match?(clean)

        clean
      end

      # One line, at most NAME_MAX characters, no brackets (a name can't
      # forge the "[Review contribution from …]" header; ParticipantName).
      # @raise [Invalid] nothing left
      def self.clean_name(name)
        clean = ParticipantName.clean(name)
        raise Invalid, "a participant needs a name" if clean.empty?

        clean
      end

      # Refuses a store others could read: the grants folder must be 0700
      # and the file 0600, both this user's (PrivateFiles).
      # @raise [Insecure]
      def self.check_permissions!(path)
        PrivateFiles.check!(File.dirname(path), [path], holds: "the participants' grants", error: Insecure)
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
      # @param identity [String, nil] the proxy identity (an email) the grant
      #   is bound to (Grants.clean_identity), nil for any
      # @param on_write [#call, nil] see #update
      # @return [Issued]
      # @raise [Invalid]
      def issue(session_id:, name:, kind: "human", role: "reviewer", ttl: nil, cap: nil, identity: nil, on_write: nil)
        Session.check_id!(session_id)
        ttl ||= Grants.default_ttl
        cap = Grants.default_cap if cap.nil?
        raise Invalid, "kind is human or agent, not #{kind}" unless KINDS.include?(kind)
        raise Invalid, "role is reviewer, not #{role}" unless ROLES.include?(role)
        raise Invalid, "a grant lasts 1 hour to 30 days" unless ttl.is_a?(Integer) && ttl.between?(3600, MAX_TTL)
        raise Invalid, CAP_RANGE unless Grants.cap?(cap)

        clean = Grants.clean_name(name)
        identity = Grants.clean_identity(identity) unless identity.nil?
        token = "#{PREFIX}#{SecureRandom.urlsafe_base64(BYTES)}"
        issued = now
        update(on_write) do |grants|
          id = fresh_id(grants)
          grant = Grant.new(id: id, session_id: session_id, digest: Grants.digest(token), kind: kind, name: clean,
                            role: role, created_at: stamp(issued), expires_at: stamp(issued + ttl), revoked_at: nil,
                            revoked_by: nil, last_used_at: nil, cap: cap.to_f, queue: Grants.default_queue,
                            identity: identity)
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
      rescue Unwritable
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

      # In a newer chi's store (Newer) a grant with fields this chi doesn't
      # know is left out: such a field may restrict it (a binding moved to a
      # new key), so it fails closed here. Its link works on that chi again.
      def reload(stamp)
        grants, version = stamp ? read : [[], VERSION]
        grants = grants.select { |grant| grant.extra.empty? } if version > MAX_VERSION
        @grants = grants
        @corrupt = nil
      rescue Corrupt => e
        @grants = []
        @corrupt = e
        Log.warn(:web, "grants_unreadable", echo: "[chi web] #{e.message}", path: @path)
      end

      # [grants, the store's version] (none yet: [[], VERSION]).
      # @raise [Corrupt] the file is there but isn't a grants store
      def read
        data = begin
          JSON.parse(File.read(@path))
        rescue Errno::ENOENT
          return [[], VERSION]
        rescue JSON::ParserError
          raise Corrupt.new(@path, "not JSON")
        end
        rows = data.is_a?(Hash) ? data["grants"] : nil
        raise Corrupt.new(@path, "no grants list") unless rows.is_a?(Array)

        version = data.fetch("version", VERSION)
        raise Corrupt.new(@path, "a bad version") unless version.is_a?(Integer) && version >= VERSION

        [rows.each_with_index.map { |hash, index| grant_from(hash, index) }, version]
      end

      # A stored grant the gate can compare and date, else Corrupt.
      def grant_from(hash, index)
        raise Corrupt.new(@path, "grant #{index + 1} isn't an object") unless hash.is_a?(Hash)

        grant = Grant.from_h(hash)
        problem = if !grant.id.is_a?(String) || !grant.session_id.is_a?(String) then "no id or session"
                  elsif !grant.digest.is_a?(String) || grant.digest.empty? then "no digest"
                  elsif !time?(grant.expires_at) then "no expiry"
                  elsif !grant.revoked_at.nil? && !time?(grant.revoked_at) then "a bad revoked_at"
                  elsif !identity?(grant.identity) then "a bad identity"
                  end
        raise Corrupt.new(@path, "grant #{index + 1} has #{problem}") if problem

        grant
      end

      # nil (unbound), or an identity as #issue stores it: anything else
      # (false, "", a list) could read as unbound.
      def identity?(value)
        value.nil? || (value.is_a?(String) && Grants.clean_identity(value) == value)
      rescue BadIdentity
        false
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
          # would keep only this one's change. Nor over a newer chi's
          # (Newer): this chi would drop what it doesn't know.
          stored, version = read
          raise Newer.new(@path, version) if version > MAX_VERSION

          grants, result = yield(stored)
          at = now
          kept = grants.reject { |grant| (ended = grant.ended_at(at)) && at - ended > KEEP_ENDED }
          version = [version, kept.any?(&:identity) ? BOUND_VERSION : VERSION].max
          body = JSON.pretty_generate({ "version" => version, "grants" => kept.map(&:to_store) })
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
