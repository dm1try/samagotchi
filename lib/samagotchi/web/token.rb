# frozen_string_literal: true

require "fileutils"
require "openssl"
require "securerandom"
require_relative "../atomic_file"

require_relative "../session"
require_relative "../redacted_inspect"

module Samagotchi
  module Web
    # The access token of `chi web` on the LAN (web.host: lan): anyone
    # who has it can run commands as you, so it lives in one file only you
    # can read, $XDG_STATE_HOME/samagotchi/web-token (0600). It is made on
    # the first LAN start and kept, so a phone's bookmark survives
    # restarts; `chi web --new-token` replaces it. A loopback-only chi web
    # never reads it. The owner's cookie for this machine's 127.0.0.1
    # holds #loopback_cookie, never the token: a server on any other local
    # port is sent that cookie too.
    module Token
      FILE = "web-token"
      # 32 random bytes: 43 URL-safe characters.
      BYTES = 32
      LOOPBACK_PREFIX = "chl_"
      LOOPBACK_LABEL = "chi web loopback cookie v1"

      module_function

      def path(env: ENV)
        File.join(File.dirname(Session.default_state_dir(env: env)), FILE)
      end

      # @return [String, nil] the token in +path+, nil when there is none
      def read(path = self.path)
        token = File.read(path).strip
        token.empty? ? nil : token
      rescue Errno::ENOENT
        nil
      end

      # @return [String] the token in +path+, made (and saved) if there is none
      def load_or_create(path = self.path)
        read(path) || write(path, generate)
      end

      # A new token in +path+: every link made with the old one stops working.
      # @return [String] the new token
      def rotate(path = self.path)
        write(path, generate)
      end

      def generate
        SecureRandom.urlsafe_base64(BYTES)
      end

      # The owner's 127.0.0.1 cookie on the LAN: an HMAC of a label keyed
      # by +token+, so a leaked one gives nothing about the token, and
      # rotating the token ends it. The gate takes it only as that cookie,
      # from an unproxied loopback peer (App#loopback_cookie_peer?).
      # @return [String, nil] "chl_" and 43 URL-safe characters; nil
      #   without a token
      def loopback_cookie(token)
        return nil if token.nil? || token.empty?

        # URL-safe base64 without padding (pack: base64 isn't a default gem).
        digest = OpenSSL::HMAC.digest("SHA256", token, LOOPBACK_LABEL)
        LOOPBACK_PREFIX + [digest].pack("m0").tr("+/", "-_").delete("=")
      end

      # Written whole under a temporary name, then renamed over +path+: a
      # reader never sees half a token. The file is 0600 from the start,
      # its folder 0700 when this makes it.
      def write(path, token)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir, mode: 0o700)
        AtomicFile.write(path, "#{token}\n", perm: 0o600)
        token
      end

      # The token a running server checks against: the file is re-read when
      # its mtime changes (one stat per check), so `chi web --new-token`
      # takes effect at once, without a restart.
      class Source
        include RedactedInspect

        attr_reader :path

        def initialize(path = Token.path)
          @path = path
          @mutex = Mutex.new
          @stamp = nil
          @token = nil
        end

        # @return [String, nil] the current token; nil when the file is gone
        #   (then nothing matches)
        def current
          stamp = begin
            stat = File.stat(@path)
            [stat.mtime, stat.size, stat.ino]
          rescue Errno::ENOENT
            nil
          end
          @mutex.synchronize do
            unless stamp == @stamp
              @token = stamp && Token.read(@path)
              @stamp = stamp
            end
            @token
          end
        end
      end
    end
  end
end
