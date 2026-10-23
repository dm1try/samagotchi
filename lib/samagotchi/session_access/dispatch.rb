# frozen_string_literal: true

require_relative "../session_access"
require_relative "contract"
require_relative "../remotes"
require_relative "../cli/exit"

module Samagotchi
  module SessionAccess
    # bin/chi's front for chi --remote NAME … and CHI_REMOTE=NAME: takes the
    # flag off the front of the arguments (before the subcommand lookup),
    # names the remote (the flag beats the env; no default remote), refuses
    # what runs on this machine only (Contract) and runs a session command
    # with a Remote for its SessionAccess. chi remote itself, --version and
    # --help always run here.
    class Dispatch
      FLAG = "--remote"
      ENV_KEY = "CHI_REMOTE"
      # Run here whatever the remote: chi remote manages the remotes.
      ALWAYS_HERE = %w[remote].freeze
      # bin/chi's own words besides its SUBCOMMANDS (a refusal names them).
      OWN_WORDS = %w[web scratch self].freeze
      HELP = %w[--version -h --help].freeze
      # The run flags (not subcommands) a refusal names: remote attach is
      # its own phase (P4).
      RUN_FLAGS = { "--attach" => "--attach", "--resume" => "--resume", "-p" => "-p", "--prompt" => "-p",
                    "--shared" => "--shared", "--no-shared" => "--no-shared" }.freeze

      # A usage error in the flag itself (--remote with no name, a bad one).
      class Usage < StandardError; end

      # The flag (any number of them at the front; the last wins) taken off
      # +argv+, and the remote it and +env+ name.
      # @return [Dispatch]
      # @raise [Usage]
      def self.from(argv, env: ENV)
        rest = argv.dup
        flag = nil
        while (arg = rest.first) && (arg == FLAG || arg.start_with?("#{FLAG}="))
          rest.shift
          flag = arg == FLAG ? rest.shift : arg.delete_prefix("#{FLAG}=")
          raise Usage, "#{FLAG} needs a remote's name (chi remote ls lists them)" if flag.nil? || flag.strip.empty? || flag.start_with?("-")
        end
        from_env = env.fetch(ENV_KEY, "").to_s.strip
        new(rest, remote: flag || (from_env.empty? ? nil : from_env))
      end

      attr_reader :argv, :remote

      def initialize(argv, remote:)
        @argv = argv
        @remote = remote
      end

      def remote? = !@remote.nil?

      # Whether the arguments run here as they would without a remote: chi
      # remote, --version, --help.
      def here?
        first = @argv.first
        ALWAYS_HERE.include?(first) || (@argv.size == 1 && HELP.include?(first))
      end

      # The one refusal of a command or flag that runs on this machine only,
      # or nil when the Contract lets it run against the remote.
      # @return [String, nil]
      def refusal
        words = local_words or return nil

        "chi #{words} runs on this machine only: run it on #{@remote}"
      end

      # The session command against the remote: refused (exit 2), or run
      # with a Remote. A failure to reach it is the command's line, exit 1.
      # @param subcommands [Hash] bin/chi's SUBCOMMANDS
      # @return [Integer] the exit status
      def run(subcommands, stderr: $stderr, transport: nil)
        command = @argv.first
        unless command.nil? || command.start_with?("-") || subcommands.key?(command) || OWN_WORDS.include?(command)
          stderr.puts("Error: unknown command #{command} (see chi --help)")
          return CLI::Exit::FAILED
        end
        if (message = refusal)
          stderr.puts("Error: #{message}")
          return CLI::Exit::USAGE
        end

        entry = Remotes.find(Remotes.check_name!(@remote))
        path, klass = subcommands.fetch(@argv.first)
        require path
        access = Remote.new(entry, transport: transport)
        Samagotchi.const_get(klass).new(@argv[1..] || [], access: access).run
      rescue Remotes::Invalid => e
        stderr.puts("Error: #{e.message}")
        CLI::Exit::USAGE
      rescue RemoteFailed => e
        stderr.puts("chi #{@argv.first}: #{e.message}")
        CLI::Exit::FAILED
      end

      private

      # The words that run here only: the command (and its subcommand, a
      # flag) the Contract lists local_only, a machine command, or the run
      # flags (a session in this terminal, attach). nil: supported.
      def local_words
        command = @argv.first
        return run_words if command.nil? || command.start_with?("-")
        return command if Contract::MACHINE.include?(command) || Contract.status(command).nil?
        return command if Contract.status(command) == Contract::LOCAL_ONLY

        sub = @argv[1] if Contract::TABLE.key?("#{command} #{@argv[1]}")
        return "#{command} #{sub}" if sub && Contract.status(command, sub) == Contract::LOCAL_ONLY

        prefix = [command, sub].compact
        flags.each do |flag|
          return [*prefix, flag].join(" ") if Contract.status(*prefix, flag) == Contract::LOCAL_ONLY
        end
        nil
      end

      # The long flags given, up to a "--".
      def flags
        @argv.drop(1).take_while { |arg| arg != "--" }.select { |arg| arg.start_with?("--") }.map { |arg| arg.split("=", 2).first }
      end

      def run_words
        flag = @argv.take_while { |arg| arg != "--" }.map { |arg| arg.split("=", 2).first }.find { |arg| RUN_FLAGS.key?(arg) }
        flag ? RUN_FLAGS[flag] : "(a session in this terminal)"
      end
    end
  end
end
