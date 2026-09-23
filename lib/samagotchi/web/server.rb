# frozen_string_literal: true

require "rack"
require "rackup/handler/webrick"
require "webrick"

require_relative "app"

module Samagotchi
  module Web
    # Launcher for the single-port Web UI.
    #
    # Binds strictly to 127.0.0.1 (localhost-only). Use `bin/chi web` to start.
    class Server
      # WEBrick logs every exception out of its request loop as an ERROR with
      # a backtrace, among them a browser dropping a kept-alive connection
      # (sock.eof? raising ECONNRESET): harmless, so not logged.
      class Log < WEBrick::Log
        DROPPED = [Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED].freeze

        def error(msg)
          return if DROPPED.any? { |klass| msg.is_a?(klass) }

          super
        end
      end

      DEFAULT_PORT = 4567
      DEFAULT_HOST = "127.0.0.1"

      def self.start(port: nil, host: nil, open_browser: false, state_dir: nil, manager: nil, markdown: false)
        port = resolve_port(port)
        host = (host || ENV.fetch("SAMAGOTCHI_WEB_HOST", DEFAULT_HOST)).to_s.strip
        host = DEFAULT_HOST if host.empty?
        unless %w[127.0.0.1 ::1 localhost].include?(host)
          warn "Web server only binds to 127.0.0.1 (got #{host}); forcing 127.0.0.1"
          host = DEFAULT_HOST
        end

        app = App.new(manager: manager, state_dir: state_dir, markdown: markdown)
        puts "Chi Web starting on http://#{host}:#{port} (public: #{File.expand_path("public", __dir__)})"
        puts "Press Ctrl-C to stop."

        if open_browser
          Thread.new do
            sleep 0.8
            open_url("http://#{host}:#{port}/")
          end
        end

        Rackup::Handler::WEBrick.run(app, Host: host, Port: port, AccessLog: [], Logger: Log.new($stderr, WEBrick::Log::WARN))
      end

      def self.resolve_port(port)
        raw = port || ENV.fetch("SAMAGOTCHI_WEB_PORT", DEFAULT_PORT.to_s)
        parsed = raw.to_s.to_i
        parsed.positive? ? parsed : DEFAULT_PORT
      end

      def self.open_url(url)
        case RbConfig::CONFIG["host_os"]
        when /darwin/ then system("open", url)
        when /linux/ then system("xdg-open", url)
        when /mswin|mingw/ then system("start", url)
        else warn "Please open #{url} manually"
        end
      rescue StandardError => e
        warn "Failed to open browser: #{e.message} — please open #{url} manually"
      end
    end
  end
end
