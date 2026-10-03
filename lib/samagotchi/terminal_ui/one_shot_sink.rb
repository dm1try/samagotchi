# frozen_string_literal: true

require_relative "formatting"

module Samagotchi
  class TerminalUI
    # The turn sink of `chi -p … --non-interactive` (Engine#run_turn's
    # on_event): the few lines a reader wants while the turn runs, on
    # stderr. stdout is the answer's alone, printed after the turn: a
    # script or a parent agent reads it.
    #
    # It prints the retry lines the REPL shows: the loop asking again after
    # an empty answer (:empty_answer_retry), and a generation retried after
    # a failed request (:generation_retrying).
    class OneShotSink
      include Formatting

      # @param err [IO, nil] nil writes to $stderr as it is at each write
      def initialize(err: nil)
        @err = err
      end

      def call(event)
        case event[:type]
        when :empty_answer_retry then line(format_empty_retry_line(event))
        when :generation_retrying then line(format_generation_retry_line(event))
        end
      end

      private

      def line(text)
        err.puts(text)
        err.flush
      end

      def err = @err || $stderr

      # Colour when stderr, where the lines go, is a colour terminal.
      def color_output?
        return false unless err.tty?
        return false if ENV.key?("NO_COLOR")

        ENV.fetch("TERM", "") != "dumb"
      end
    end
  end
end
