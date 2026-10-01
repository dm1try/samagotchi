# frozen_string_literal: true

require "monitor"
require_relative "formatting"
require_relative "../output_formatter"
require_relative "../turn_tally"
require_relative "thinking_line"

module Samagotchi
  class TerminalUI
    # EventRenderer's view in both TUIs (attached mode and the REPL), drawn
    # on a Screen: the thinking feedback is the activity slot, one row right
    # above the prompt (spinner frame, then the running tool or the newest
    # sentence of the model's thinking or text, ThinkingLine), and every
    # finished line is committed output. On a PlainSurface the activity
    # slot is dropped.
    #
    # The spinner turns with time, not per chunk: while the slot is shown a
    # ticker thread redraws it every TICK_INTERVAL, so a turn that gets no
    # chunks (a queued remote request, a long prompt eval) still looks alive,
    # and after WAIT_NOTICE_AFTER seconds with no chunk it says how long it
    # has been waiting for the first token.
    #
    # From a turn's TurnTally::MIN_CALLS-th tool call, a second, dim row under
    # it tallies the turn's calls (TurnTally).
    class AttachedView
      include Formatting

      FRAMES = ["|", "/", "-", "\\"].freeze
      # Chunks arrive faster than a status line is worth redrawing.
      MIN_REDRAW_INTERVAL = 0.08
      # Seconds per spinner frame.
      FRAME_INTERVAL = 0.25
      # Seconds between the ticker's redraws (specs stub it to nil: no thread).
      TICK_INTERVAL = FRAME_INTERVAL
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
        @tally = TurnTally.new
        @line = ThinkingLine.new(clock: clock)
        # Plugins' init tasks running now (chi.init), id => "bundle: label".
        @init_tasks = {}
        reset_turn_feedback
      end

      def print_line(text)
        @screen.commit(text)
      end

      # Draw on +surface+ from now on (the REPL swaps in its live region
      # after the view is built, and back when it ends): what the slot shows
      # moves there.
      def surface=(surface)
        @lock.synchronize do
          @screen = surface
          redraw_status if status_text
        end
      end

      # A new turn: its tally starts over too.
      def reset_turn_feedback
        @lock.synchronize do
          reset_feedback_state
          @tally.reset
        end
      end

      # @param _event [Hash] :generation_started (its context window isn't
      #   shown: the status line is one row)
      def generation_feedback_started(_event = {})
        @lock.synchronize do
          @thinking = true
          @line.reset
          @tool = nil
          @waiting_since = @clock.call
          redraw_status
        end
      end

      def generation_feedback_retrying(event)
        @lock.synchronize do
          @retry = format_generation_retry_line(event)
          # The retry streams from the start: wait for its first token again.
          @waiting_since = @clock.call if @thinking
          redraw_status
        end
      end

      def generation_feedback_chunk(event)
        @lock.synchronize do
          @retry = nil
          @waiting_since = nil
          @line.chunk(event)
          redraw_status(throttle: true)
        end
      end

      def tool_call_feedback_started(event)
        @lock.synchronize do
          @retry = nil
          @waiting_since = nil
          @tool = "running #{event[:tool]}"
          @tally.started(key: tally_key(event), tool: event[:tool], params: event[:params])
          redraw_status
        end
      end

      def tool_call_feedback_completed(event)
        @lock.synchronize do
          @tally.completed(key: tally_key(event), tool: event[:tool],
                           status: event.dig(:activity, :status), params: event.dig(:activity, :params))
        end
      end

      def clear_generation_retry
        @lock.synchronize { @retry = nil }
      end

      def generation_feedback_finished
        @lock.synchronize do
          @thinking = false
          @line.reset
          @waiting_since = nil
          redraw_status
        end
      end

      # The turn's answer (or a merge's) is out: the slot goes (unless a
      # plugin's init task still runs). The tally keeps counting until the
      # next turn starts (a merge goes on).
      def finish_thinking_spinner
        @lock.synchronize do
          reset_feedback_state
          @init_tasks.empty? ? @screen.clear_slot(:activity) : redraw_status
        end
      end

      # A plugin's init task runs (between turns too): the slot turns with
      # its label until it ends.
      # @param task [Hash] {bundle:, id:, label:} (an event or a snapshot's)
      def init_started(task)
        @lock.synchronize do
          @init_tasks[task[:id].to_s] = "#{task[:bundle]}: #{task[:label]}"
          redraw_status
        end
      end

      def init_finished(task)
        @lock.synchronize do
          @init_tasks.delete(task[:id].to_s)
          redraw_status
        end
      end

      # The turn waits for them: the slot already shows them.
      def init_wait_feedback(_event); end

      # Pick up a turn joined mid-way (from the Bridge snapshot): the model's
      # thinking or text so far (+lane+ :thinking or :writing), or the tool it
      # is running, and the tally of its tool parts.
      def resume(tail: nil, lane: :writing, tool: nil, parts: nil)
        @lock.synchronize do
          @tally.reset.seed(parts) if parts
          @thinking = true
          @line.reset
          @line.resume(lane, tail)
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

      private

      def reset_feedback_state
        @thinking = false
        @line.reset
        @tool = nil
        @retry = nil
        @waiting_since = nil
      end

      def tally_key(event)
        [event[:iteration].to_i, event[:call_index].to_i]
      end

      def redraw_status(throttle: false)
        now = @clock.call
        return if throttle && @last_redraw && (now - @last_redraw) < MIN_REDRAW_INTERVAL

        @last_redraw = now
        @line.tick
        text = status_text
        if text
          tally = @tally.text(width: @screen.columns - 1)
          @screen.set_slot(:activity, tally ? [text, paint(tally, 90)] : [text])
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
        frame = FRAMES[((now - @origin) / FRAME_INTERVAL).floor % FRAMES.length]
        return "#{frame} #{paint(@retry, 90)}" if @retry
        return "#{frame} #{@tool}…" if @tool
        return "#{frame} #{@init_tasks.values.join(" · ")}…" if !@thinking && @init_tasks.any?
        return nil unless @thinking

        waited = @waiting_since ? now - @waiting_since : 0
        return "#{frame} waiting for the first token… #{waited.floor}s" if waited >= WAIT_NOTICE_AFTER

        return "#{frame} thinking…" if @line.empty?

        prefix = "#{frame} #{@line.label} · "
        prefix + paint(@line.fit(@screen.columns - 1 - prefix.length), 90)
      end
    end
  end
end
