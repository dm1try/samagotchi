# frozen_string_literal: true

require_relative "exit"

module Samagotchi
  module CLI
    # The usage side of a subcommand: its error lines, usage errors (exit 2)
    # and help, and its piped stdin. The including class sets @stdout and
    # @stderr (@stdin for #read_stdin) and defines #command_name ("chi
    # send"); its usage text is USAGE unless it overrides #usage_text.
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
        error_line("#{command_name}: #{message}#{" (see #{command_name} --help)" unless usage}")
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

      # The including class's @stdin, read only when it is a pipe or a
      # file. A terminal means nobody piped anything in, and a socket a
      # launcher or an agent's shell passes down may never close: waiting
      # on either would hang a script. (A pipe the caller never closes
      # still hangs, as it would for cat.)
      # @return [String, nil] nil for a terminal or a socket
      def read_stdin
        return nil if @stdin.respond_to?(:tty?) && @stdin.tty?

        if @stdin.respond_to?(:stat)
          stat = @stdin.stat
          return nil unless stat.pipe? || stat.file?
        end

        @stdin.read
      end

      # +text+ as UTF-8 whatever the locale says: with no LANG/LC_* (an app
      # started from Finder, launchd) stdin reads as US-ASCII and ARGV as
      # binary. Invalid bytes become U+FFFD rather than an error.
      def utf8(text)
        text&.dup&.force_encoding(Encoding::UTF_8)&.scrub
      end
    end
  end
end
