# frozen_string_literal: true

require_relative "cli/command"
require_relative "cli/flags"
require_relative "desktop"

module Samagotchi
  # `chi desktop install|upgrade|uninstall|status`: the native helper that
  # sends selected text (or images) to sessions, live, stopped or new, as a
  # message or a context note (macOS for now).
  class DesktopCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi desktop <install|upgrade|uninstall|status>
        install [--force] [--login]
                           build "Chi Helper" into ~/Applications (needs the Command Line Tools)
                           and start it: Services > "Send to chi", or ⌃⌥⌘N with the clipboard,
                           sends text or images to a session (live, stopped or new) as a
                           message (⏎) or a context note (⌘⏎). --login: start it at login
                           too (else it runs until you log out)
        upgrade            rebuild it for this chi and restart it (chi update does this only
                           when its sources changed)
        uninstall          remove it, its settings and its launch file
        status             installed version, how it runs chi, Service and process state
    TEXT

    SUBCOMMANDS = %w[install upgrade uninstall status].freeze

    # --no-register (hidden) on each; --help is an unknown option after the
    # subcommand.
    FLAGS = CLI::Flags.new(args: false) { |f| f.switch "--no-register" }
    INSTALL_FLAGS = CLI::Flags.new(args: false) do |f|
      f.switch "--no-register"
      f.switch "--force"
      f.switch "--login"
    end

    # @param platform [#call] register: → a Desktop::MacOS-like object
    def initialize(argv, stdout: $stdout, stderr: $stderr, platform: nil, supported: Desktop.supported?)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @platform = platform || Desktop::MacOS.method(:from_config)
      @supported = supported
    end

    # @return [Integer] 0 ok, 1 failed, 2 usage
    def run
      sub = @argv.shift
      if sub.nil? || HELP_WORDS.include?(sub)
        @stdout.puts(USAGE)
        return 0
      end
      return usage_error("unknown subcommand #{sub}") unless SUBCOMMANDS.include?(sub)

      unless @supported
        @stderr.puts("chi desktop supports macOS only for now")
        return 1
      end

      options = parse(sub)
      return options if options.is_a?(Integer)

      # --no-register (hidden): no pbs/lsregister/open/pkill, for installs
      # into temp dirs (HOME=…) that must not touch the real Services.
      helper = @platform.call(register: !options[:no_register])
      send(sub.to_sym, helper, options)
    rescue Desktop::MacOS::Error => e
      @stderr.puts("chi desktop: #{e.message}")
      1
    end

    private

    def command_name = "chi desktop"

    # @return [Hash, Integer] the options, or the usage error's exit status
    def parse(sub)
      parsed = (sub == "install" ? INSTALL_FLAGS : FLAGS).parse(@argv)
      return usage_error(parsed.error.message) if parsed.error

      parsed.options
    end

    # The warnings come after a done install: a refused or failed one
    # prints only its error.
    def install(helper, options)
      helper.install(force: options[:force] || false, login: options[:login] || false) { |line| @stdout.puts(line) }
      print_warnings(helper)
      0
    end

    def upgrade(helper, _options)
      helper.upgrade { |line| @stdout.puts(line) }
      print_warnings(helper)
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
                elsif s[:stale]
                  "#{s[:app_version] || "?"} (chi is #{s[:chi_version]}: chi update)"
                else
                  "#{s[:app_version] || "?"} (up to date: chi #{s[:chi_version]} changed nothing in it)"
                end
      launch = s[:launch_argv].empty? ? "(none)" : s[:launch_argv].join(" ")
      launch += s[:launch_ok] ? " (ok)" : " (missing: chi update)"
      dirs = s[:baked_dirs].empty? ? "(defaults)" : s[:baked_dirs].map { |name, value| "#{name}=#{value}" }.join(" ")
      service = s[:service] ? "registered" : "not registered (try chi desktop upgrade, or log out and back in)"
      running = s[:running] ? "running" : "not running (open -g \"#{s[:app_path]}\")"
      @stdout.puts(format_rows([["Chi Helper", version], ["app", s[:app_path]], ["runs chi", launch],
                                ["state dirs", dirs], ["service", service], ["hotkey", hotkey(s[:hotkey])],
                                ["process", running], ["at login", login(s[:login])]]))
      0
    end

    def hotkey(state)
      return "unknown (the app writes it when it starts)" unless state

      state["registered"] ? "#{state["keys"]} (clipboard)" : "#{state["keys"]} taken by another app"
    end

    def login(state)
      case state
      when "enabled" then "on"
      when "requiresApproval" then "waiting for approval in System Settings > General > Login Items"
      when nil then "unknown"
      else "off (chi desktop install --force --login)"
      end
    end

    def format_rows(rows)
      width = rows.map { |label, _| label.length }.max
      rows.map { |label, value| "#{label.ljust(width)}  #{value}" }.join("\n")
    end

    def print_warnings(helper)
      helper.warnings.each { |warning| @stderr.puts("warning: #{warning}") }
    end
  end
end
