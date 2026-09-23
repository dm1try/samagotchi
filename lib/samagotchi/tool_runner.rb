# frozen_string_literal: true

require_relative "tool_activity"

module Samagotchi
  # The single per-call path both loops use: the tool_call_started and
  # tool_call_completed events, the before/after_tool_call hooks with the
  # veto, dispatch through KernelLoop, and the output cap. Each loop picks
  # what the model gets back: native feeds the full `output:`, the chat
  # loop feeds `capped_output:` (the cap on the event applies to both).
  class ToolRunner
    # @param kernel [KernelLoop] read lazily: Engine sets its hooks after
    #   the kernel is built.
    def initialize(kernel)
      @kernel = kernel
    end

    # @param call_index [Integer] 1-based position of the call in its batch
    # @return [Hash] output:, capped_output:, truncated:, activity:
    def run(call, iteration:, call_index:, call_count:, on_stream_event:, max_tool_output_chars:)
      params = ToolActivity.tool_activity_params(call[:name], call)
      emit(on_stream_event,
           type: :tool_call_started, iteration: iteration, call_count: call_count, call_index: call_index,
           tool: call[:name], call: call.dup, params: params)

      # Veto protocol (minimal guardrail): a before_tool_call hook may set
      # event[:blocked]=true with an optional event[:block_reason]. Only this
      # hook supports veto. A blocked call gets a synthetic error output and is
      # never dispatched.
      before = { type: :before_tool_call, iteration: iteration, call: call.dup, params: params,
                 blocked: false, block_reason: nil }
      fire(:before_tool_call, before)
      result = before[:blocked] ? blocked(call, before[:block_reason]) : dispatch(before[:call] || call)

      output = result[:output].to_s
      capped = output
      truncated = false
      if max_tool_output_chars && output.length > max_tool_output_chars
        truncated = true
        capped = output[0, max_tool_output_chars]
      end

      fire(:after_tool_call, { type: :after_tool_call, iteration: iteration, tool: call[:name], output: capped })
      emit(on_stream_event,
           type: :tool_call_completed, iteration: iteration, call_count: call_count, call_index: call_index,
           tool: call[:name], output: capped, output_truncated: truncated, activity: result[:activity])

      { output: output, capped_output: capped, truncated: truncated, activity: result[:activity] }
    end

    private

    def blocked(call, reason)
      reason = reason.to_s.strip
      reason = "blocked by hook" if reason.empty?
      output = "[#{call[:name]}] Error: blocked by guardrail: #{reason}"
      { output: output, activity: ToolActivity.tool_activity_event(call[:name], call, output).merge(status: "blocked") }
    end

    # KernelLoop#dispatch turns tool errors into "[name] Error: …" itself;
    # this rescue only catches a failing dispatcher.
    def dispatch(call)
      @kernel.dispatch_tool_call(call)
    rescue StandardError => e
      { output: "[#{call[:name]}] Error: #{e.class}: #{e.message}", activity: nil }
    end

    # A failing hook must not break the turn.
    def fire(name, event)
      hooks = @kernel.hooks if @kernel.respond_to?(:hooks)
      hooks&.fire(name, event)
    rescue StandardError
      nil
    end

    def emit(callback, event)
      callback&.call(event)
    rescue StandardError
      nil
    end
  end
end
