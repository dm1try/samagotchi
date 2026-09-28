# frozen_string_literal: true

require "json"
require "net/http"
require "rack"
require "rackup/handler/webrick"
require "uri"
require "webrick"

require_relative "app"
require_relative "session_hub"
require_relative "../config"
require_relative "../project_scope"
require_relative "../log"
require_relative "../version"

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

        # WEBrick logs the signal that ends its loop (Ctrl-C, a kill) as
        # FATAL with a backtrace, then re-raises it: .launch says it in a
        # line instead.
        def fatal(msg)
          return if msg.is_a?(SignalException)

          super
        end
      end

      DEFAULT_PORT = 4567
      DEFAULT_HOST = "127.0.0.1"
      # How long `chi web` waits for a server already on its port to answer.
      PROBE_TIMEOUT = 0.3

      # `chi web`: one server serves every project, the scope is in the page
      # URL. If a chi web already runs on the port, print (and with --open,
      # open) its page for +dir+ and leave it be; else start one.
      # @param scope ["project", "all"] "all": the plain page, every session
      # @return [Integer] the exit status
      def self.launch(port: nil, host: nil, scope: "project", dir: Dir.pwd, open_browser: false, markdown: false, turn_view: true,
                      annotate_presets: Config::BY_KEY["web.annotate_presets"].default)
        host = resolve_host(host)
        port = resolve_port(port)
        url = scope_url(host, port, dir: dir, scope: scope)
        found = probe(host, port)
        case found
        when Hash
          puts "chi web already runs on port #{port} (pid #{found["pid"]}): #{url}"
          open_url(url) if open_browser
          0
        when :other
          warn in_use_message(port)
          1
        else
          start(port: port, host: host, url: url, open_browser: open_browser, markdown: markdown, turn_view: turn_view,
                annotate_presets: annotate_presets) ? 0 : 1
        end
      rescue Interrupt
        # Ctrl-C: the server has stopped (start's ensure); one line, and the
        # status a shell gives a command it interrupted.
        puts "#{"\n" if $stdout.tty?}Chi Web stopped."
        130
      end

      # @param hub [SessionHub, nil] the session projection the page streams
      #   from; built over the app's state dir unless given
      # @return [Boolean] false when the port was taken (said so on stderr)
      def self.start(port: nil, host: nil, url: nil, open_browser: false, state_dir: nil, manager: nil, markdown: false,
                     turn_view: true, annotate_presets: Config::BY_KEY["web.annotate_presets"].default, hub: nil)
        port = resolve_port(port)
        host = resolve_host(host)
        url ||= "http://#{url_host(host)}:#{port}/"

        hub ||= SessionHub.new(state_dir: state_dir || Session.default_state_dir, manager: manager || SessionManager)
        app = App.new(manager: manager, state_dir: state_dir, markdown: markdown, turn_view: turn_view,
                      annotate_presets: annotate_presets, hub: hub)
        Samagotchi::Log.info(:web, "start", url: "http://#{host}:#{port}", version: Samagotchi::VERSION)
        hub.start
        # Said once the port is bound: a second chi web racing for it gets
        # the in-use line instead.
        started = lambda do
          puts "Chi Web on #{url} (public: #{File.expand_path("public", __dir__)})"
          puts "Press Ctrl-C to stop."
          $stdout.flush # a log file isn't line-buffered
          if open_browser
            Thread.new do
              sleep 0.8
              open_url(url)
            end
          end
        end

        # The event loops (GET /api/events) end once WEBrick leaves
        # :Running: it joins every request thread before run returns.
        Rackup::Handler::WEBrick.run(app, Host: host, Port: port, AccessLog: [], Logger: Log.new($stderr, WEBrick::Log::WARN),
                                          StartCallback: started) do |server|
          app.server_running = -> { server.status == :Running }
        end
        true
      rescue Errno::EADDRINUSE
        warn in_use_message(port)
        false
      ensure
        hub&.stop
        Samagotchi::Log.info(:web, "stop") if app
      end

      def self.resolve_host(host)
        host = (host || ENV.fetch("SAMAGOTCHI_WEB_HOST", DEFAULT_HOST)).to_s.strip
        host = DEFAULT_HOST if host.empty?
        return host if %w[127.0.0.1 ::1 localhost].include?(host)

        Samagotchi::Log.warn(:web, "bind_forced", echo: "Web server only binds to 127.0.0.1 (got #{host}); forcing 127.0.0.1", host: host.to_s)
        DEFAULT_HOST
      end

      # The page for +dir+: its project view (?dir=) when it is in a repo,
      # the plain page (every session) outside one or with scope "all".
      def self.scope_url(host, port, dir:, scope: "project")
        base = "http://#{url_host(host)}:#{port}/"
        return base if scope.to_s == "all" || ProjectScope.root_for(dir).nil?

        # Slashes stay as they are (valid in a query): a URL people can read.
        "#{base}?dir=#{URI.encode_www_form_component(dir).gsub("%2F", "/")}"
      end

      def self.url_host(host)
        host.include?(":") ? "[#{host}]" : host
      end

      # What answers on the port: the /api/info hash of a chi web that knows
      # ?dir, :free when nothing listens, :other for anything else (an older
      # chi web, another program).
      def self.probe(host, port, timeout: PROBE_TIMEOUT)
        response = Net::HTTP.start(host, port, open_timeout: timeout, read_timeout: timeout) { |http| http.get("/api/info") }
        probe_verdict(response.code.to_i, response.body)
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        :free
      rescue StandardError
        :other
      end

      def self.probe_verdict(status, body)
        info = status == 200 ? JSON.parse(body.to_s) : nil
        info.is_a?(Hash) && info["app"] == "chi-web" && Array(info["features"]).include?("dir") ? info : :other
      rescue JSON::ParserError
        :other
      end

      def self.in_use_message(port)
        "Error: port #{port} is in use (an older chi web? restart it, or use --port)"
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
        else Samagotchi::Log.info(:web, "open_manually", echo: "Please open #{url} manually")
        end
      rescue StandardError => e
        Samagotchi::Log.warn(:web, "open_failed", echo: "Failed to open browser: #{e.message} — please open #{url} manually", error: e.class.name)
      end
    end
  end
end
