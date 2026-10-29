# frozen_string_literal: true

require "digest"
require "erb"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require_relative "../atomic_file"
require_relative "../version"
require_relative "../self_report"
require_relative "../chi_home"
require_relative "../installed_gem"
require_relative "../config"
require_relative "../host_keys"
require_relative "../redacted_inspect"
require_relative "../paths"

module Samagotchi
  module Desktop
    # The macOS helper, "Chi Helper.app": a Service ("Send to chi") and a
    # hotkey that open a panel sending text to live sessions via `chi note`.
    #
    # Built on this machine with plain swiftc and an ad-hoc signature (no
    # Xcode project, no notarization) into ~/Applications. Every outside
    # command goes through the runner, and the dirs are injectable, so specs
    # (and smokes with register: false) never touch the real system.
    class MacOS
      include RedactedInspect

      class Error < StandardError
      end

      APP_NAME = "Chi Helper"
      BUNDLE_ID = "dev.samagotchi.chi-helper"
      EXECUTABLE = "ChiHelper"
      SOURCES_DIR = File.expand_path("macos", __dir__)
      PBS = "/System/Library/CoreServices/pbs"
      LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
      # Built next to the target without an .app suffix, so Launch Services
      # never registers a half-built app.
      BUILD_NAME = ".chi-helper-build"
      OLD_NAME = ".chi-helper-old"
      # Apps started by launchd get a bare env (no shell rc files), so the
      # launch file carries what chi needs to find its state and tools.
      # Only these, and only when set: no tokens, no runtime knobs. No
      # RUBYLIB, and GEM_HOME/GEM_PATH (GEM_ENV) only for a [ruby, chi]
      # argv, whose wrapper may find its gem only through them (a chruby
      # GEM_HOME): the chi home's boot sets its gem path itself, and they
      # would reach every tool its sessions run (a project's `bundle exec`).
      ENV_ALLOWLIST = %w[XDG_CONFIG_HOME XDG_STATE_HOME].freeze
      GEM_ENV = %w[GEM_HOME GEM_PATH].freeze
      # What older launch files carried and a refresh drops (#refresh_launch_file).
      DROPPED_ENV = %w[GEM_HOME GEM_PATH RUBYLIB].freeze
      # PATH is separately filtered to absolute dirs and frozen when written,
      # so the helper's chi, workers and execute can find the shell's tools.
      # Without it Ruby reads stdin as US-ASCII and non-ASCII notes break.
      LANG = "en_US.UTF-8"
      # chi broadcast's default triage deadline, and the helper's seconds on
      # top of it (MacOS.broadcast_timeout).
      BROADCAST_TRIAGE_DEADLINE = 20
      BROADCAST_MARGIN = 10
      # The agent terminals the helper pastes into (AgentTerminal.swift):
      # one launch-file section each, in this order.
      TERMINALS = %w[kitty tmux].freeze

      # PATH dirs the helper can use from launchd's / working directory:
      # keep absolute entries only, in order, once each.
      def self.path_dirs(env)
        env["PATH"].to_s.split(File::PATH_SEPARATOR).select { _1.start_with?("/") }.uniq
      end

      def self.baked_path(env)
        dirs = path_dirs(env)
        dirs.empty? ? nil : dirs.join(File::PATH_SEPARATOR)
      end

      # Runs a command without a shell; [output, success].
      class Runner
        def run(argv)
          output, status = Open3.capture2e(*argv)
          [output, status.success?]
        rescue SystemCallError => e
          [e.message, false]
        end
      end

      # The kitty: settings the helper lists agent windows with (baked into
      # the launch file), or nil when kitty.listen_on is unset.
      def self.kitty_settings(get = Config.method(:get))
        listen_on = get.call("kitty.listen_on").to_s.strip
        return nil if listen_on.empty?

        agents = get.call("kitty.agents").to_s.split("|").map(&:strip).reject(&:empty?)
        { "listen_on" => listen_on, "binary" => get.call("kitty.binary").to_s, "agents" => agents }
      end

      # The tmux: settings, or nil while tmux.enabled is off. The binary is
      # tmux.binary, else the tmux on +env+'s PATH ("" when there is none:
      # only absolute dirs are usable from launchd; see #warnings); the socket
      # dir is where tmux puts `-L` sockets
      # ($TMUX_TMPDIR when it is a directory, else /tmp, then tmux-<uid>).
      # Both are frozen at bake time, like the rest of the launch file.
      def self.tmux_settings(get = Config.method(:get), env: ENV)
        return nil unless get.call("tmux.enabled")

        binary = get.call("tmux.binary").to_s.strip
        binary = path_tmux(env) if binary.empty?
        tmpdir = env["TMUX_TMPDIR"].to_s
        tmpdir = "/tmp" if tmpdir.empty? || !File.directory?(tmpdir)
        agents = get.call("tmux.agents").to_s.split("|").map(&:strip).reject(&:empty?)
        { "binary" => binary, "socket_dir" => File.join(tmpdir, "tmux-#{Process.uid}"), "agents" => agents }
      end

      def self.path_tmux(env)
        path_dirs(env).map { File.join(_1, "tmux") }.find { File.file?(_1) && File.executable?(_1) }.to_s
      end

      # Each switched-on terminal's settings by name ("kitty" => …).
      def self.terminal_settings(get = Config.method(:get), env: ENV)
        { "kitty" => kitty_settings(get), "tmux" => tmux_settings(get, env: env) }.compact
      end

      # The helper as chi desktop and chi update make it: the settings it
      # bakes into the launch file read from the config.
      def self.from_config(register: true)
        new(register: register, terminals: terminal_settings, broadcast_timeout: broadcast_timeout)
      end

      # Seconds the helper gives `chi broadcast` before it stops it: the
      # triage deadline, then the deliveries and chi's own start. Baked into
      # the launch file: a changed deadline reaches the helper with chi update.
      def self.broadcast_timeout(get = Config.method(:get))
        (get.call("broadcast.triage_deadline") || BROADCAST_TRIAGE_DEADLINE).to_f + BROADCAST_MARGIN
      end

      attr_reader :app_dir, :support_dir

      def initialize(app_dir: nil, support_dir: nil, env: ENV, runner: Runner.new,
                     source_dir: SelfReport::SOURCE_DIR, ruby: RbConfig.ruby, version: VERSION,
                     arch: nil, sources_dir: SOURCES_DIR, register: true, chi_path: nil, terminals: {},
                     broadcast_timeout: nil, chi_home: ChiHome.current(gem_spec: InstalledGem.spec(source_dir)))
        home = env["HOME"] || Dir.home
        @app_dir = app_dir || File.join(home, "Applications")
        @support_dir = support_dir || File.join(home, "Library", "Application Support", APP_NAME)
        @env = env
        @runner = runner
        @source_dir = source_dir
        @chi_path = chi_path || InstalledGem.wrapper(InstalledGem.spec(source_dir)) || File.join(source_dir, "bin", "chi")
        @ruby = ruby
        @version = version
        @arch = arch
        @sources_dir = sources_dir
        @register = register
        @terminals = terminals
        @broadcast_timeout = broadcast_timeout
        @chi_home = chi_home
      end

      def app_path = File.join(@app_dir, "#{APP_NAME}.app")
      def launch_path = File.join(@support_dir, "launch.json")
      # Written by the app at launch: its hotkey and whether macOS took it.
      def hotkey_path = File.join(@support_dir, "hotkey.json")
      def executable_path = File.join(app_path, "Contents", "MacOS", EXECUTABLE)
      def installed? = File.directory?(app_path)

      # What the helper runs: the chi home's boot (ChiHome: its ruby, its gem
      # path in the -e string, then "--" and the helper's args) when there
      # is one; else absolute ruby + chi (no shims, which need the shell's
      # PATH). chi is an installed gem's RubyGems wrapper (it activates the
      # gem and outlives upgrades and `gem cleanup`), else this checkout's
      # bin/chi. And the allowlisted env. A section per terminal
      # switched on (TERMINALS order); the broadcast timeout when given.
      # The XDG dirs go in absolute (Paths): launchd starts the app in /,
      # where a relative one would mean /<dir>. PATH is filtered to absolute,
      # deduplicated dirs so chi, its workers and execute find shell tools;
      # it is frozen at bake time.
      def launch_config
        env = { "LANG" => LANG }
        argv = launch_argv
        names = home_boot?(argv) ? ENV_ALLOWLIST : ENV_ALLOWLIST + GEM_ENV
        names.each { |name| env[name] = @env[name] unless @env[name].to_s.empty? }
        path = self.class.baked_path(@env)
        env["PATH"] = path if path
        env.merge!(Paths.absolute_xdg(env: env, set: :key))
        config = { "version" => @version, "argv" => argv, "env" => env, "sources_sha" => sources_sha }
        TERMINALS.each { |name| config[name] = @terminals[name] if @terminals[name] }
        config["broadcast_timeout"] = @broadcast_timeout if @broadcast_timeout
        config
      end

      def launch_argv
        @chi_home ? @chi_home.boot_argv(run: ChiHome::CHI_BOOT) + ["--"] : [@ruby, @chi_path]
      end

      # A digest of what a build compiles: the Swift sources and the
      # Info.plist template. The launch file records the one it was built
      # from, so a new chi rebuilds only when these changed.
      def sources_sha
        files = Dir[File.join(@sources_dir, "*.swift")].sort + [File.join(SOURCES_DIR, "Info.plist.erb")]
        Digest::SHA256.hexdigest(files.map { |f| "#{File.basename(f)}\0#{File.binread(f)}" }.join("\0"))
      end

      # Whether the installed app needs a rebuild (chi desktop upgrade): its
      # sources changed since the build (a launch file without a digest
      # counts as changed), or the launch file's ruby or chi is gone (a Ruby
      # upgrade moved them).
      def stale?
        return false unless installed?

        launch = read_launch
        launch["sources_sha"] != sources_sha || !launch_ok?(launch)
      end

      # The launch file names an older chi version than this one (or none), or
      # other terminal settings, broadcast timeout or a missing bakeable PATH:
      # refresh_launch_file fixes that without a rebuild. A different argv or
      # baked PATH, or a newer version, is intentional: the ruby, chi and PATH
      # the helper runs change only with chi desktop install --force or upgrade.
      def launch_outdated?
        launch = read_launch
        older_version?(launch["version"]) ||
          TERMINALS.map { launch[_1] } != TERMINALS.map { @terminals[_1] } ||
          launch["broadcast_timeout"] != @broadcast_timeout || path_missing?(launch)
      end

      # Why chi update can't keep the launch file's ruby or chi: one of them
      # is gone. nil when it runs, or has no usable argv (a refresh writes
      # this chi's then). Only the absolute paths in it count (a boot
      # string, "-e" and "--" are not paths), as ChiRunner.swift checks.
      def launch_problem
        argv = usable_argv(read_launch)
        argv && argv_problem(argv)
      end

      # The chi version the launch file names, nil without one.
      def launch_version = read_launch["version"]

      # The launch file names a newer chi than this one: an older chi's
      # chi update keeps the helper as it is (no rebuild from older sources).
      def launch_newer?
        Gem::Version.new(launch_version.to_s) > Gem::Version.new(@version)
      rescue ArgumentError
        false
      end

      # Rewrite the launch file for this chi and its settings, keeping
      # its argv and the env it was installed with; a PATH only when it has
      # none (changing them takes chi desktop install --force or upgrade). A
      # newer version stays. The app reads it at each send. The kept env
      # loses what ENV_ALLOWLIST no longer takes (DROPPED_ENV): RUBYLIB
      # always; GEM_HOME/GEM_PATH once the argv boots the chi home (an old
      # [ruby, wrapper] argv may find its gem only through them).
      def refresh_launch_file
        config = launch_config
        old = read_launch
        config["argv"] = usable_argv(old) || config["argv"]
        config["version"] = old["version"] unless older_version?(old["version"])
        old_env = old["env"]
        if old_env.is_a?(Hash)
          dropped = home_boot?(config["argv"]) ? DROPPED_ENV : DROPPED_ENV - GEM_ENV
          config["env"] = old_env.except(*dropped)
          path = self.class.baked_path(@env)
          config["env"]["PATH"] = path if config["env"]["PATH"].to_s.empty? && path
        end
        write_launch_file(config)
      end

      def warnings
        worktree = if File.file?(File.join(@source_dir, ".git"))
                     ["chi runs from a linked git worktree (#{@source_dir}); the helper stops working once it is removed. " \
                      "Install from the main checkout or a gem install."]
                   end
        Array(worktree) + terminal_warnings + host_key_warnings
      end

      # What a terminal section can't do as baked (chi update shows these
      # too: they need no Keychain lookup).
      def terminal_warnings
        tmux = @terminals["tmux"]
        return [] unless tmux && tmux["binary"].to_s.empty?

        ["tmux.enabled but no tmux found on PATH: set tmux.binary"]
      end

      # Each configured host key (api_key_env:) and whether the helper's chi
      # gets it: the helper's bare env has no keys, so only the Keychain's
      # count (HostKeys). :keychain, :shell_only (set in this shell, not in
      # the Keychain) or :unset. Hosts come from the config the helper's chi
      # reads: the launch file's XDG_CONFIG_HOME when baked; disabled hosts
      # are left out. @return [Array<Hash>] name:, hosts:, state:
      def host_keys
        baked = read_launch["env"]
        dir = baked["XDG_CONFIG_HOME"] if baked.is_a?(Hash)
        # Spelled out: Paths.config_home's ~ is this process's HOME, not @env's.
        config_env = { "XDG_CONFIG_HOME" => dir.to_s.empty? ? File.join(@env["HOME"] || Dir.home, ".config") : dir }
        hosts = ConfigFile.hosts_config(env: config_env).values.select(&:api_key_env).group_by(&:api_key_env)
        hosts.map do |name, entries|
          state = if HostKeys.from_keychain(name, env: @env) then :keychain
                  elsif !@env[name].to_s.strip.empty? then :shell_only
                  else :unset
                  end
          { name: name, hosts: entries.map(&:name), state: state }
        end
      end

      def info_plist
        ERB.new(File.read(File.join(SOURCES_DIR, "Info.plist.erb")))
           .result_with_hash(bundle_id: BUNDLE_ID, app_name: APP_NAME, executable: EXECUTABLE, version: @version)
      end

      # @yield [String] progress lines
      # @param login [Boolean] also start the app at login
      # @param keep_launch [Boolean] keep the launch file's ruby, chi and PATH
      #   (chi update's rebuild) instead of baking this shell's
      def install(force: false, login: false, keep_launch: false, &progress)
        raise Error, "already installed (#{app_version}); use chi desktop upgrade" if installed? && !force

        toolchain!
        quit if installed?
        progress&.call("building #{APP_NAME} #{@version} (can take a few minutes)…")
        built = build_app
        swap_in(built)
        write_launch_file(keep_launch: keep_launch)
        register_app
        self.login = true if login
        progress&.call("installed #{app_path}")
        app_path
      end

      # Keeps the login item as it was.
      def upgrade(keep_launch: false, &)
        was_login = installed? && login == "enabled"
        install(force: true, login: was_login, keep_launch: keep_launch, &)
      end

      # SMAppService status as the app reports it ("enabled",
      # "notRegistered", "requiresApproval", "notFound"); nil if unknown.
      # Only the app itself can register it, run directly with --login.
      def login
        return nil unless @register && installed?

        output, ok = @runner.run([executable_path, "--login", "status"])
        ok ? output.strip : nil
      end

      def login=(on)
        return unless @register && installed?

        output, ok = @runner.run([executable_path, "--login", on ? "on" : "off"])
        raise Error, "could not turn #{on ? "on" : "off"} the login item: #{output.strip}" if on && !ok
      end

      # @return [Boolean] false when there was nothing to remove
      def uninstall
        return false unless installed? || File.exist?(@support_dir)

        self.login = false
        quit
        FileUtils.rm_rf(app_path)
        FileUtils.rm_rf(@support_dir)
        if @register
          @runner.run(["defaults", "delete", BUNDLE_ID])
          @runner.run([PBS, "-update"])
        end
        true
      end

      def status
        result = { installed: installed?, app_path: app_path, chi_version: @version }
        return result unless result[:installed]

        launch = read_launch
        argv = Array(launch["argv"])
        env = launch["env"].is_a?(Hash) ? launch["env"] : {}
        dump, = @runner.run([PBS, "-dump"])
        _, running = @runner.run(["pgrep", "-x", EXECUTABLE])
        hotkey = JSON.parse(File.read(hotkey_path)) rescue nil
        result.merge(
          app_version: app_version,
          login: login,
          hotkey: hotkey.is_a?(Hash) ? hotkey : nil,
          launch_argv: argv,
          launch_ok: launch_ok?(launch),
          stale: stale?,
          baked_dirs: env.select { |name, _| name.start_with?("XDG_") },
          baked_path: env["PATH"],
          service: dump.include?(BUNDLE_ID),
          running: running,
          host_keys: host_keys
        )
      end

      def app_version
        plist = File.read(File.join(app_path, "Contents", "Info.plist"))
        plist[%r{<key>CFBundleShortVersionString</key>\s*<string>([^<]*)</string>}, 1]
      rescue SystemCallError
        nil
      end

      # rename(2) can't replace a non-empty dir: old aside, new in, old gone;
      # the old copy comes back if the second rename fails.
      def swap_in(build)
        old = File.join(@app_dir, OLD_NAME)
        FileUtils.rm_rf(old)
        had_old = installed?
        File.rename(app_path, old) if had_old
        begin
          File.rename(build, app_path)
        rescue StandardError
          File.rename(old, app_path) if had_old
          raise
        end
        FileUtils.rm_rf(old)
      end

      private

      def toolchain!
        _, ok = @runner.run(%w[xcrun --find swiftc])
        return if ok

        raise Error, "chi desktop needs the Command Line Tools (swiftc): xcode-select --install"
      end

      def build_app
        build = File.join(@app_dir, BUILD_NAME)
        FileUtils.rm_rf(build)
        macos_dir = File.join(build, "Contents", "MacOS")
        FileUtils.mkdir_p(macos_dir)
        File.write(File.join(build, "Contents", "Info.plist"), info_plist)
        sources = Dir[File.join(@sources_dir, "*.swift")].sort
        # Through xcrun: swiftc run by its bare path finds no SDK.
        compile = ["xcrun", "--sdk", "macosx", "swiftc", "-O", "-swift-version", "5", "-target", "#{arch}-apple-macos13", "-parse-as-library",
                   *sources, "-o", File.join(macos_dir, EXECUTABLE)]
        run!(compile, "swiftc failed")
        run!(["codesign", "--force", "--sign", "-", build], "codesign failed")
        build
      rescue StandardError
        FileUtils.rm_rf(build) if build
        raise
      end

      def run!(argv, what)
        output, ok = @runner.run(argv)
        raise Error, "#{what}:\n#{output}" unless ok
      end

      def arch
        @arch ||= RbConfig::CONFIG["host_cpu"] == "arm64" ? "arm64" : `uname -m`.strip
      end

      def host_key_warnings
        host_keys.reject { |key| key[:state] == :keychain }.map do |key|
          where = key[:state] == :shell_only ? "is set in this shell only" : "is unset"
          "#{key[:name]} #{where}: the helper's new sessions and model list won't reach host " \
            "#{key[:hosts].join(", ")} until it is in the Keychain (#{HostKeys.store_command(key[:name])})"
        end
      end

      def read_launch
        launch = JSON.parse(File.read(launch_path))
        launch.is_a?(Hash) ? launch : {}
      rescue SystemCallError, JSON::ParserError
        {}
      end

      # This chi is newer than the version the launch file names; a missing or
      # unreadable version counts as older.
      def older_version?(version)
        Gem::Version.new(@version) > Gem::Version.new(version.to_s)
      rescue ArgumentError
        true
      end

      def usable_argv(launch)
        argv = launch["argv"]
        argv if argv.is_a?(Array) && !argv.empty? && argv.all? { |path| path.is_a?(String) && !path.empty? }
      end

      def path_missing?(launch)
        return false unless self.class.baked_path(@env)

        env = launch["env"]
        !env.is_a?(Hash) || env["PATH"].to_s.empty?
      end

      # A launch file whose argv runs (#argv_problem finds nothing).
      def launch_ok?(launch)
        argv = usable_argv(launch)
        !argv.nil? && argv_problem(argv).nil?
      end

      # Why a launch argv (strings) can't run chi, or nil: its ruby isn't an
      # absolute path, an absolute path in it is gone, or it boots the chi
      # home (home.json's ruby) and the home can't boot chi
      # (ChiHome.problem).
      def argv_problem(argv)
        return "the launch file's ruby #{argv[0]} isn't an absolute path: run chi desktop install --force" unless argv[0].start_with?("/")

        missing = launch_paths(argv).reject { |path| File.exist?(path) }
        unless missing.empty?
          return "chi not found at #{missing.join(", ")}: run chi desktop install --force from the shell whose chi it should run"
        end
        return nil unless home_boot?(argv)

        home = begin
          ChiHome.read
        rescue ChiHome::Invalid
          nil
        end
        why = home && ChiHome.real(home.ruby) == ChiHome.real(argv[0]) && ChiHome.problem(home)
        why ? "the chi home it boots can't run chi (#{why}): chi home doctor" : nil
      end

      # The argv entries that are paths (absolute): a boot's "-e", its
      # string and "--" are not.
      def launch_paths(argv) = Array(argv).select { |arg| arg.is_a?(String) && arg.start_with?("/") }

      # An argv in the chi home's boot form ([ruby, "-e", boot, "--"]).
      def home_boot?(argv) = argv.is_a?(Array) && argv[1] == "-e"

      def write_launch_file(config = launch_config, keep_launch: false)
        if keep_launch
          old = read_launch
          config["argv"] = usable_argv(old) || config["argv"]
          old_env = old["env"]
          old_path = old_env["PATH"] if old_env.is_a?(Hash)
          config["env"]["PATH"] = old_path unless old_path.to_s.empty?
          # A kept [ruby, wrapper] argv keeps the GEM_* its gem was found
          # through; a kept home boot takes none.
          if home_boot?(config["argv"])
            config["env"] = config["env"].except(*GEM_ENV)
          elsif old_env.is_a?(Hash)
            config["env"].merge!(old_env.slice(*GEM_ENV))
          end
        end
        FileUtils.mkdir_p(@support_dir)
        AtomicFile.write(launch_path, JSON.pretty_generate(config) + "\n")
      end

      def register_app
        return unless @register

        # The app first, so pbs reads the Service types it has now (a new
        # type may otherwise show only after a re-login).
        @runner.run([LSREGISTER, "-f", app_path])
        @runner.run([PBS, "-update"])
        # open hands the app its own env, so the install shell's
        # (SAMAGOTCHI_* knobs, tokens) would stay in the helper and in every
        # chi it runs until a relaunch. Through env -i the app gets launchd's
        # bare env, as at login; launch.json carries what chi needs.
        @runner.run(["/usr/bin/env", "-i", "HOME=#{@env["HOME"] || Dir.home}", "/usr/bin/open", "-g", app_path])
      end

      def quit
        @runner.run(["pkill", "-x", EXECUTABLE]) if @register
      end
    end
  end
end
