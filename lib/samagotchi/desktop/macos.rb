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
require_relative "../installed_gem"
require_relative "../config"

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
      # launch file carries what chi needs to find its gems and state. Only
      # these, and only when set: no tokens, no runtime knobs.
      ENV_ALLOWLIST = %w[XDG_CONFIG_HOME XDG_STATE_HOME GEM_HOME GEM_PATH RUBYLIB].freeze
      # Without it Ruby reads stdin as US-ASCII and non-ASCII notes break.
      LANG = "en_US.UTF-8"
      # chi broadcast's default triage deadline, and the helper's seconds on
      # top of it (MacOS.broadcast_timeout).
      BROADCAST_TRIAGE_DEADLINE = 20
      BROADCAST_MARGIN = 10

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

      # The helper as chi desktop and chi update make it: the settings it
      # bakes into the launch file read from the config.
      def self.from_config(register: true)
        new(register: register, kitty: kitty_settings, broadcast_timeout: broadcast_timeout)
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
                     arch: nil, sources_dir: SOURCES_DIR, register: true, chi_path: nil, kitty: nil,
                     broadcast_timeout: nil)
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
        @kitty = kitty
        @broadcast_timeout = broadcast_timeout
      end

      def app_path = File.join(@app_dir, "#{APP_NAME}.app")
      def launch_path = File.join(@support_dir, "launch.json")
      # Written by the app at launch: its hotkey and whether macOS took it.
      def hotkey_path = File.join(@support_dir, "hotkey.json")
      def executable_path = File.join(app_path, "Contents", "MacOS", EXECUTABLE)
      def installed? = File.directory?(app_path)

      # What the helper runs: absolute ruby + chi (no shims, which need the
      # shell's PATH), and the allowlisted env. chi is an installed gem's
      # RubyGems wrapper (it activates the gem and outlives upgrades and
      # `gem cleanup`), else this checkout's bin/chi. The kitty section only
      # when kitty.listen_on is set; the broadcast timeout when given.
      def launch_config
        env = { "LANG" => LANG }
        ENV_ALLOWLIST.each { |name| env[name] = @env[name] unless @env[name].to_s.empty? }
        config = { "version" => @version, "argv" => [@ruby, @chi_path], "env" => env, "sources_sha" => sources_sha }
        config["kitty"] = @kitty if @kitty
        config["broadcast_timeout"] = @broadcast_timeout if @broadcast_timeout
        config
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

      # The launch file names another chi version or path than this one, or
      # other kitty settings or broadcast timeout: refresh_launch_file fixes
      # that without a rebuild.
      def launch_outdated?
        launch = read_launch
        launch["version"] != @version || Array(launch["argv"]) != launch_config["argv"] || launch["kitty"] != @kitty ||
          launch["broadcast_timeout"] != @broadcast_timeout
      end

      # Rewrite the launch file for this chi and its settings, keeping
      # the env it was installed with. The app reads it at each send: no restart.
      def refresh_launch_file
        config = launch_config
        env = read_launch["env"]
        config["env"] = env if env.is_a?(Hash)
        write_launch_file(config)
      end

      def warnings
        return [] unless File.file?(File.join(@source_dir, ".git"))

        ["chi runs from a linked git worktree (#{@source_dir}); the helper stops working once it is removed. " \
         "Install from the main checkout or a gem install."]
      end

      def info_plist
        ERB.new(File.read(File.join(SOURCES_DIR, "Info.plist.erb")))
           .result_with_hash(bundle_id: BUNDLE_ID, app_name: APP_NAME, executable: EXECUTABLE, version: @version)
      end

      # @yield [String] progress lines
      # @param login [Boolean] also start the app at login
      def install(force: false, login: false, &progress)
        raise Error, "already installed (#{app_version}); use chi desktop upgrade" if installed? && !force

        toolchain!
        quit if installed?
        progress&.call("building #{APP_NAME} #{@version} (can take a few minutes)…")
        built = build_app
        swap_in(built)
        write_launch_file
        register_app
        self.login = true if login
        progress&.call("installed #{app_path}")
        app_path
      end

      # Keeps the login item as it was.
      def upgrade(&)
        was_login = installed? && login == "enabled"
        install(force: true, login: was_login, &)
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
          service: dump.include?(BUNDLE_ID),
          running: running
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

      def read_launch
        launch = JSON.parse(File.read(launch_path))
        launch.is_a?(Hash) ? launch : {}
      rescue SystemCallError, JSON::ParserError
        {}
      end

      def launch_ok?(launch)
        argv = Array(launch["argv"])
        !argv.empty? && argv.all? { |path| File.exist?(path) }
      end

      def write_launch_file(config = launch_config)
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
