# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "time"
require_relative "atomic_file"
require_relative "installed_gem"
require_relative "log"
require_relative "paths"
require_relative "version"

module Samagotchi
  # The chi home: the one Ruby (and its gem path) every chi launch boots,
  # whoever launches it (a terminal on another Ruby, chi web, the macOS
  # helper under launchd). Recorded in home.json under the config dir
  # ($XDG_CONFIG_HOME/samagotchi/home.json) by `chi home set`, or once, the
  # first time, by chi bootstrap or chi update (#record_first!); never
  # overwritten implicitly.
  #
  # One mechanism (docs/architecture.md, "How chi launches itself"):
  # Record#boot_argv puts `Gem.paths = {…}` at the front of a `ruby -e`
  # boot string, so no GEM_HOME/GEM_PATH ever goes into an environment
  # (the tools a worker runs keep the spawner's, or the project's). Every
  # launch site asks #current at launch time and keeps its own argv when
  # there is no usable home.
  module ChiHome
    FILE = "home.json"
    # What a launch outside a worker boots: the newest chi in the home,
    # run as its own `chi` executable (ARGV after the "--").
    CHI_BOOT = "gem 'samagotchi', '>= 0.a'; load Gem.bin_path('samagotchi', 'chi')"
    # Where `mise` usually is when PATH doesn't have it (launchd's bare PATH).
    MISE_DIRS = ["/opt/homebrew/bin", "/usr/local/bin", File.join(Dir.home, ".local", "bin")].freeze
    # What a probe of another Ruby must not inherit: they would move it off
    # its own gems.
    PROBE_UNSET = %w[GEM_HOME GEM_PATH RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH].freeze
    PROBE = "require 'json'; print JSON.generate('ruby' => RbConfig.ruby, 'gem_home' => Gem.dir, " \
            "'gem_path' => Gem.path.join(File::PATH_SEPARATOR))"
    GEMSPEC = /\Asamagotchi-(#{Gem::Version::VERSION_PATTERN})\.gemspec\z/

    class Invalid < StandardError
    end

    # home.json's fields. +gem_path+ is what `Gem.paths=` takes (dirs joined
    # by File::PATH_SEPARATOR); +mise+ an absolute path or nil.
    Record = Data.define(:ruby, :gem_home, :gem_path, :mise, :set_at, :set_by_version) do
      # home.json's (or a probe's) fields, checked: ruby, gem_home and every
      # gem_path entry absolute paths, mise an absolute path or nil.
      # @raise [Invalid]
      def self.from_h(hash)
        fields = members.to_h { |key| [key, hash[key.to_s]] }
        %i[ruby gem_home gem_path].each do |key|
          value = fields[key]
          raise Invalid, "#{key} is missing" unless value.is_a?(String) && !value.empty?
        end
        raise Invalid, "ruby is not an absolute path" unless fields[:ruby].start_with?("/")
        raise Invalid, "gem_home is not an absolute path" unless fields[:gem_home].start_with?("/")

        dirs = fields[:gem_path].split(File::PATH_SEPARATOR)
        raise Invalid, "gem_path has a relative entry" unless dirs.all? { |dir| dir.start_with?("/") }

        mise = fields[:mise]
        raise Invalid, "mise is not an absolute path" unless mise.nil? || (mise.is_a?(String) && mise.start_with?("/"))

        new(**fields)
      end

      def to_h = members.to_h { |key| [key.to_s, public_send(key)] }
      def gem_dirs = gem_path.split(File::PATH_SEPARATOR).reject(&:empty?)
      def spec_dirs = gem_dirs.map { |dir| File.join(dir, "specifications") }
      # The home Ruby's own gem command (its bindir, not a shim).
      def gem_bin = File.join(File.dirname(ruby), "gem")
      def ruby_ok? = File.file?(ruby) && File.executable?(ruby)

      # The samagotchi versions installed in the home, newest last.
      # @return [Array<Gem::Version>]
      def versions
        spec_dirs.flat_map do |dir|
          Dir.children(dir).filter_map { |name| GEMSPEC.match(name)&.[](1) }
        rescue SystemCallError
          []
        end.select { |v| Gem::Version.correct?(v) }.map { |v| Gem::Version.new(v) }.uniq.sort
      end

      def newest_version = versions.last

      # Whether a gem named +name+ is installed in the home.
      def gem?(name)
        spec_dirs.any? { |dir| !Dir.glob(File.join(dir, "#{name}-*.gemspec")).empty? }
      end

      # The `Gem.paths =` line every boot starts with: string literals only
      # (String#inspect escapes `#{`), no env read.
      def prelude = "Gem.paths = {'GEM_HOME' => #{gem_home.inspect}, 'GEM_PATH' => #{gem_path.inspect}}"

      # [ruby, "-e", "<prelude>; <run>"]: a site appends "--" and its args
      # when +run+ runs chi's executable (CHI_BOOT).
      def boot_argv(run:) = [ruby, "-e", "#{prelude}; #{run}"]

      # Whether this process runs on the home: its Ruby and its gem dir.
      def running_here?(ruby: RbConfig.ruby, gem_dir: Gem.dir)
        ChiHome.real(ruby) == ChiHome.real(self.ruby) && ChiHome.real(gem_dir) == ChiHome.real(gem_home)
      end
    end

    @warned = {}
    @warn_mutex = Mutex.new

    module_function

    # @return [String] $XDG_CONFIG_HOME/samagotchi/home.json
    def path(env: ENV) = File.join(Paths.config_home(env: env), Paths::APP_DIR, FILE)

    # The record as home.json has it, usable or not (chi home shows it);
    # nil without one.
    # @raise [Invalid] a file that isn't home.json's shape
    def read(path: self.path)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      raise Invalid, "#{Paths.tilde(path)} is not a JSON object" unless data.is_a?(Hash)

      Record.from_h(data)
    rescue JSON::ParserError, SystemCallError => e
      raise Invalid, "#{Paths.tilde(path)}: #{e.message.lines.first.to_s.strip}"
    rescue Invalid => e
      raise if e.message.start_with?(Paths.tilde(path))

      raise Invalid, "#{Paths.tilde(path)}: #{e.message}"
    end

    # The home every launch boots, or nil, where each site keeps its own
    # argv: no home.json; one that isn't its shape (warned once); its ruby
    # gone (a Ruby upgrade); no samagotchi in its gem path; or this chi
    # runs from a source checkout (a worktree's bin/chi spawns its own code).
    # @param gem_spec [Gem::Specification, nil] the installed gem this runs from
    # @return [Record, nil]
    def current(path: self.path, gem_spec: InstalledGem.spec)
      return nil unless gem_spec

      home = read(path: path)
      return nil unless home

      why = problem(home)
      why ? warn_once(:unusable, path: path, problem: why) : home
    rescue Invalid => e
      warn_once(:invalid, path: path, error: e.message)
    end

    # Why a recorded home can't boot chi, or nil.
    # @return [String, nil]
    def problem(home)
      return "home ruby missing: #{home.ruby}" unless home.ruby_ok?
      return "no samagotchi in the home's gems (#{home.gem_path})" if home.versions.empty?

      nil
    end

    # The home's boot, or nil without a usable home (#current).
    # @return [Array<String>, nil]
    def boot_argv(run:, home: current) = home&.boot_argv(run: run)

    # Where a gem install lands: the home's gem dir, else this process's
    # (UpdateCheck's writability).
    def gem_dir(gem_spec: InstalledGem.spec) = current(gem_spec: gem_spec)&.gem_home || Gem.dir

    # The specification dirs new workers activate chi from: the home's,
    # else this process's (InstalledVersions' "installed; restart").
    def spec_dirs(gem_spec: InstalledGem.spec) = current(gem_spec: gem_spec)&.spec_dirs || Gem::Specification.dirs

    # The gem command a gem install runs: the home's, else this Ruby's own.
    def gem_bin(home = current) = home ? home.gem_bin : File.join(RbConfig::CONFIG["bindir"], "gem")

    # The env for a gem install child (chi update, chi bootstrap's
    # commonmarker): into the home's gems whatever the spawner's
    # GEM_HOME/GEM_PATH say (a chruby shell, an old helper's launch file),
    # and with mise's dir on PATH (mise's rubygems plugin runs `mise
    # reshim` after an install). {} without a home: the env as today.
    # @return [Hash{String=>String}]
    def install_env(home = current, env: ENV)
      return {} unless home

      result = { "GEM_HOME" => home.gem_home, "GEM_PATH" => home.gem_path }
      if home.mise
        dirs = env["PATH"].to_s.split(File::PATH_SEPARATOR)
        mise_dir = File.dirname(home.mise)
        result["PATH"] = (dirs + [mise_dir]).uniq.join(File::PATH_SEPARATOR) unless dirs.include?(mise_dir)
      end
      result
    end

    # The fallback pin for a worker's `>= 0.a` (a broken newest install):
    # the spawner's own version when the home has it, else the home's
    # newest.
    # @return [String, nil]
    def fallback_version(home, gem_spec)
      versions = home.versions
      own = gem_spec && Gem::Version.new(gem_spec.version.to_s)
      (own && versions.include?(own) ? own : versions.last)&.to_s
    end

    # This process's Ruby and gem path as a record (chi home set without
    # --ruby, a first record from the running chi).
    def from_running(env: ENV)
      Record.new(ruby: real(RbConfig.ruby), gem_home: Gem.dir, gem_path: Gem.path.join(File::PATH_SEPARATOR),
                 mise: find_mise(env: env), set_at: Time.now.utc.iso8601, set_by_version: VERSION)
    end

    # Another Ruby's own gem dirs, asked of it (its GEM_*/RUBYOPT unset
    # unless +gem_env+ gives the GEM_HOME/GEM_PATH its chi lived under).
    # @param runner [#call] (env, argv) → [output, success]
    # @return [Record, nil] nil when it doesn't run or answer
    def probe(ruby, gem_env: {}, env: ENV, runner: method(:capture))
      child_env = PROBE_UNSET.to_h { |key| [key, nil] }.merge(gem_env.slice("GEM_HOME", "GEM_PATH").compact)
      output, ok = runner.call(child_env, [ruby, "-e", PROBE])
      return nil unless ok

      data = JSON.parse(output.to_s.lines.last.to_s)
      return nil unless data.is_a?(Hash)

      Record.from_h(data.merge("ruby" => data["ruby"].is_a?(String) ? real(data["ruby"]) : data["ruby"],
                               "mise" => find_mise(env: env), "set_at" => Time.now.utc.iso8601,
                               "set_by_version" => VERSION))
    rescue JSON::ParserError, TypeError, Invalid
      nil
    end

    # @raise [SystemCallError]
    def write!(home, path: self.path)
      FileUtils.mkdir_p(File.dirname(path))
      AtomicFile.write(path, "#{JSON.pretty_generate(home.to_h)}\n", perm: 0o644)
      home
    end

    # The first record, once, from an installed chi (chi bootstrap, chi
    # update): the macOS helper's ruby when its launch file names one that
    # has samagotchi (the Ruby it already runs), else this chi's. Never
    # over an existing home.json, never from a checkout, never a Ruby
    # without samagotchi.
    # @param launch_path [String, nil] the helper's launch.json
    # @return [Record, nil] the home written, nil when none was
    def record_first!(gem_spec: InstalledGem.spec, launch_path: nil, path: self.path, env: ENV,
                      runner: method(:capture))
      return nil unless gem_spec
      return nil if File.exist?(path)

      home = [helper_home(launch_path, env: env, runner: runner), from_running(env: env)]
             .compact.find { |candidate| problem(candidate).nil? }
      home && write!(home, path: path)
    rescue SystemCallError => e
      Log.warn(:config, "home_record_failed", error: e.class.name, msg: e.message)
      nil
    end

    # The helper's launch.json ruby (argv[0]) probed with the GEM_* it was
    # installed with; nil without one.
    def helper_home(launch_path, env:, runner:)
      return nil unless launch_path && File.file?(launch_path)

      launch = JSON.parse(File.read(launch_path))
      ruby = Array(launch["argv"]).first if launch.is_a?(Hash)
      return nil unless ruby.is_a?(String) && ruby.start_with?("/") && File.executable?(ruby)

      gem_env = launch["env"].is_a?(Hash) ? launch["env"] : {}
      probe(ruby, gem_env: gem_env, env: env, runner: runner)
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # mise's absolute path: on +env+'s PATH, else in MISE_DIRS; nil without.
    def find_mise(env: ENV)
      dirs = env["PATH"].to_s.split(File::PATH_SEPARATOR).select { |dir| dir.start_with?("/") } + MISE_DIRS
      dirs.map { |dir| File.join(dir, "mise") }.find { |file| File.file?(file) && File.executable?(file) }
    end

    def real(path)
      File.realpath(path)
    rescue SystemCallError, TypeError
      path.to_s
    end

    def capture(env, argv)
      output, status = Open3.capture2e(env, *argv)
      [output, status.success?]
    rescue SystemCallError => e
      [e.message, false]
    end

    # Logs a home that can't be used, once per process and reason; nil.
    def warn_once(event, **fields)
      key = [event, fields]
      first = @warn_mutex.synchronize { @warned[key] ? false : (@warned[key] = true) }
      Log.warn(:config, "home_#{event}", **fields) if first
      nil
    end

    # Specs: forget what was warned.
    def reset_warnings! = @warn_mutex.synchronize { @warned.clear }
  end
end
