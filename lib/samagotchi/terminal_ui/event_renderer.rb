# frozen_string_literal: true

module Samagotchi
  class TerminalUI
    # Renders one UI's view of Engine turn events: the thinking spinner while
    # the model generates, a `tool>` line per completed tool call, and the
    # answer (with any tool activity not already shown) from :turn_completed's
    # turn_summary. It is the `on_event:` sink the REPL hands Engine#run_turn.
    #
    # Drawing is delegated to a +view+ (the TerminalUI), so the same dispatch
    # can later render events that arrive over the Bridge. The renderer keeps
    # only per-turn bookkeeping that must come from the events themselves:
    # which tool lines were already streamed, and when each tool call started.
    class EventRenderer
      def initialize(view, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @view = view
        @clock = clock
        @streamed_tool_activity = Hash.new(0)
        @tool_started_at = {}
      end

      def call(event)
        case event[:type]
        when :turn_started
          begin_turn
        when :generation_started
          @view.generation_feedback_started(event)
        when :generation_retrying
          @view.generation_feedback_retrying(event)
        when :generation_chunk
          @view.generation_feedback_chunk(event)
        when :tool_call_started
          @tool_started_at[tool_call_key(event)] = @clock.call
          @view.tool_call_feedback_started(event)
        when :tool_call_completed
          @view.clear_generation_retry
          render_streamed_tool_activity(event[:activity], duration_ms: tool_duration_ms(event))
        when :generation_completed, :generation_cancelled, :tool_dispatch_started
          @view.generation_feedback_finished
        when :turn_completed
          render_turn_summary(event[:turn_summary]) if event[:turn_summary]
        end
      end

      # Start a turn's bookkeeping and reset the view's per-turn feedback.
      # Also called directly by REPL paths that drive the kernel without
      # Engine#run_turn (so no :turn_started).
      def begin_turn
        @streamed_tool_activity = Hash.new(0)
        @tool_started_at = {}
        @view.reset_turn_feedback
      end

      # Render a finished turn: tool activity the stream did not already show,
      # the status lines, the answer, and the iteration-limit notice.
      # @param summary [Hash] Engine#turn_summary
      def render_turn_summary(summary)
        @view.finish_thinking_spinner
        @view.capture_context_status(summary[:context_status])
        Array(summary[:tool_activity]).each do |activity|
          next if consume_streamed_tool_activity(activity)

          @view.print_line(@view.format_tool_activity_line(activity))
        end
        @view.emit_active_memories_line
        @view.print_line(summary[:output])
        @view.print_line("iteration limit reached") if summary[:resumable]
      end

      private

      def render_streamed_tool_activity(activity, duration_ms:)
        return if activity.nil?

        @streamed_tool_activity[tool_activity_key(activity)] += 1
        @view.print_line(@view.format_tool_activity_line(activity, duration_ms: duration_ms))
      end

      def consume_streamed_tool_activity(activity)
        key = tool_activity_key(activity)
        count = @streamed_tool_activity[key]
        return false unless count.positive?

        @streamed_tool_activity[key] = count - 1
        true
      end

      def tool_activity_key(activity)
        [activity[:action], activity[:tool], activity[:params], activity[:status]].map(&:to_s).join("|")
      end

      def tool_call_key(event)
        [event[:iteration].to_i, event[:call_index].to_i, event[:tool].to_s]
      end

      def tool_duration_ms(event)
        started_at = @tool_started_at.delete(tool_call_key(event))
        started_at && ((@clock.call - started_at) * 1000.0)
      end
    end
  end
end
