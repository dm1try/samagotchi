# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "openssl"
require "time"
require "uri"
require_relative "crypto"
require_relative "../private_files"
require_relative "../../atomic_file"
require_relative "../../session"

module Samagotchi
  module Web
    module Push
      # This machine's Web Push state, in $XDG_STATE_HOME/samagotchi/web-push/
      # (next to web-token and web-grants/; a 0700 folder, 0600 files, never
      # in config.yml): vapid.pem, chi web's one VAPID key, and
      # subscriptions.json, the devices that turned the bell on. A
      # subscription holds no personal data (an opaque endpoint and two
      # keys); the endpoint and keys never leave this store but for the push
      # itself: what the page and the log show is Sub#public_h (the short
      # id, the label, the dates). See docs/internals/web-push.md.
      #
      # chi web's request threads and the Notifier's sender thread both
      # write: every write is a read-change-write under a lock file.
      class Store
        DIR = "web-push"
        KEY_FILE = "vapid.pem"
        SUBS_FILE = "subscriptions.json"
        LOCK = "store.lock"

        # The push services a subscription's endpoint may name: the
        # browsers' (Apple, Google, Mozilla, Microsoft). chi web POSTs to
        # nothing else (a subscription is the owner's, but an endpoint is a
        # URL chi web fetches). A ".suffix" entry takes any host under it.
        PUSH_SERVICES = ["web.push.apple.com", "fcm.googleapis.com", "updates.push.services.mozilla.com",
                         ".notify.windows.com"].freeze
        ENDPOINT_MAX = 2048
        LABEL_MAX = 40
        # Devices a store keeps (every subscribe adds one until it is turned
        # off): a bound on what one push fans out to.
        MAX_SUBS = 50

        # The store's folder or a file in it can be read by others: chi web
        # refuses to start (Server.launch).
        class Insecure < StandardError; end

        # A subscription the store won't take: the message is the page's.
        class Invalid < StandardError; end

        # subscriptions.json is there but doesn't read: no device is pushed
        # to, and nothing writes over it (that would forget every device).
        class Corrupt < StandardError
          def initialize(path, reason)
            super("#{path} can't be read (#{reason}): chi won't write over it; fix it, or move it aside and turn " \
                  "the bell on again on each device")
          end
        end

        # One device's subscription. +id+ is the short id (the first 8 hex
        # of the endpoint's SHA-256), the only name of it outside this
        # store. +p256dh+ and +auth+ as the browser gave them (base64url).
        # +origin+ the public origin it subscribed on: it is sent to only
        # while chi web runs there (a renamed machine's are stale).
        Sub = Data.define(:id, :endpoint, :p256dh, :auth, :origin, :label, :created_at, :last_ok_at, :last_error,
                          :prefs) do
          def self.from_store(hash)
            keys = hash["keys"].is_a?(Hash) ? hash["keys"] : {}
            new(id: hash["id"], endpoint: hash["endpoint"], p256dh: keys["p256dh"], auth: keys["auth"],
                origin: hash["origin"], label: hash["label"], created_at: hash["created_at"],
                last_ok_at: hash["last_ok_at"], last_error: hash["last_error"],
                prefs: hash["prefs"].is_a?(Hash) ? hash["prefs"] : { "done" => false })
          end

          def to_store
            { "id" => id, "endpoint" => endpoint, "keys" => { "p256dh" => p256dh, "auth" => auth }, "origin" => origin,
              "label" => label, "created_at" => created_at, "last_ok_at" => last_ok_at, "last_error" => last_error,
              "prefs" => prefs }
          end

          # The device's keys as bytes (Crypto.encrypt's).
          def p256dh_bytes = Crypto.unb64u(p256dh)
          def auth_bytes = Crypto.unb64u(auth)

          # Never the endpoint or the keys: what the page, the CLI and the log show.
          def public_h
            { id: id, label: label, origin: origin, created_at: created_at, last_ok_at: last_ok_at,
              last_error: last_error }
          end

          def inspect = "#<Sub #{id} #{label.inspect}>"
          alias_method :to_s, :inspect
        end

        # $XDG_STATE_HOME/samagotchi/web-push, next to the grants;
        # +state_dir+ is the sessions dir (Session.default_state_dir).
        def self.dir(state_dir: nil, env: ENV)
          File.join(File.dirname(state_dir || Session.default_state_dir(env: env)), DIR)
        end

        def self.short_id(endpoint) = Digest::SHA256.hexdigest(endpoint.to_s)[0, 8]

        attr_reader :dir

        # @param services [Array<String>] the push services endpoints may
        #   name (PUSH_SERVICES; a spec seam, not config)
        # @param clock [#call] the Time now
        def initialize(dir = Store.dir, services: PUSH_SERVICES, clock: -> { Time.now })
          @dir = dir
          @services = services
          @clock = clock
          @key_mutex = Mutex.new
          @key = nil
        end

        # Never the key.
        def inspect = "#<#{self.class.name} #{@dir}>"
        alias to_s inspect

        def key_path = File.join(@dir, KEY_FILE)
        def subs_path = File.join(@dir, SUBS_FILE)

        # Refuses a store others could read (PrivateFiles).
        # @raise [Insecure]
        def check_permissions!
          PrivateFiles.check!(@dir, [key_path, subs_path], holds: "chi's push key and devices", error: Insecure)
        end

        # chi web's VAPID key: vapid.pem, made (0600) the first time.
        # @return [OpenSSL::PKey::EC]
        def vapid_key
          @key_mutex.synchronize do
            @key ||= locked do
              if File.file?(key_path)
                OpenSSL::PKey::EC.new(File.read(key_path))
              else
                Crypto.generate_key.tap { |key| AtomicFile.write(key_path, key.private_to_pem, perm: 0o600) }
              end
            end
          end
        end

        # @return [Array<Sub>] none when the file is missing or corrupt (a
        #   corrupt one is refused on write: #update)
        def subscriptions
          read
        rescue Corrupt
          []
        end

        # The subscriptions for +origin+ (the ones chi web sends to now).
        def for_origin(origin) = subscriptions.select { |sub| sub.origin == origin }

        def find(id) = subscriptions.find { |sub| sub.id == id }

        # Adds the subscription a page's pushManager.subscribe gave (its
        # JSON: endpoint, keys {p256dh, auth}); the same endpoint again
        # replaces the old entry (a device subscribing again).
        # @return [Sub]
        # @raise [Invalid] one message per refusal
        def add(subscription, origin:, label:)
          endpoint, p256dh, auth = validate(subscription)
          at = stamp(now)
          sub = Sub.new(id: Store.short_id(endpoint), endpoint: endpoint, p256dh: p256dh, auth: auth, origin: origin,
                        label: label.to_s[0, LABEL_MAX], created_at: at, last_ok_at: nil, last_error: nil,
                        prefs: { "done" => false })
          update do |subs|
            kept = subs.reject { |old| old.endpoint == endpoint }
            raise Invalid, "chi web already pushes to #{MAX_SUBS} devices: turn the bell off on one first" if kept.size >= MAX_SUBS

            [kept + [sub], sub]
          end
        end

        # Removes the subscription with this short id or endpoint.
        # @return [Sub, nil] the one removed
        def remove(id_or_endpoint)
          update do |subs|
            gone = subs.find { |sub| sub.id == id_or_endpoint || sub.endpoint == id_or_endpoint }
            [subs - [gone], gone]
          end
        end

        # Records a delivery: +ok+ true stamps last_ok_at (and clears the
        # error), else +error+ (a short word: "410", "timeout") is kept.
        def mark(id, ok: false, error: nil)
          update do |subs|
            subs = subs.map do |sub|
              next sub unless sub.id == id

              ok ? sub.with(last_ok_at: stamp(now), last_error: nil) : sub.with(last_error: error.to_s[0, 80])
            end
            [subs, nil]
          end
        end

        private

        def now = @clock.call

        def stamp(time) = time.utc.iso8601

        # @return [Array(String, String, String)] endpoint, p256dh, auth
        def validate(subscription)
          keys = subscription["keys"] if subscription.is_a?(Hash)
          endpoint = subscription["endpoint"] if subscription.is_a?(Hash)
          unless endpoint.is_a?(String) && keys.is_a?(Hash) && keys["p256dh"].is_a?(String) && keys["auth"].is_a?(String)
            raise Invalid, "a push subscription needs an endpoint and keys (p256dh, auth)"
          end

          check_endpoint(endpoint)
          p256dh = decoded(keys["p256dh"])
          unless p256dh&.bytesize == 65 && p256dh.getbyte(0) == 4
            raise Invalid, "a push subscription's p256dh must be a P-256 public key (65 bytes, base64url)"
          end
          raise Invalid, "a push subscription's auth must be 16 bytes (base64url)" unless decoded(keys["auth"])&.bytesize == 16

          [endpoint, keys["p256dh"], keys["auth"]]
        end

        def check_endpoint(endpoint)
          uri = begin
            URI.parse(endpoint)
          rescue URI::InvalidURIError
            nil
          end
          if endpoint.bytesize > ENDPOINT_MAX || uri.nil? || uri.scheme != "https" || uri.host.to_s.empty? ||
             uri.userinfo || uri.port != 443
            raise Invalid, "a push endpoint must be an https URL on port 443"
          end
          return if service?(uri.host.downcase)

          raise Invalid, "chi web only pushes to the browsers' push services, not #{uri.host[0, 80]}"
        end

        def service?(host)
          @services.any? { |entry| entry.start_with?(".") ? host.end_with?(entry) && host.length > entry.length : host == entry }
        end

        def decoded(text)
          Crypto.unb64u(text)
        rescue ArgumentError
          nil
        end

        # @raise [Corrupt]
        def read
          data = begin
            JSON.parse(File.read(subs_path))
          rescue Errno::ENOENT
            return []
          rescue JSON::ParserError
            raise Corrupt.new(subs_path, "not JSON")
          end
          rows = data["subscriptions"] if data.is_a?(Hash)
          raise Corrupt.new(subs_path, "no subscriptions list") unless rows.is_a?(Array) && rows.all?(Hash)

          rows.map { |row| Sub.from_store(row) }
        end

        # Read, change and write subscriptions.json under the lock. The block
        # takes the subscriptions and returns [new subscriptions, result].
        def update
          locked do
            subs, result = yield(read)
            body = JSON.pretty_generate({ "version" => 1, "subscriptions" => subs.map(&:to_store) })
            AtomicFile.write(subs_path, "#{body}\n", perm: 0o600)
            result
          end
        end

        def locked
          FileUtils.mkdir_p(@dir, mode: 0o700)
          File.chmod(0o700, @dir)
          File.open(File.join(@dir, LOCK), File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            yield
          end
        end
      end
    end
  end
end
