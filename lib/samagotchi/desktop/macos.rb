# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require_relative "../version"
require_relative "../self_report"

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
      Error = Class.new(StandardError)

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

      # Runs a command without a shell; [output, success].
      class Runner
        def run(argv)
          output, status = Open3.capture2e(*argv)
          [output, status.success?]
        rescue SystemCallError => e
          [e.message, false]
        end
      end

      attr_reader :app_dir, :support_dir

      def initialize(app_dir: nil, support_dir: nil, env: ENV, runner: Runner.new,
                     source_dir: SelfReport::SOURCE_DIR, ruby: RbConfig.ruby, version: VERSION,
                     arch: nil, sources_dir: SOURCES_DIR, register: true)
        home = env["HOME"] || Dir.home
        @app_dir = app_dir || File.join(home, "Applications")
        @support_dir = support_dir || File.join(home, "Library", "Application Support", APP_NAME)
        @env = env
        @runner = runner
        @source_dir = source_dir
        @ruby = ruby
        @version = version
        @arch = arch
        @sources_dir = sources_dir
        @register = register
      end

      def app_path = File.join(@app_dir, "#{APP_NAME}.app")
      def launch_path = File.join(@support_dir, "launch.json")
      def installed? = File.directory?(app_path)

      # What the helper runs: absolute ruby + this chi's bin/chi (no shims,
      # which need the shell's PATH), and the allowlisted env.
      def launch_config
        env = { "LANG" => LANG }
        ENV_ALLOWLIST.each { |name| env[name] = @env[name] unless @env[name].to_s.empty? }
        { "version" => @version, "argv" => [@ruby, File.join(@source_dir, "bin", "chi")], "env" => env }
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
      def install(force: false, &progress)
        raise Error, "already installed (#{app_version}); use chi desktop upgrade" if installed? && !force

        toolchain!
        progress&.call("building #{APP_NAME} #{@version} (can take a few minutes)…")
        built = build_app
        swap_in(built)
        write_launch_file
        register_app
        progress&.call("installed #{app_path}")
        app_path
      end

      def upgrade(&progress)
        quit
        install(force: true, &progress)
      end

      # @return [Boolean] false when there was nothing to remove
      def uninstall
        return false unless installed? || File.exist?(@support_dir)

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

        launch = (JSON.parse(File.read(launch_path)) rescue nil)
        argv = launch.is_a?(Hash) ? Array(launch["argv"]) : []
        env = launch.is_a?(Hash) && launch["env"].is_a?(Hash) ? launch["env"] : {}
        dump, = @runner.run([PBS, "-dump"])
        _, running = @runner.run(["pgrep", "-x", EXECUTABLE])
        result.merge(
          app_version: app_version,
          launch_argv: argv,
          launch_ok: !argv.empty? && argv.all? { |path| File.exist?(path) },
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

      def write_launch_file
        FileUtils.mkdir_p(@support_dir)
        tmp = "#{launch_path}.tmp"
        File.write(tmp, JSON.pretty_generate(launch_config) + "\n")
        File.rename(tmp, launch_path)
      end

      def register_app
        return unless @register

        @runner.run([PBS, "-update"])
        @runner.run([LSREGISTER, "-f", app_path])
        @runner.run(["open", "-g", app_path])
      end

      def quit
        @runner.run(["pkill", "-x", EXECUTABLE]) if @register
      end
    end
  end
end
