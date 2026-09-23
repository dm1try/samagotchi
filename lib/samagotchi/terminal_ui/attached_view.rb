# frozen_string_literal: true

require "monitor"
require_relative "formatting"
require_relative "../output_formatter"

module Samagotchi
  class TerminalUI
    # EventRenderer's view in attached mode, drawn on a Screen: the
    # thinking feedback is the activity slot, one row right above the prompt
    # (spinner frame, then the running tool or the tail of the model's text),
    # and every finished line is committed output. The local REPL's
    # multi-line spinner redraws in place, which can't share the terminal
    # with an open prompt.
    #
    # The spinner turns with time, not per chunk: while the slot is shown a
    # ticker thread redraws it every TICK_INTERVAL, so a turn that gets no
    # chunks (a queued remote request, a long prompt eval) still looks alive,
    # and after WAIT_NOTICE_AFTER seconds with no chunk it says how long it
    # has been waiting for the first token.
    class AttachedView
      include Formatting

      FRAMES = ["|", "/", "-", "\\"].freeze
      TAIL_LIMIT = 400
      # Chunks arrive faster than a status line is worth redrawing.
      MIN_REDRAW_INTERVAL = 0.08
      TICK_INTERVAL = 0.25
      WAIT_NOTICE_AFTER = 2.0

      attr_reader :context_status

      # @param screen [Surface] with #columns (a Screen)
      # @param tick_interval [Numeric, nil] seconds between the ticker's
      #   redraws; nil: no ticker thread (specs call #tick)
      def initialize(screen, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, tick_interval: TICK_INTERVAL)
        @screen = screen
        @clock = clock
        @tick_interval = tick_interval
        @origin = clock.call
        @lock = Monitor.new
        @ticker = nil
        reset_turn_feedback
      end

      def print_line(text)
        @screen.commit(text)
      end

      def reset_turn_feedback
        @lock.synchronize do
          @thinking = false
          @tail = +""
          @tool = nil
          @retry = nil
          @waiting_since = nil
        end
      end

      # @param _event [Hash] :generation_started (its context window isn't
      #   shown: the status line is one row)
      def generation_feedback_started(_event = {})
        @lock.synchronize do
          @thinking = true
          @tail = +""
          @tool = nil
          @waiting_since = @clock.call
          redraw_status
        end
      end

      def generation_feedback_retrying(event)
        @lock.synchronize do
          @retry = "retrying (attempt #{event[:attempt]})"
          # The retry streams from the start: wait for its first token again.
          @waiting_since = @clock.call if @thinking
          redraw_status
        end
      end

      def generation_feedback_chunk(event)
        @lock.synchronize do
          @retry = nil
          @waiting_since = nil
          @tail << event[:content].to_s
          @tail = @tail[-TAIL_LIMIT..] if @tail.length > TAIL_LIMIT
          redraw_status(throttle: true)
        end
      end

      def tool_call_feedback_started(event)
        @lock.synchronize do
          @retry = nil
          @waiting_since = nil
          @tool = "running #{event[:tool]}"
          redraw_status
        end
      end

      def clear_generation_retry
        @lock.synchronize { @retry = nil }
      end

      def generation_feedback_finished
        @lock.synchronize do
          @thinking = false
          @tail = +""
          @waiting_since = nil
          redraw_status
        end
      end

      def finish_thinking_spinner
        @lock.synchronize do
          reset_turn_feedback
          @screen.clear_slot(:activity)
        end
      end

      # Pick up a turn joined mid-way (from the Bridge snapshot): the model's
      # text so far, or the tool it is running.
      def resume(tail: nil, tool: nil)
        @lock.synchronize do
          @thinking = true
          @tail = +tail.to_s
          @tool = tool && "running #{tool}"
          @waiting_since = nil
          redraw_status
        end
      end

      # Redraw the slot for the time that passed (the ticker calls it).
      # @return [Boolean] whether the slot is still shown
      def tick
        @lock.synchronize do
          return false unless status_text

          redraw_status
          true
        end
      end

      # End the ticker (the loop is over; nothing may draw after it).
      def stop
        ticker = @lock.synchronize { @ticker.tap { @ticker = nil } }
        ticker&.kill
        ticker&.join(0.5)
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
        text = status_text
        if text
          @screen.set_slot(:activity, [text])
          start_ticker
        else
          @screen.clear_slot(:activity)
        end
      end

      # One thread per shown slot; it ends when the slot goes (see #tick).
      def start_ticker
        return unless @tick_interval
        return if @ticker&.alive?

        @ticker = Thread.new do
          loop do
            sleep(@tick_interval)
            break unless tick
          end
        rescue StandardError
          nil
        end
        @ticker.report_on_exception = false
      end

      def status_text
        now = @clock.call
        frame = FRAMES[((now - @origin) / TICK_INTERVAL).floor % FRAMES.length]
        return "#{frame} #{@retry}" if @retry
        return "#{frame} #{@tool}…" if @tool
        return nil unless @thinking

        waited = @waiting_since ? now - @waiting_since : 0
        return "#{frame} waiting for the first token… #{waited.floor}s" if waited >= WAIT_NOTICE_AFTER

        tail = OutputFormatter.strip(@tail).gsub(/\s+/, " ").strip
        return "#{frame} thinking…" if tail.empty?

        prefix = "#{frame} model> … "
        room = [@screen.columns - 1 - prefix.length, 1].max
        "#{prefix}#{tail.length > room ? tail[-room..] : tail}"
      end
    end
  end
end
