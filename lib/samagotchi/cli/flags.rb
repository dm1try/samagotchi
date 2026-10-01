# frozen_string_literal: true

module Samagotchi
  module CLI
    # A subcommand's flags as a table (the subcommands bin/chi dispatches
    # before OptionParser): each flag's names, whether it takes a value
    # ("--flag V", or "--flag=V" for a long name) and whether it repeats.
    # #parse walks argv once, in order, and stops at the first help word or
    # error; what isn't a flag is a positional argument.
    #
    #   FLAGS = CLI::Flags.new(help: %w[-h --help help]) do |f|
    #     f.value "-m", "--message"
    #     f.value "--image", key: :images, repeat: true
    #     f.switch "--new"
    #   end
    #   FLAGS.parse(argv, images: []) # => Result
    class Flags
      Flag = Struct.new(:key, :value, :repeat, :set, :refusal, keyword_init: true)

      # kind :unknown (an undeclared flag, a switch given =V, or a
      # positional where none are taken), :missing (a value flag with no
      # value after it) or :refused (a flag declared with #refuse); +arg+ is
      # the argument as given.
      Error = Data.define(:kind, :arg, :refusal) do
        def message
          case kind
          when :unknown then "unknown option #{arg}"
          when :missing then "#{arg} needs a value"
          else refusal
          end
        end
      end

      # +options+ by key, +args+ the positionals in order; +help+ true when
      # a help word stopped the parse; +error+ nil or an Error.
      Result = Data.define(:options, :args, :help, :error)

      # @param help [Array<String>] words that stop the parse with help
      #   (not when they are a flag's value)
      # @param flag_pattern [Regexp] what an undeclared flag looks like (an
      #   unknown option); other arguments are positionals
      # @param dash_values [Boolean] false: a value flag followed by a
      #   "--…" argument has no value
      # @param args [Boolean] false: a positional is an unknown option
      def initialize(help: [], flag_pattern: /\A-/, dash_values: true, args: true)
        @help = help
        @flag_pattern = flag_pattern
        @dash_values = dash_values
        @args = args
        @flags = {}
        yield self if block_given?
      end

      # A flag without a value: options[key] = +set+. The key defaults to
      # the last name without its dashes, snake_cased.
      def switch(*names, key: nil, set: true)
        add(names, Flag.new(key: key, value: false, set: set))
      end

      # A flag with a value; +repeat+: options[key] collects them in an array.
      def value(*names, key: nil, repeat: false)
        add(names, Flag.new(key: key, value: true, repeat: repeat))
      end

      # A flag that is an error, with +message+ (a flag that doesn't exist
      # on purpose).
      def refuse(*names, message)
        add(names, Flag.new(refusal: message))
      end

      # @param defaults [Hash] the options before any flag (not changed)
      # @return [Result]
      def parse(argv, defaults = {})
        options = defaults.dup
        args = []
        rest = argv.dup
        until rest.empty?
          arg = rest.shift
          return Result.new(options: options, args: args, help: true, error: nil) if @help.include?(arg)

          name, inline = arg.start_with?("--") && arg.include?("=") ? arg.split("=", 2) : [arg, nil]
          flag = @flags[name]
          flag = nil if inline && !flag&.value
          unless flag
            return failure(options, args, :unknown, arg) if !@args || arg.match?(@flag_pattern)

            args << arg
            next
          end
          return failure(options, args, :refused, arg, flag.refusal) if flag.refusal
          next options[flag.key] = flag.set unless flag.value

          unless inline
            return failure(options, args, :missing, arg) if rest.empty? || (!@dash_values && rest.first.start_with?("--"))

            inline = rest.shift
          end
          options[flag.key] = flag.repeat ? [*options[flag.key], inline] : inline
        end
        Result.new(options: options, args: args, help: false, error: nil)
      end

      private

      def add(names, flag)
        flag.key ||= names.last.sub(/\A-+/, "").tr("-", "_").to_sym unless flag.refusal
        names.each { |name| @flags[name] = flag }
        self
      end

      def failure(options, args, kind, arg, refusal = nil)
        Result.new(options: options, args: args, help: false, error: Error.new(kind: kind, arg: arg, refusal: refusal))
      end
    end
  end
end
