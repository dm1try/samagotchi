# frozen_string_literal: true

require_relative "formatting"
require_relative "event_renderer"

module Samagotchi
  class TerminalUI
    # The turn sink of `chi -p … --non-interactive` (Engine#run_turn's
    # on_event): the few lines a reader wants while the turn runs, on
    # stderr. stdout is the answer's alone, printed after the turn: a
    # script or a parent agent reads it.
    #
    # It prints the retry lines the REPL shows: the loop asking again after
    # an empty answer (:empty_answer_retry), and a generation retried after
    # a failed request (:generation_retrying). And the hooks' notices
    # (:hook_notice): one during the turn as it comes, one the after_turn
    # hooks give (after :turn_completed; source-links' `sources:`) kept for
    # #flush, which the caller runs after it has printed the answer.
    class OneShotSink
      include Formatting

      # @param err [IO, nil] nil writes to $stderr as it is at each write
      def initialize(err: nil)
        @err = err
        @turn_over = false
        @held = []
      end

      def call(event)
        case event[:type]
        when :empty_answer_retry then line(format_empty_retry_line(event))
        when :generation_retrying then line(format_generation_retry_line(event))
        when :turn_completed, :turn_canceled then @turn_over = true
        when :hook_notice
          text = EventRenderer.hook_notice_line(event)
          @turn_over ? @held << text : line(text)
        end
      end

      # Print the notices that came after the turn's end.
      def flush
        line(@held.shift) until @held.empty?
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
