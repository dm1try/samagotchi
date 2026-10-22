# frozen_string_literal: true

require_relative "../../cli/exit"
require_relative "../../cli/flags"
require_relative "../../session_config"
require_relative "../../thinking"
require_relative "sandbox"
require_relative "run"
require_relative "trace"
require_relative "render"

module Samagotchi
  class BundleCommand
    module Try
      # `chi bundle try PATH -p TEXT [options]` (docs/cli.md, "Trying a
      # bundle"): checks the arguments, then installs PATH in a Sandbox, runs
      # one turn (Run), stops what the run left (Sandbox#stop_leftovers),
      # reads its Trace and prints it (Render). BundleCommand parses the
      # flags (FLAGS, HELP) and hands the result to #run.
      class Command
        HELP = <<~TEXT
          Usage: chi bundle try PATH -p TEXT [--model NAME] [--memory NAME] [--mute NAME] [--toolkit NAME]
                 [--thinking LEVEL] [--set KEY=VALUE] [--json] [--keep] [--timeout SECONDS]

            Install PATH and run one non-interactive turn in an isolated temporary config, state and work directory.
            The user's hosts, keys and ordinary runtime settings are retained; their bundles, hooks, guardrails,
            memories, prompt additions, sessions and attached context sources are not. Shipped guardrails and a
            $1 cost cap are installed for the run. --set KEY=VALUE sets the tried bundle's config.yml bundles entry;
            --set cost-cap.cap=N overrides the cap (unlike chi --set BUNDLE.KEY=VALUE, these are config settings).
            --memory and --mute accept comma-separated names and repeat. --keep retains the sandbox and debug log.
            --json prints the experimental machine-readable trace.
            Exit status: child turn's status; 1 on install failure or timeout; 2 for usage; 130 on Ctrl-C.
        TEXT
        FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A-/) do |f|
          f.value "-p", "--prompt", key: :prompt
          f.value "--model"
          f.value "--memory", repeat: true
          f.value "--mute", repeat: true
          f.value "--toolkit"
          f.value "--thinking"
          f.value "--set", repeat: true
          f.switch "--json"
          f.switch "--keep"
          f.value "--timeout"
          f.refuse "--attach", "--shared", "chi bundle try can't use --attach or --shared"
        end
        DEFAULT_TIMEOUT = 300
        # The sandbox's cost-cap bundle setting (--set cost-cap.cap=N).
        COST_CAP_KEY = "cost-cap.cap"
        DEFAULT_COST_CAP = 1
        # The tried bundle's --set values, and the cap for the run.
        Settings = Data.define(:bundle, :cost_cap, :cost_cap_override)

        def initialize(stdout:, stderr:)
          @stdout = stdout
          @stderr = stderr
        end

        # @param parsed [CLI::Flags::Result] FLAGS' parse of the arguments
        # @return [Integer] exit status
        def run(parsed)
          options = parsed.options
          path = checked_path(parsed) or return CLI::Exit::USAGE
          timeout = parse_timeout(options[:timeout]) or return CLI::Exit::USAGE
          settings = parse_settings(Array(options[:set])) or return CLI::Exit::USAGE

          try(path, options, timeout, settings)
        end

        private

        def try(path, options, timeout, settings)
          render = Render.new(stdout: @stdout, stderr: @stderr)
          sandbox = nil
          begin
            sandbox = Sandbox.new(path, settings: settings.bundle, cost_cap: settings.cost_cap,
                                        cost_cap_override: settings.cost_cap_override)
            sandbox.install
            result = Run.new(sandbox).run(prompt: options[:prompt], options: options, timeout: timeout)
            # Before the trace: a delegate's worker saves its session as it stops.
            sandbox.stop_leftovers
            trace = TraceReader.new(state_home: sandbox.state_home, session_id: result.session_id)
                               .read(exit_code: result.exit_status, answer: result.stdout, stderr: result.stderr,
                                     sandbox: options[:keep] ? sandbox.root : nil, timed_out: result.timed_out)
            render.trace(trace, json: options[:json], child_stderr: result.stderr)
            @stderr.puts "chi bundle try: timed out after #{timeout} seconds" if result.timed_out
            result.exit_status
          rescue Sandbox::Error => e
            @stderr.puts e.message
            e.status
          ensure
            if options[:keep] && sandbox
              sandbox.stop_leftovers
              render.sandbox(sandbox)
            end
            sandbox&.cleanup unless options[:keep]
          end
        end

        # @return [String, nil] PATH, or nil after saying what's wrong
        def checked_path(parsed)
          options = parsed.options
          if options[:prompt].nil? || parsed.args.size != 1
            @stderr.puts "Usage: chi bundle try PATH -p TEXT [options]"
            return nil
          end
          path = parsed.args.first
          unless File.directory?(path)
            @stderr.puts "chi bundle try: #{path} isn't a folder"
            return nil
          end
          if options.values_at(:model, :toolkit, :thinking, :memory, :mute).flatten.compact.any?(&:empty?)
            @stderr.puts "chi bundle try: model, toolkit, thinking, memory and mute values cannot be empty"
            return nil
          end
          if options[:thinking] && !Thinking::LEVELS.map(&:to_s).include?(options[:thinking])
            @stderr.puts "chi bundle try: --thinking takes #{Thinking::LEVELS.join(", ")}, not #{options[:thinking]}"
            return nil
          end
          path
        end

        def parse_timeout(value)
          return DEFAULT_TIMEOUT unless value

          timeout = Float(value)
          return timeout if timeout.positive? && timeout.finite?

          @stderr.puts "chi bundle try: --timeout must be a positive number"
          nil
        rescue ArgumentError
          @stderr.puts "chi bundle try: --timeout must be a positive number"
          nil
        end

        # The --set KEY=VALUE pairs, typed as SessionConfig.typed:
        # cost-cap.cap is the run's cap, the others the tried bundle's.
        # @return [Settings, nil] nil after saying what's wrong
        def parse_settings(pairs)
          bundle = {}
          cost_cap = DEFAULT_COST_CAP
          override = false
          pairs.each do |pair|
            key, sep, value = pair.partition("=")
            if key == COST_CAP_KEY && !sep.empty?
              cost_cap = SessionConfig.typed(value)
              override = true
              next if (cost_cap.is_a?(Numeric) && cost_cap >= 0) || cost_cap == false

              @stderr.puts "chi bundle try: --set #{COST_CAP_KEY} takes a non-negative number or off"
              return nil
            end
            unless !sep.empty? && key.match?(SessionConfig::KEY)
              @stderr.puts "chi bundle try: --set takes KEY=VALUE, not #{pair}"
              return nil
            end
            bundle[key] = SessionConfig.typed(value)
          end
          Settings.new(bundle: bundle, cost_cap: cost_cap, cost_cap_override: override)
        end
      end
    end
  end
end
