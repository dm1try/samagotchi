# frozen_string_literal: true

require_relative "exit"

module Samagotchi
  module CLI
    # The usage side of a subcommand: its error lines, usage errors (exit 2)
    # and help. The including class sets @stdout and @stderr and defines
    # #command_name ("chi send"); its usage text is USAGE unless it
    # overrides #usage_text.
    module Command
      HELP_WORDS = %w[-h --help help].freeze

      private

      def usage_text = self.class::USAGE

      # What follows a usage error's line: the usage, or nil for a short
      # "(see chi … --help)" at the end of the line instead.
      def usage_on_error = usage_text

      # stderr isn't buffered, stdout is when it's a pipe: flush the lines
      # already printed, so the output keeps the order of the ids given.
      def error_line(text)
        @stdout.flush
        @stderr.puts(text)
      end

      # @return [Integer] the usage exit status
      def usage_error(message)
        usage = usage_on_error
        error_line("#{command_name}: #{message}#{usage ? "" : " (see #{command_name} --help)"}")
        @stderr.puts(usage) if usage
        Exit::USAGE
      end

      # +argv+ through +flags+ (a Flags), help and usage errors done.
      # @return [Flags::Result, Integer] the result, or the exit status
      #   after the help (0) or a usage error (2)
      def parse_flags(flags, argv, defaults = {})
        parsed = flags.parse(argv, defaults)
        if parsed.help
          @stdout.puts(usage_text)
          return 0
        end
        return usage_error(parsed.error.message) if parsed.error

        parsed
      end
    end
  end
end
