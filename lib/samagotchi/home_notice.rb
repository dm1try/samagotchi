# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require_relative "chi_home"
require_relative "installed_gem"
require_relative "paths"
require_relative "version"

module Samagotchi
  # One dim stderr line, at most once a day, when a person runs an installed
  # chi at a terminal from a Ruby that isn't the chi home's: "chi 0.131.0 on
  # /x/ruby; the chi home is /y/ruby (chi 0.132.0) (chi home doctor)". The
  # sessions it starts boot the home anyway; the line says which chi answered.
  # Never inside a worker's tools (SAMAGOTCHI_PROJECT_ENV), never for a
  # script (no TTY, --json, --non-interactive), never from a checkout.
  # The day is stamped in $XDG_STATE_HOME/samagotchi/home_noticed.
  module HomeNotice
    STAMP_FILE = "home_noticed"
    # Runs whose output a program reads, or that say this themselves.
    QUIET_COMMANDS = %w[home update self].freeze
    QUIET_FLAGS = %w[--json --non-interactive --version -h --help].freeze
    # Set in a worker's tools (ProjectEnv::MARKER_ENV) and in specs' test runs.
    QUIET_ENV = %w[SAMAGOTCHI_PROJECT_ENV SAMAGOTCHI_ENV RACK_ENV CI].freeze

    module_function

    # Prints the line when it is due. Cheap when it isn't: the TTY, argv
    # and env checks come first, then the stamp, then home.json.
    # @return [String, nil] the line printed
    def show(argv: ARGV, env: ENV, tty: $stdin.tty? && $stderr.tty?, io: $stderr,
             gem_spec: nil, today: Time.now.strftime("%Y-%m-%d"))
      return nil unless tty && !quiet_argv?(argv) && QUIET_ENV.none? { |key| env.key?(key) }

      stamp = File.join(Paths.state_dir(env: env), STAMP_FILE)
      return nil if stamped?(stamp, today)

      gem_spec ||= InstalledGem.spec
      text = gem_spec && mismatch(ChiHome.current(path: ChiHome.path(env: env), gem_spec: gem_spec))
      return nil unless text

      line = "#{text} (chi home doctor)"
      io.puts("\e[2m#{line}\e[0m")
      FileUtils.mkdir_p(File.dirname(stamp))
      File.write(stamp, "#{today}\n")
      line
    rescue StandardError
      nil
    end

    # This chi isn't the home's: the text, also chi home doctor's row; nil
    # when this process runs on +home+ (or there is none).
    # @return [String, nil]
    def mismatch(home, ruby: RbConfig.ruby, gem_dir: Gem.dir, version: VERSION)
      return nil if home.nil? || (home.running_here?(ruby: ruby, gem_dir: gem_dir) && home.newest_version.to_s == version)

      where = ruby
      # The same Ruby on other gems (a chruby GEM_HOME): name them both.
      if ChiHome.real(ruby) == ChiHome.real(home.ruby) && ChiHome.real(gem_dir) != ChiHome.real(home.gem_home)
        where = "#{ruby} (gems #{gem_dir})"
        home_where = "#{home.ruby} (gems #{home.gem_home})"
      end
      "chi #{version} on #{where}; the chi home is #{home_where || home.ruby} (chi #{home.newest_version})"
    end

    def quiet_argv?(argv)
      return true if QUIET_COMMANDS.include?(argv.first)

      argv.each_with_index.any? do |arg, i|
        QUIET_FLAGS.include?(arg) || arg == "--format=json" || (arg == "--format" && argv[i + 1] == "json")
      end
    end

    def stamped?(stamp, today)
      File.read(stamp, 32).to_s.strip == today
    rescue SystemCallError
      false
    end
  end
end
