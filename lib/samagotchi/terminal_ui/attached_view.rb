# frozen_string_literal: true

require_relative "formatting"
require_relative "../output_formatter"

module Samagotchi
  class TerminalUI
    # EventRenderer's view in attached mode, drawn on an AttachedScreen: the
    # thinking feedback is the screen's one status line (spinner frame, then
    # the running tool or the tail of the model's text), and every finished
    # line is permanent output. The local REPL's multi-line spinner redraws
    # in place, which can't share the terminal with an open prompt.
    class AttachedView
      include Formatting

      FRAMES = ["|", "/", "-", "\\"].freeze
      TAIL_LIMIT = 400
      # Chunks arrive faster than a status line is worth redrawing.
      MIN_REDRAW_INTERVAL = 0.08

      attr_reader :context_status

      # @param screen [AttachedScreen]
      def initialize(screen, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @screen = screen
        @clock = clock
        @frame = 0
        reset_turn_feedback
      end

      def print_line(text)
        @screen.print_line(text)
      end

      def reset_turn_feedback
        @thinking = false
        @tail = +""
        @tool = nil
        @retry = nil
      end

      # @param _event [Hash] :generation_started (its context window isn't
      #   shown: the status line is one row)
      def generation_feedback_started(_event = {})
        @thinking = true
        @tail = +""
        @tool = nil
        redraw_status
      end

      def generation_feedback_retrying(event)
        @retry = "retrying (attempt #{event[:attempt]})"
        redraw_status
      end

      def generation_feedback_chunk(event)
        @retry = nil
        @tail << event[:content].to_s
        @tail = @tail[-TAIL_LIMIT..] if @tail.length > TAIL_LIMIT
        @frame += 1
        redraw_status(throttle: true)
      end

      def tool_call_feedback_started(event)
        @retry = nil
        @tool = "running #{event[:tool]}"
        redraw_status
      end

      def clear_generation_retry
        @retry = nil
      end

      def generation_feedback_finished
        @thinking = false
        @tail = +""
        redraw_status
      end

      def finish_thinking_spinner
        reset_turn_feedback
        @screen.status = nil
      end

      def capture_context_status(status)
        @context_status = status if status
      end

      # The REPL's sticky memories line has no source in attached mode.
      def emit_active_memories_line; end

      private

      def redraw_status(throttle: false)
        now = @clock.call
        return if throttle && @last_redraw && (now - @last_redraw) < MIN_REDRAW_INTERVAL

        @last_redraw = now
        @screen.status = status_text
      end

      def status_text
        frame = FRAMES[@frame % FRAMES.length]
        return "#{frame} #{@retry}" if @retry
        return "#{frame} #{@tool}…" if @tool
        return nil unless @thinking

        tail = OutputFormatter.strip(@tail).gsub(/\s+/, " ").strip
        return "#{frame} thinking…" if tail.empty?

        prefix = "#{frame} model> … "
        room = [@screen.columns - 1 - prefix.length, 1].max
        "#{prefix}#{tail.length > room ? tail[-room..] : tail}"
      end
    end
  end
end
