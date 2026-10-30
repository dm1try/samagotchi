# frozen_string_literal: true

require "rbconfig"
require_relative "chi_home"
require_relative "home_doctor"
require_relative "home_notice"
require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "installed_gem"
require_relative "paths"
require_relative "version"

module Samagotchi
  # `chi home`: the chi home (ChiHome), the Ruby every chi launch boots.
  # Shows it, sets it (`chi home set [--ruby PATH]`), and checks it
  # (`chi home doctor`, HomeDoctor's rows).
  class HomeCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi home [set [--ruby PATH] | doctor]
        (none)            show the chi home: its Ruby, the chi it runs, its gem home and path, mise
        set               record this chi's Ruby and gem path as the home (a chruby shell's
                          GEM_HOME/GEM_PATH are part of it)
        set --ruby PATH   record that Ruby (its own gem dirs) as the home; it must have samagotchi
                          (gem install samagotchi with it first)
        doctor            check the home (its Ruby is there and has samagotchi) and what should
                          follow it: this chi, the last worker boot, the desktop helper, sessions,
                          the tools' chi script, this project's Gemfile.lock, mise and the last
                          worker's project env
        Every chi launch (workers, chi web's restart and Update, the macOS helper's next
        chi desktop install or upgrade) boots the home's Ruby with the home's gems. Saved in
        #{Paths.tilde(ChiHome.path)}.
    TEXT

    SUBCOMMANDS = %w[set doctor].freeze
    FLAGS = {
      nil => CLI::Flags.new(help: HELP_WORDS, args: false),
      "set" => CLI::Flags.new(help: HELP_WORDS, args: false) { |f| f.value "--ruby" },
      "doctor" => CLI::Flags.new(help: HELP_WORDS, args: false)
    }.freeze

    # @param path [String] home.json
    # @param probe [#call] (ruby) → ChiHome::Record or nil (ChiHome.probe)
    # @param doctor [#call] (home) → HomeDoctor
    # @param bundler [Boolean, nil] running under Bundler (nil: found out)
    def initialize(argv, stdout: $stdout, stderr: $stderr, path: ChiHome.path, gem_spec: InstalledGem.spec,
                   env: ENV, probe: nil, doctor: nil, bundler: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @path = path
      @gem_spec = gem_spec
      @env = env
      @bundler = bundler.nil? ? ChiHome.under_bundler?(env) : bundler
      @probe = probe || ->(ruby) { ChiHome.probe(ruby, env: env) }
      @doctor = doctor || lambda { |home|
        HomeDoctor.new(home: home, env: env, gem_spec: gem_spec, helper: HomeDoctor.default_helper(env: env))
      }
    end

    # @return [Integer] 0, 1 (no usable home, a refusal), 2 usage
    def run
      @sub = SUBCOMMANDS.include?(@argv.first) ? @argv.first : nil
      parsed = parse_flags(FLAGS.fetch(@sub), @sub ? @argv[1..] : @argv)
      return parsed if parsed.is_a?(Integer)

      case @sub
      when "set" then run_set(parsed.options)
      when "doctor" then run_doctor
      else run_show
      end
    rescue ChiHome::Invalid => e
      error_line("#{command_name}: #{e.message} (chi home set rewrites it)")
      CLI::Exit::FAILED
    rescue ChiHome::UnderBundler => e
      error_line("#{command_name}: #{e.message}")
      CLI::Exit::FAILED
    end

    private

    def command_name = @sub ? "chi home #{@sub}" : "chi home"
    def usage_on_error = nil

    def run_show
      home = ChiHome.read(path: @path)
      unless home
        @stdout.puts("no chi home: chi launches on the Ruby that starts it (chi home set records this one, #{running_ruby})")
        return CLI::Exit::OK
      end

      rows(home).each { |label, value| @stdout.puts("#{label.ljust(9)} #{value}") }
      problem = ChiHome.problem(home)
      @stdout.puts("problem   #{problem} (chi home doctor)") if problem
      problem ? CLI::Exit::FAILED : CLI::Exit::OK
    end

    def rows(home)
      list = [["ruby", home.ruby], ["chi", home.newest_version&.to_s || "none"], ["gem home", home.gem_home],
              ["gem path", home.gem_path], ["mise", home.mise || "none"],
              ["set", "#{home.set_at} by chi #{home.set_by_version}"]]
      list << ["running", "chi #{VERSION} on #{running_ruby}"] unless running_home?(home)
      list
    end

    def running_home?(home) = @gem_spec && HomeNotice.home?(home)

    def running_ruby = "#{RbConfig.ruby}#{" (a checkout)" unless @gem_spec}"

    def run_set(options)
      home = options[:ruby] ? probed(options[:ruby]) : running_record
      return CLI::Exit::FAILED unless home

      if (problem = ChiHome.problem(home))
        error_line("#{command_name}: #{problem}: gem install samagotchi with #{home.ruby} first")
        return CLI::Exit::FAILED
      end

      ChiHome.write!(home, path: @path)
      @stdout.puts("chi home set to #{home.ruby} (chi #{home.newest_version}); new workers and launches boot it")
      CLI::Exit::OK
    rescue SystemCallError => e
      error_line("#{command_name}: couldn't write #{Paths.tilde(@path)}: #{e.message}")
      CLI::Exit::FAILED
    end

    # The home a --ruby names: this one's (with this shell's gem path) when
    # it is the running Ruby, else asked of it.
    def probed(ruby)
      path = File.expand_path(ruby)
      unless File.file?(path) && File.executable?(path)
        error_line("#{command_name}: no Ruby at #{ruby}")
        return nil
      end
      return running_record if ChiHome.real(path) == ChiHome.real(RbConfig.ruby)

      home = @probe.call(path)
      error_line("#{command_name}: #{ruby} didn't answer as a Ruby") unless home
      home
    end

    # This process's Ruby and gem path, never under Bundler (the bundle's
    # gems). Another Ruby is probed with Bundler's variables unset.
    # @raise [ChiHome::UnderBundler]
    def running_record
      raise ChiHome::UnderBundler if @bundler

      ChiHome.from_running(env: @env)
    end

    # The home's rows and what should follow it (HomeDoctor); exit 1 when
    # one fails.
    def run_doctor
      rows = @doctor.call(ChiHome.read(path: @path)).rows
      rows.each { |row| @stdout.puts(row.to_s) }
      rows.any? { |row| row.status == :fail } ? CLI::Exit::FAILED : CLI::Exit::OK
    end
  end
end
