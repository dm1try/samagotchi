# frozen_string_literal: true

require "json"
require "rack"
require "rackup/handler/webrick"
require "uri"
require "webrick"

require_relative "app"
require_relative "info_probe"
require_relative "lan"
require_relative "qr"
require_relative "session_hub"
require_relative "token"
require_relative "../config"
require_relative "../project_scope"
require_relative "../log"
require_relative "../version"
require_relative "../cli/exit"

module Samagotchi
  module Web
    # Launcher for the single-port Web UI.
    #
    # Binds to loopback (127.0.0.1 by default); with web.host lan (or a LAN
    # address) also to that address, where requests need the access token.
    # Use `bin/chi web` to start.
    class Server
      # WEBrick logs every exception out of its request loop as an ERROR with
      # a backtrace, among them a browser dropping a kept-alive connection
      # (sock.eof? raising ECONNRESET): harmless, so not logged. Nor is the
      # line it logs after answering a body-less POST (no Content-Length),
      # when it tries to drain a body nobody read: the response already went.
      class Log < WEBrick::Log
        DROPPED = [Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED].freeze
        DROPPED_LINES = ["HTTPRequest#fixup: WEBrick::HTTPStatus::LengthRequired occurred."].freeze

        def error(msg)
          return if DROPPED.any? { |klass| msg.is_a?(klass) }
          return if msg.is_a?(String) && DROPPED_LINES.include?(msg)

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
      # @param new_token [Boolean] replace the LAN access token first
      #   (--new-token): a running server takes the new one at once
      # @return [Integer] the exit status
      def self.launch(port: nil, host: nil, scope: "project", dir: Dir.pwd, open_browser: false, markdown: false,
                      view: Config::BY_KEY["web.view"].default, annotate_presets: Config::BY_KEY["web.annotate_presets"].default,
                      editor: Config::BY_KEY["web.editor"].default, new_token: false)
        rotate_token if new_token
        setting = host_setting(host)
        lan = Lan.wanted?(setting) ? Lan.choose(setting) : nil
        host = resolve_host(setting)
        port = resolve_port(port)
        url = scope_url(host, port, dir: dir, scope: scope)
        found = probe(host, port)
        case found
        when Hash
          if lan && !found["lan"]
            warn "chi web already runs on port #{port} without LAN access; stop it (Ctrl-C in its terminal, " \
                 "or kill #{found["pid"]}) and run this again"
            return 1
          end
          puts "chi web already runs on port #{port} (pid #{found["pid"]}): #{url}"
          puts running_lan_lines(found["lan"], port) if found["lan"]
          puts lan_off_line(setting) if new_token && !found["lan"]
          open_url(url) if open_browser
          0
        when :other
          warn in_use_message(port)
          1
        else
          if new_token && !lan
            puts lan_off_line(setting)
            return 0
          end
          if start(port: port, host: host, url: url, open_browser: open_browser, markdown: markdown, view: view,
                   annotate_presets: annotate_presets, editor: editor, lan: lan)
            0
          else
            1
          end
        end
      rescue Lan::Error => e
        warn "Error: #{e.message}"
        1
      rescue Interrupt
        # Ctrl-C: the server has stopped (start's ensure); one line, and the
        # status a shell gives a command it interrupted.
        puts "#{"\n" if $stdout.tty?}Chi Web stopped."
        CLI::Exit::INTERRUPTED
      end

      # @param hub [SessionHub, nil] the session projection the page streams
      #   from; built over the app's state dir unless given
      # @param lan [Lan::Choice, nil] also listen on this LAN address, where
      #   every request but this machine's needs the access token
      # @param token_path [String] the LAN access token's file
      # @return [Boolean] false when the port was taken (said so on stderr)
      def self.start(port: nil, host: nil, url: nil, open_browser: false, state_dir: nil, manager: nil, markdown: false,
                     view: Config::BY_KEY["web.view"].default, annotate_presets: Config::BY_KEY["web.annotate_presets"].default, hub: nil, lan: nil,
                     editor: Config::BY_KEY["web.editor"].default, token_path: Token.path)
        port = resolve_port(port)
        host = resolve_host(host)
        url ||= "http://#{url_host(host)}:#{port}/"

        hub ||= SessionHub.new(state_dir: state_dir || Session.default_state_dir, manager: manager || SessionManager)
        if lan
          Token.load_or_create(token_path)
          lan_option = { ip: lan.ip, token: Token::Source.new(token_path) }
        end
        app = App.new(manager: manager, state_dir: state_dir, markdown: markdown, view: view,
                      annotate_presets: annotate_presets, editor: editor, hub: hub, lan: lan_option)
        Samagotchi::Log.info(:web, "start", url: "http://#{host}:#{port}", version: Samagotchi::VERSION)
        Samagotchi::Log.info(:web, "lan", ip: lan.ip, interface: lan.interface) if lan
        # Subscribed before the first scan, which makes the first check.
        hub.subscribe(method(:on_hub_event))
        hub.start
        # Said once the port is bound: a second chi web racing for it gets
        # the in-use line instead.
        started = lambda do
          puts "Chi Web on #{url} (public: #{File.expand_path("public", __dir__)})"
          puts lan_lines(ip: lan.ip, port: port, token: Token.read(token_path), others: lan.others, public: lan.public) if lan
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
          listen_lan(server, lan, port) if lan
        end
        true
      rescue Errno::EADDRINUSE
        warn in_use_message(port)
        false
      rescue LanListenError => e
        warn "Error: can't listen on #{lan.ip}:#{port} (#{e.message}); did the address change? Run chi web again"
        false
      ensure
        hub&.stop
        Samagotchi::Log.info(:web, "stop") if app
      end

      class LanListenError < StandardError; end

      # The hub's `chi` event: a newer chi installed than this chi web runs
      # is said once in its terminal (the page says it too).
      def self.on_hub_event(event)
        return unless event.type == "chi"

        line = installed_line(event.data[:installed])
        return unless line

        Samagotchi::Log.info(:web, "newer_installed", installed: event.data[:installed], version: Samagotchi::VERSION)
        puts line
        $stdout.flush
      end

      # nil unless +installed+ is newer than this chi web.
      def self.installed_line(installed, running = Samagotchi::VERSION)
        return nil unless InstalledVersions.newer?(installed, running)

        "chi #{installed} is installed; this chi web runs #{running}. Restart it: Ctrl-C here, then chi web " \
          "(new sessions already run #{installed})"
      end

      # The LAN address's listener, next to the loopback one WEBrick made.
      # The loopback socket is bound by now: on a failure it is closed
      # here, as WEBrick never starts.
      def self.listen_lan(server, lan, port)
        server.listen(lan.ip, port)
      rescue Errno::EADDRNOTAVAIL, Errno::EADDRINUSE, SocketError => e
        server.listeners.each(&:close)
        raise LanListenError, e.message
      end

      def self.host_setting(host)
        (host || Samagotchi::Config.get("web.host")).to_s.strip
      end

      # The address the server binds: loopback. For web.host lan or a LAN
      # address it is 127.0.0.1, and the LAN address is a second listener
      # (start's lan:).
      def self.resolve_host(host)
        host = host_setting(host)
        host = DEFAULT_HOST if host.empty?
        return host if %w[127.0.0.1 ::1 localhost].include?(host)
        return DEFAULT_HOST if Lan.wanted?(host)

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
        knows_dir(InfoProbe.call(host, port, timeout: timeout))
      end

      def self.probe_verdict(status, body)
        knows_dir(InfoProbe.verdict(status, body))
      end

      def self.knows_dir(info)
        info.is_a?(Hash) && !Array(info["features"]).include?("dir") ? :other : info
      end
      private_class_method :knows_dir

      # What a phone needs: the LAN link with the token, the warnings, and
      # the link's QR code (at a terminal only).
      def self.lan_lines(ip:, port:, token:, others: [], public: false, qr: $stdout.tty?)
        unless token
          return ["LAN: http://#{ip}:#{port}/ (no access token: its file is gone; chi web --new-token makes one)"]
        end

        link = "http://#{ip}:#{port}/?token=#{token}"
        lines = ["LAN: #{link}   ← anyone with this link can run commands as you",
                 "Plain http: the link and your traffic can be read by anyone on this Wi-Fi."]
        lines << "also: #{others.map(&:to_s).join(", ")}; set web.host to pick one" unless others.empty?
        lines << "#{ip} isn't a private LAN address: anyone who can reach it can try to get in" if public
        lines.concat(QR.lines(link)) if qr
        lines
      end

      # A second chi web, when the running one has LAN access: the same
      # lines, the token read from its file here.
      def self.running_lan_lines(ip, port, token_path: Token.path)
        lan_lines(ip: ip, port: port, token: Token.read(token_path))
      end

      def self.lan_off_line(setting)
        "LAN access is off (web.host is #{setting.empty? ? DEFAULT_HOST : setting}): chi web --web-host lan uses the new token"
      end

      def self.rotate_token(path = Token.path)
        Token.rotate(path)
        Samagotchi::Log.info(:web, "token_rotated")
        puts "New LAN access token: links and QR codes made with the old one stop working."
      end

      def self.in_use_message(port)
        "Error: port #{port} is in use (an older chi web? restart it, or use --port)"
      end

      def self.resolve_port(port)
        raw = port || Samagotchi::Config.get("web.port")
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
