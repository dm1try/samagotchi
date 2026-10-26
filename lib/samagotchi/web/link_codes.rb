# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "openssl"
require "securerandom"
require "time"
require_relative "../atomic_file"

module Samagotchi
  module Web
    # One-time link codes (web.public_url): what a link's fragment carries
    # instead of a token (https://<public url>/#code=chc_…). A fragment
    # outlives the proxy's sign-in redirects, so the sign-in page sits at
    # that URL (its scripts can read it) and it lands in the browser's
    # history: a code works once, then nothing. The page trades it at
    # POST /api/token for the token's cookie.
    #
    # A code is the owner's (10 minutes) or a grant's (until the grant
    # expires). Nothing secret is kept: the store has each code's digest,
    # and a grant's token sealed (AES-256-GCM) under a key derived from the
    # code itself, so only the code's holder can open it. The store is
    # next to the grants (web-grants/link-codes.json, 0600 in that 0700
    # folder), written under a lock: chi web and a local chi share both
    # issue codes.
    class LinkCodes
      FILE = "link-codes.json"
      LOCK = "link-codes.lock"
      PREFIX = "chc_"
      OWNER_TTL = 600
      CODE_RE = /\Achc_[A-Za-z0-9_-]{43}\z/

      # @param grants_path [String] the grants store's path (Grants#path)
      def self.for_grants(grants_path, clock: -> { Time.now }) = new(File.join(File.dirname(grants_path), FILE), clock: clock)

      def self.code?(value) = value.is_a?(String) && CODE_RE.match?(value)

      attr_reader :path

      def initialize(path, clock: -> { Time.now })
        @path = path
        @clock = clock
      end

      # @param kind [:owner, :grant]
      # @param token [String, nil] the grant's token (sealed), nil for the owner
      # @param ttl [Numeric] seconds
      # @return [String] the code
      def issue(kind:, ttl:, token: nil)
        code = "#{PREFIX}#{SecureRandom.urlsafe_base64(32)}"
        entry = { "digest" => digest(code), "kind" => kind.to_s, "expires_at" => (@clock.call + ttl).utc.iso8601 }
        entry["sealed"] = seal(code, token) if token
        update { |entries| entries << entry }
        code
      end

      # The code's [kind, token] (token nil for the owner's), once: the code
      # is gone after. nil for an unknown, used or expired code. With a
      # block, it is asked (kind, token) first, under the lock: false keeps
      # the code for another try and gives nil (a bound grant's code opened
      # by another identity: decision C).
      def redeem(code)
        return nil unless LinkCodes.code?(code)

        wanted = digest(code)
        result = nil
        update do |entries|
          entry = entries.find { |candidate| same_digest?(candidate["digest"].to_s, wanted) }
          next entries unless entry

          opened = open_entry(code, entry)
          next entries if opened && block_given? && !yield(*opened)

          result = opened
          entries.reject { |candidate| candidate.equal?(entry) }
        end
        result
      end

      private

      def digest(code) = Digest::SHA256.hexdigest(code)

      # [kind, token] for a live entry whose token unseals, else nil.
      def open_entry(code, entry)
        return nil if Time.iso8601(entry["expires_at"].to_s) <= @clock.call

        kind = entry["kind"] == "grant" ? :grant : :owner
        token = entry["sealed"] && unseal(code, entry["sealed"])
        return nil if kind == :grant && token.nil?

        [kind, token]
      rescue ArgumentError
        nil
      end

      def same_digest?(left, right) = left.bytesize == right.bytesize && OpenSSL.fixed_length_secure_compare(left, right)

      def key(code) = OpenSSL::KDF.hkdf(code, salt: "chi-link-code", info: "seal", length: 32, hash: "SHA256")

      def seal(code, token)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = key(code)
        iv = cipher.random_iv
        cipher.auth_data = ""
        sealed = cipher.update(token) + cipher.final
        [iv + cipher.auth_tag + sealed].pack("m0")
      end

      def unseal(code, value)
        raw = value.unpack1("m0")
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = key(code)
        cipher.iv = raw[0, 12]
        cipher.auth_tag = raw[12, 16]
        cipher.auth_data = ""
        cipher.update(raw[28..]) + cipher.final
      rescue OpenSSL::Cipher::CipherError, ArgumentError
        nil
      end

      # Read, change and write under the lock; expired codes go. The block
      # gets the live codes and returns the codes to keep.
      def update
        dir = File.dirname(@path)
        FileUtils.mkdir_p(dir, mode: 0o700)
        File.open(File.join(dir, LOCK), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          now = @clock.call
          stored = read
          entries = yield(stored.reject { |entry| expired?(entry, now) })
          # Written only when it changes: a guessed code costs no write.
          next if entries == stored

          AtomicFile.write(@path, "#{JSON.generate({ "version" => 1, "codes" => entries })}\n", perm: 0o600)
        end
      end

      def expired?(entry, now)
        Time.iso8601(entry["expires_at"].to_s) <= now
      rescue ArgumentError
        true
      end

      def read
        data = JSON.parse(File.read(@path))
        codes = data.is_a?(Hash) ? data["codes"] : nil
        codes.is_a?(Array) ? codes.select { |entry| entry.is_a?(Hash) } : []
      rescue Errno::ENOENT, JSON::ParserError
        []
      end
    end
  end
end
