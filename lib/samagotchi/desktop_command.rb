# frozen_string_literal: true

require_relative "desktop"

module Samagotchi
  # `chi desktop install|upgrade|uninstall|status`: the native helper that
  # sends selected text to live sessions as a context note (macOS for now).
  class DesktopCommand
    USAGE = <<~TEXT
      Usage: chi desktop <install|upgrade|uninstall|status>
        install [--force]  build "Chi Helper" into ~/Applications (needs the Command Line Tools)
                           and start it: Services > "Send to chi" and a hotkey send text to
                           a live session as a context note
        upgrade            rebuild it for this chi and restart it
        uninstall          remove it, its settings and its launch file
        status             installed version, how it runs chi, Service and process state
    TEXT

    SUBCOMMANDS = %w[install upgrade uninstall status].freeze

    # @param platform [#call] register: → a Desktop::MacOS-like object
    def initialize(argv, stdout: $stdout, stderr: $stderr, platform: nil, supported: Desktop.supported?)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @platform = platform || ->(register:) { Desktop::MacOS.new(register: register) }
      @supported = supported
    end

    # @return [Integer] 0 ok, 1 failed, 2 usage
    def run
      sub = @argv.shift
      if sub.nil? || %w[-h --help help].include?(sub)
        @stdout.puts(USAGE)
        return 0
      end
      return usage_error("unknown subcommand #{sub}") unless SUBCOMMANDS.include?(sub)

      unless @supported
        @stderr.puts("chi desktop supports macOS only for now")
        return 1
      end

      options = parse(sub) or return 2
      # --no-register (hidden): no pbs/lsregister/open/pkill, for installs
      # into temp dirs (HOME=…) that must not touch the real Services.
      helper = @platform.call(register: !options[:no_register])
      send(sub.to_sym, helper, options)
    rescue Desktop::MacOS::Error => e
      @stderr.puts("chi desktop: #{e.message}")
      1
    end

    private

    # @return [Hash, nil] nil after a usage error
    def parse(sub)
      flags = { "--no-register" => :no_register }
      flags["--force"] = :force if sub == "install"
      @argv.each_with_object({}) do |arg, options|
        unless flags.key?(arg)
          usage_error("unknown option #{arg}")
          return nil
        end
        options[flags[arg]] = true
      end
    end

    def install(helper, options)
      print_warnings(helper)
      helper.install(force: options[:force] || false) { |line| @stdout.puts(line) }
      0
    end

    def upgrade(helper, _options)
      print_warnings(helper)
      helper.upgrade { |line| @stdout.puts(line) }
      0
    end

    def uninstall(helper, _options)
      @stdout.puts(helper.uninstall ? "removed Chi Helper" : "Chi Helper is not installed")
      0
    end

    def status(helper, _options)
      s = helper.status
      unless s[:installed]
        @stdout.puts(format_rows([["Chi Helper", "not installed (chi desktop install)"], ["app", s[:app_path]]]))
        return 0
      end

      version = if s[:app_version] == s[:chi_version]
                  "#{s[:app_version]} (matches chi)"
                else
                  "#{s[:app_version] || "?"} (chi is #{s[:chi_version]}: chi desktop upgrade)"
                end
      launch = s[:launch_argv].empty? ? "(none)" : s[:launch_argv].join(" ")
      launch += s[:launch_ok] ? " (ok)" : " (missing: chi desktop upgrade)"
      dirs = s[:baked_dirs].empty? ? "(defaults)" : s[:baked_dirs].map { |name, value| "#{name}=#{value}" }.join(" ")
      service = s[:service] ? "registered" : "not registered (try chi desktop upgrade, or log out and back in)"
      running = s[:running] ? "running" : "not running (open -g \"#{s[:app_path]}\")"
      @stdout.puts(format_rows([["Chi Helper", version], ["app", s[:app_path]], ["runs chi", launch],
                                ["state dirs", dirs], ["service", service], ["process", running]]))
      0
    end

    def format_rows(rows)
      width = rows.map { |label, _| label.length }.max
      rows.map { |label, value| "#{label.ljust(width)}  #{value}" }.join("\n")
    end

    def print_warnings(helper)
      helper.warnings.each { |warning| @stderr.puts("warning: #{warning}") }
    end

    def usage_error(message)
      @stderr.puts("chi desktop: #{message}")
      @stderr.puts(USAGE)
      2
    end
  end
end
