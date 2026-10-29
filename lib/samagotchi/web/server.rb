# frozen_string_literal: true

require "json"
require "rack"
require "rackup/handler/webrick"
require "rbconfig"
require "uri"
require "webrick"

require_relative "app"
require_relative "info_probe"
require_relative "lan"
require_relative "link_codes"
require_relative "proxy_gate"
require_relative "public_url"
require_relative "push"
require_relative "qr"
require_relative "running"
require_relative "start_dir"
require_relative "session_hub"
require_relative "update_check"
require_relative "token"
require_relative "tunnel"
require_relative "../config"
require_relative "../chi_home"
require_relative "../child_env"
require_relative "../installed_gem"
require_relative "../paths"
require_relative "../project_scope"
require_relative "../log"
require_relative "../session_manager"
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
      RESTARTED_ENV = "SAMAGOTCHI_WEB_RESTARTED"
      ADOPT_PIDS_ENV = "SAMAGOTCHI_WEB_ADOPT_PIDS"

      # The raw header names next to Rack's env (ProxyGate's identity check):
      # chi web is the only WEBrick server chi runs.
      WEBrick::HTTPRequest.prepend(ProxyGate::RawHeaderNames) unless WEBrick::HTTPRequest < ProxyGate::RawHeaderNames

      # `chi web`: one server serves every project, the scope is in the page
      # URL. If a chi web already runs on the port, print (and with --open,
      # open) its page for +start_dir+ and leave it be; else start one.
      # @param scope ["project", "all"] "all": the plain page, every session
      # @param start_dir [String, nil] the folder chi web starts in
      #   (--start-dir, web.start_dir; StartDir.resolve, nil: the cwd): its
      #   project's page, and where a new session without a dir starts. A
      #   folder that isn't one stops it before anything else (never a chdir)
      # @param new_token [Boolean] replace the LAN access token first
      #   (--new-token): a running server takes the new one at once
      # @param tunnel [String, nil] --tunnel's provider (Tunnel.for): this
      #   run's public_url is the tunnel's, never config's, and the tunnel is
      #   on while the server runs
      # @return [Integer] the exit status
      def self.launch(port: nil, host: nil, scope: "project", start_dir: nil, open_browser: false, markdown: false,
                      view: Config::BY_KEY["web.view"].default, annotate_presets: Config::BY_KEY["web.annotate_presets"].default,
                      editor: Config::BY_KEY["web.editor"].default, new_token: false,
                      working_set: Config::BY_KEY["web.working_set"].default, tunnel: nil, start_dir_from: :flag,
                      restarted: false, restart_argv: ["web"], exec: nil)
        handed_on = false # a :restart leaves Serve to the next process, a run turns it off itself
        start_given = !start_dir.to_s.strip.empty?
        start_dir = StartDir.resolve(start_dir, from: start_dir_from)
        rotate_token if new_token
        public_url = public_url_setting unless tunnel
        setting = host_setting(host)
        lan = Lan.wanted?(setting) ? Lan.choose(setting) : nil
        host = resolve_host(setting)
        port = resolve_port(port)
        url = scope_url(host, port, dir: start_dir, scope: scope)
        found = probe(host, port)
        raise Tunnel::AlreadyRunning, port if tunnel && found.is_a?(Hash)

        case found
        when Hash
          if lan && !found["lan"]
            warn "chi web already runs on port #{port} without LAN access; stop it (Ctrl-C in its terminal, " \
                 "or kill #{found["pid"]}) and run this again"
            return 1
          end
          puts "chi web already runs on port #{port} (pid #{found["pid"]}): #{url}"
          other_start = start_given && other_start_line(found["start_dir"], start_dir)
          puts other_start if other_start
          running_public = public_url || Running.live_public_url(probe: ->(at) { probe(host, at) })
          # On the LAN this machine's page needs the token too: the link
          # printed and opened here carries an owner's one-time code.
          here = found["lan"] && !running_public && Token.read(Token.path) ? local_owner_link(url) : nil
          puts local_lines(here) if here
          puts running_lan_lines(found["lan"], port) if found["lan"]
          puts running_public_lines(running_public) if running_public
          puts lan_off_line(setting) if new_token && !found["lan"]
          open_url(here ? local_owner_link(url) : url) if open_browser
          0
        when :other
          warn in_use_message(port)
          1
        else
          provider = nil
          plan = nil
          if tunnel
            provider = Tunnel.for(tunnel)
            plan = provider.prepare(port: port, config_owner: Samagotchi::Config.get("web.proxy.owner"),
                                    config_public_url: Samagotchi::Config.get("web.public_url"),
                                    config_identity_header: Samagotchi::Config.get("web.proxy.identity_header"))
            public_url = plan.public_url
          end
          if new_token && !lan && !public_url
            puts lan_off_line(setting)
            return 0
          end
          # The participants' grants: never served from a store others can read.
          Grants.check_permissions!(Grants.path)
          # Web Push (with an https public_url): a contact the push services
          # would refuse, or a key store others can read, stops it here,
          # before any tunnel goes up.
          Push.preflight!(public_url)
          options = { port: port, host: host, url: url, open_browser: open_browser, markdown: markdown, view: view,
                      annotate_presets: annotate_presets, editor: editor, lan: lan, working_set: working_set,
                      public_url: public_url, start_dir: start_dir }
          started = if plan
                      with_tunnel(provider, plan) do |up|
                        start(**options, public_notes: provider.start_lines(plan, restarted: restarted), on_bound: up)
                      end
                    else
                      start(**options)
                    end
          handed_on = !!started
          return reexec(restart_argv, provider: provider, plan: plan, exec: exec) if started == :restart

          started ? 0 : 1
        end
      rescue StartDir::Invalid, Lan::Error, Grants::Insecure, PublicUrl::Invalid, Tunnel::Refused, Push::Refused, Push::Store::Insecure => e
        warn "Error: #{e.message}"
        1
      rescue Interrupt
        # Ctrl-C: the server has stopped (start's ensure); one line, and the
        # status a shell gives a command it interrupted.
        puts "#{"\n" if $stdout.tty?}Chi Web stopped."
        CLI::Exit::INTERRUPTED
      ensure
        # A restarted chi web that didn't get to serve (a refusal, the port
        # race, a bad start folder): the old process's Serve handler it was
        # to adopt goes off, never left forwarding to nothing.
        stop_restarted_tunnel(tunnel, resolve_port(port)) if restarted && tunnel && !handed_on
      end

      # A second chi web given a start folder (--start-dir, web.start_dir)
      # other than the running one's: one line saying it stays; nil when
      # they match or the running one doesn't say (an older chi web).
      def self.other_start_line(running, wanted)
        return nil if running.nil? || running == wanted

        "It starts in #{Paths.tilde(running)}; restart it to use #{Paths.tilde(wanted)}"
      end

      # The tunnel on while the block runs (the server), off after it
      # whatever ends it (Ctrl-C, SIGTERM, SIGHUP), once #up may have taken
      # effect: a refusal before it turns off nothing (a live tunnel of
      # another chi web stays). The block gets #up to call once the port is
      # bound (start's on_bound), so Serve never forwards the tailnet to a
      # listener that took the port first. A signal during #up waits for it
      # (its command runs in its own process group, and Serve keeps what it
      # set even if chi stopped waiting), so it can't land between the serve
      # going on and the teardown being due; #up is bounded by its timeout.
      # A :restart result leaves Serve up for the exec'd chi web to adopt.
      def self.with_tunnel(provider, plan)
        attempted = false
        result = yield(lambda do
          Thread.handle_interrupt(SignalException => :never) do
            attempted = true
            provider.up(plan)
          end
        end)
        result
      ensure
        tunnel_down(provider, plan) if attempted && result != :restart
      end

      # Replace this process only after its listener and hub have stopped.
      # Starter PIDs are children of this process; workers are detached and
      # must not be adopted or signaled.
      # No line before the exec: one on a hung-up terminal raises EIO, and
      # the restart would end in a dead chi web; the log says it.
      def self.reexec(argv, provider: nil, plan: nil, exec: nil)
        command = reexec_command(argv)
        raise ArgumentError, "RubyGems chi wrapper not found" unless command

        env = ChildEnv.unbundled.merge(
          RESTARTED_ENV => "1",
          ADOPT_PIDS_ENV => SessionManager.live_spawn_pids.join(",")
        )
        Samagotchi::Log.info(:web, "restart", program: command[1] == "-e" ? "home:#{command[0]}" : command[1])
        runner = exec || ->(environment, *args) { Kernel.exec(environment, *args) }
        runner.call(env, *command)
      rescue SystemCallError, ArgumentError => e
        tunnel_down(provider, plan) if provider && plan
        warn "Error: couldn't restart chi web: #{e.message}"
        1
      end

      # A restart's argv: with a chi home, its boot (ChiHome::CHI_BOOT: the
      # newest chi in the home; a bare wrapper would activate the newest in
      # whatever GEM_* the env has, off the home); else this Ruby and
      # #reexec_program. A home whose newest chi is older than this one is
      # passed over (logged): the restart argv has this chi's flags, which
      # an older one may not know. nil when there is nothing to exec.
      # @return [Array<String>, nil]
      def self.reexec_command(argv, home: ChiHome.current)
        if home && home.newest_version && home.newest_version < Gem::Version.new(Samagotchi::VERSION)
          Samagotchi::Log.warn(:web, "restart_home_older", home: home.newest_version.to_s, version: Samagotchi::VERSION)
          home = nil
        end
        return home.boot_argv(run: ChiHome::CHI_BOOT) + ["--", *argv] if home

        program = reexec_program
        program.to_s.empty? ? nil : [RbConfig.ruby, program, *argv]
      end

      # What a restart execs without a chi home: the installed gem's wrapper
      # (it activates the newest installed chi), this bin/chi in a checkout;
      # nil for a gem installed without one (--bindir).
      def self.reexec_program
        gem_spec = InstalledGem.spec
        gem_spec ? InstalledGem.wrapper(gem_spec) : $PROGRAM_NAME
      end

      # bin/chi's first step: the restart marker and the starters to adopt
      # out of +env+, before anything (a worker, chi update) is spawned with
      # it; the starters are adopted only under the marker.
      # @return [Boolean] whether this chi web is a restarted one
      def self.take_restart_env!(env = ENV, detach: Process.method(:detach))
        restarted = env.delete(RESTARTED_ENV) == "1"
        adopt_reexec_children!(env: env, detach: detach) if restarted
        env.delete(ADOPT_PIDS_ENV)
        restarted
      end

      # Adopt only the recorded child starters. They may have exited in the
      # interval between collecting their PIDs and the new process starting.
      def self.adopt_reexec_children!(env: ENV, detach: Process.method(:detach))
        pids = env.delete(ADOPT_PIDS_ENV).to_s
        pids.split(",").reject(&:empty?).each do |pid|
          child_pid = Integer(pid, 10)
          begin
            detach.call(child_pid)
          rescue Errno::ECHILD
            nil
          end
        end
      end

      # Turns off the Serve handler a restarted chi web was to adopt, only
      # when it is still exactly this port's (prepare says adopted); a
      # foreign one, or none, stays as it is. Never raises: the start's own
      # error is the one to say.
      def self.stop_restarted_tunnel(tunnel, port)
        provider = Tunnel.for(tunnel)
        plan = provider.prepare(port: port, config_owner: Samagotchi::Config.get("web.proxy.owner"),
                                config_public_url: Samagotchi::Config.get("web.public_url"),
                                config_identity_header: Samagotchi::Config.get("web.proxy.identity_header"))
        tunnel_down(provider, plan) if plan.adopted
      rescue StandardError => e
        Samagotchi::Log.warn(:web, "restart_tunnel_left", error: e.class.name, msg: e.message)
      end

      # The tunnel's teardown, before any line (a hung-up terminal can't
      # write): a failure is one warning line, never a crash or another exit
      # status. A second Ctrl-C (SIGTERM, SIGHUP) during it waits for it
      # (bounded by its commands' timeouts) and is then dropped: the run
      # already ends the way the first signal ends it.
      def self.tunnel_down(provider, plan)
        line = nil
        begin
          Thread.handle_interrupt(SignalException => :never) do
            line = begin
              provider.down_line(plan, provider.down(plan))
            rescue Tunnel::Refused => e
              provider.down_warning(plan, e)
            end
          end
        rescue SignalException
          nil
        end
        say(line) if line
      end

      # A line that may meet a terminal gone (SIGHUP): never an error.
      def self.say(line)
        puts line
        $stdout.flush
      rescue IOError, SystemCallError
        nil
      end

      # @param hub [SessionHub, nil] the session projection the page streams
      #   from; built over the app's state dir unless given
      # @param lan [Lan::Choice, nil] also listen on this LAN address, where
      #   every request but this machine's needs the access token
      # @param token_path [String] the LAN access token's file
      # @param public_url [PublicUrl, nil] behind an auth proxy
      #   (web.public_url, or --tunnel's): every request needs the access token
      # @param public_notes [Array<String>] lines after the proxied link's
      #   (the tunnel's)
      # @param on_bound [#call, nil] run once the port is bound, before any
      #   line (the tunnel's #up); what it raises ends the run
      # @param start_dir [String] the folder chi web starts in (App's)
      # @return [Boolean, :restart] false when the port was taken (said so on stderr);
      #   :restart when the owner requested an in-place process replacement
      def self.start(port: nil, host: nil, url: nil, open_browser: false, state_dir: nil, manager: nil, markdown: false,
                     view: Config::BY_KEY["web.view"].default, annotate_presets: Config::BY_KEY["web.annotate_presets"].default, hub: nil, lan: nil,
                     editor: Config::BY_KEY["web.editor"].default, token_path: Token.path,
                     working_set: Config::BY_KEY["web.working_set"].default, public_url: nil, public_notes: [],
                     on_bound: nil, start_dir: Dir.pwd, update_check: nil)
        config_restart_unsubscribe = ConfigFile.watch_restart_settings!(process: :web) do |message|
          Samagotchi::Log.warn(:config, "restart_required", echo: "Warning: config: #{message}")
        end
        port = resolve_port(port)
        host = resolve_host(host)
        url ||= "http://#{url_host(host)}:#{port}/"

        hub ||= SessionHub.new(state_dir: state_dir || Session.default_state_dir, manager: manager || SessionManager)
        update_check ||= UpdateCheck.new(hub: hub)
        Token.load_or_create(token_path) if lan || public_url
        lan_option = { ip: lan.ip, token: Token::Source.new(token_path) } if lan
        public_token = Token::Source.new(token_path) if public_url
        push = push_runtime(public_url, state_dir)
        app = App.new(manager: manager, state_dir: state_dir, markdown: markdown, view: view,
                      annotate_presets: annotate_presets, editor: editor, hub: hub, lan: lan_option, working_set: working_set,
                      public_url: public_url, public_token: public_token, push: push, start_dir: start_dir)
        webrick = nil
        restart_mutex = Mutex.new
        restart_requested = false
        restart_thread = nil
        if app.respond_to?(:restart_web=)
          app.restart_web = lambda do
            restart_mutex.synchronize do
              next false if restart_requested
              next :no_wrapper unless reexec_command([])

              restart_requested = true
              restart_thread = Thread.new do
                sleep 0.2
                webrick&.shutdown
              end
              true
            end
          end
        end
        Samagotchi::Log.info(:web, "start", url: "http://#{host}:#{port}", version: Samagotchi::VERSION)
        Samagotchi::Log.info(:web, "lan", ip: lan.ip, interface: lan.interface) if lan
        if public_url
          Samagotchi::Log.info(:web, "public_url", origin: public_url.origin, identity_header: public_url.identity_label,
                                                   owner: public_url.owner ? "set" : "none")
        end
        # Subscribed before the first scan, which makes the first check.
        hub.subscribe(method(:on_hub_event))
        if push
          # The Notifier seeds from the hub's snapshot, which is empty before
          # a scan: one now, so what is already open never pushes.
          hub.scan
          notifier = Push::Notifier.new(store: push.store, client: push.client, origin: push.origin,
                                        presence: push.presence).start(hub)
          Samagotchi::Log.info(:web, "push", devices: push.store.for_origin(push.origin).size)
        end
        hub.start
        update_check.start
        # Said once the port is bound: a second chi web racing for it gets
        # the in-use line instead.
        running_path = Running.path(state_dir: state_dir)
        callback_unfinished = false
        started = lambda do
          callback_unfinished = true
          on_bound&.call
          record_running(running_path, port, public_url)
          puts "Chi Web on #{url} (public: #{File.expand_path("public", __dir__)})"
          # On the LAN (no web.public_url) this machine's page needs the
          # token too: a one-time owner's code in the link instead.
          local = lan && !public_url
          puts local_lines(local_owner_link(url, codes: owner_codes(state_dir))) if local
          puts lan_lines(ip: lan.ip, port: port, token: Token.read(token_path), others: lan.others, public: lan.public) if lan
          if public_url
            puts public_lines(public_url, token: Token.read(token_path), codes: owner_codes(state_dir), notes: public_notes)
          end
          puts "Press Ctrl-C to stop."
          $stdout.flush # a log file isn't line-buffered
          if open_browser
            # With web.public_url the page opens through the proxy; on the
            # LAN with a one-time owner's code (#code=, its own).
            open_target = if public_url then public_url.link(owner_codes(state_dir).issue(kind: :owner, ttl: LinkCodes::OWNER_TTL))
                          elsif local then local_owner_link(url, codes: owner_codes(state_dir))
                          else url
                          end
            Thread.new do
              sleep 0.8
              open_url(open_target)
            end
          end
          callback_unfinished = false
        end

        # The event loops (GET /api/events) end once WEBrick leaves
        # :Running: it joins every request thread before run returns.
        Rackup::Handler::WEBrick.run(app, Host: host, Port: port, AccessLog: [], Logger: Log.new($stderr, WEBrick::Log::WARN),
                                          StartCallback: started) do |server|
          webrick = server
          app.server_running = -> { server.status == :Running }
          listen_lan(server, lan, port) if lan
        end
        restart_requested ? :restart : true
      rescue Errno::EADDRINUSE
        warn in_use_message(port)
        false
      rescue LanListenError => e
        warn "Error: can't listen on #{lan.ip}:#{port} (#{e.message}); did the address change? Run chi web again"
        false
      ensure
        # A start callback that raised (on_bound's refusal, a Ctrl-C) leaves
        # WEBrick :Running with its sockets open.
        webrick&.listeners&.each { |socket| socket.close unless socket.closed? } if callback_unfinished
        Running.clear(path: running_path) if running_path
        config_restart_unsubscribe&.call
        notifier&.stop
        update_check&.stop
        hub&.stop
        Samagotchi::Log.info(:web, "stop") if app
        restart_thread&.join
      end

      class LanListenError < StandardError; end

      # This run's Web Push (Push.runtime), nil when off. launch checked it
      # (Push.preflight!); a store that broke since leaves chi web running
      # without pushes, said in one line.
      def self.push_runtime(public_url, state_dir)
        Push.runtime(public_url, state_dir: state_dir)
      rescue Push::Refused, Push::Store::Insecure, SystemCallError => e
        Samagotchi::Log.warn(:web, "push_off", echo: "Warning: #{e.message}; phone notifications are off")
        nil
      end

      # Where this chi web listens, and its public_url (config's or the
      # tunnel's), for chi share's link (Web::Running); a write that fails
      # leaves the server running and the readers on web.port and config.
      def self.record_running(path, port, public_url = nil)
        Running.record(port: port, path: path, public_url: public_url&.origin,
                       identity_header: public_url&.identity_header)
      rescue SystemCallError => e
        Samagotchi::Log.warn(:web, "running_record_failed", error: e.class.name)
      end

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

      # web.public_url as Server runs it, nil when unset.
      # @raise [PublicUrl::Invalid]
      def self.public_url_setting
        PublicUrl.from_config(url: Samagotchi::Config.get("web.public_url"),
                              identity_header: Samagotchi::Config.get("web.proxy.identity_header"),
                              owner: Samagotchi::Config.get("web.proxy.owner"))
      end

      # What web.public_url adds to the start lines: the proxied link (a
      # one-time code in its fragment), who the owner is, +notes+ (the
      # tunnel's) and, at a terminal, the link's QR code. On this machine the
      # page opens through the proxy too; a direct request takes the token
      # as Authorization: Bearer only (no cookie for 127.0.0.1, which every
      # local port would get).
      def self.public_lines(public_url, token:, codes: owner_codes, notes: [], qr: $stdout.tty?)
        unless token
          return ["Proxied: #{public_url.origin}/ (no access token: its file is gone; chi web --new-token makes one)",
                  *notes]
        end

        who = if public_url.identity_header.nil? then "token only, no identity header"
              elsif public_url.owner then "owner #{public_url.owner} by #{public_url.identity_header}, and the token"
              else "nobody is the owner by identity: web.proxy.owner is unset"
              end
        link = public_url.link(codes.issue(kind: :owner, ttl: LinkCodes::OWNER_TTL))
        lines = ["Proxied: #{link}   ← opens chi web as you once, within #{LinkCodes::OWNER_TTL / 60} minutes " \
                 "(chi web again prints a new one)",
                 "         (#{who}; on this machine the page opens through the proxy too)", *notes]
        lines.concat(QR.lines(link)) if qr
        lines
      end

      # This machine's page on the LAN (web.host lan, no web.public_url),
      # whose loopback needs the token too: +url+ with an owner's one-time
      # code in its fragment (token_fragment.js trades it for the cookie on
      # 127.0.0.1), never the token. One code per link.
      def self.local_owner_link(url, codes: owner_codes)
        "#{url}#code=#{codes.issue(kind: :owner, ttl: LinkCodes::OWNER_TTL)}"
      end

      def self.local_lines(link)
        ["Local: #{link}   ← opens chi web as you once, within #{LinkCodes::OWNER_TTL / 60} minutes " \
         "(chi web again prints a new one; the LAN link works here too)"]
      end

      # The owner's one-time link codes, next to the grants.
      def self.owner_codes(state_dir = nil) = LinkCodes.for_grants(Grants.path(state_dir: state_dir))

      # A second chi web, when this machine's config has web.public_url (or
      # the running chi web recorded one: Running.live_public_url): the link
      # from there and the token file, never from what answered on the port.
      def self.running_public_lines(public_url, token_path: Token.path, codes: owner_codes)
        return ["Proxied: #{public_url.origin}/"] unless Token.read(token_path)

        ["Proxied: #{public_url.link(codes.issue(kind: :owner, ttl: LinkCodes::OWNER_TTL))}   (once, within " \
         "#{LinkCodes::OWNER_TTL / 60} minutes)"]
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

      # The page for +dir+: its project view (?dir=, explicit though a bare
      # page opens the start folder's project too) when it is in a repo;
      # every session (?scope=all) outside one or with scope "all", as a
      # running chi web's bare page may be its own start project.
      def self.scope_url(host, port, dir:, scope: "project")
        base = "http://#{url_host(host)}:#{port}/"
        return "#{base}?scope=all" if scope.to_s == "all" || ProjectScope.root_for(dir).nil?

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
