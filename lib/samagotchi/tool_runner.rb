# frozen_string_literal: true

require_relative "tool_activity"
require_relative "guardrails"

module Samagotchi
  # The single per-call path both loops use: the tool_call_started and
  # tool_call_completed events, the guardrail gate (before_tool_call hooks
  # and their veto), dispatch through KernelLoop, the after_tool_call hook
  # and the output cap. Each loop picks what the model gets back: native
  # feeds the full `output:`, the chat loop feeds `capped_output:` (the cap
  # on the event applies to both).
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
      # The gate runs first, so tool_call_started shows the call that runs.
      verdict = evaluate(call, iteration, params)
      call = verdict.call
      params = ToolActivity.tool_activity_params(call[:name], call)
      emit(on_stream_event,
           type: :tool_call_started, iteration: iteration, call_count: call_count, call_index: call_index,
           tool: call[:name], call: call.dup, params: params)

      # Nothing can approve an ask yet: it is denied.
      verdict.settle!(:deny, decided_by: "no one", note: "No one to approve it.") if verdict.ask?
      result = verdict.deny? ? denied(call, verdict) : dispatch(call)

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

    # The Engine sets the kernel's gate (its context, later the approval
    # flow); a bare kernel (specs) gets one that only runs the hooks.
    def gate
      given = @kernel.guardrail_gate if @kernel.respond_to?(:guardrail_gate)
      given || (@gate ||= Guardrails::Gate.new(-> { @kernel.hooks if @kernel.respond_to?(:hooks) }))
    end

    # A gate that fails denies the call (fail closed).
    def evaluate(call, iteration, params)
      gate.evaluate(call, iteration: iteration, params: params)
    rescue StandardError => e
      Guardrails::Verdict.new(call: call).deny!("the guardrail check failed: #{e.class}: #{e.message}",
                                                decided_by: "core")
    end

    # A legacy veto keeps its old text; a verdict's deny tells the model
    # who decided and not to route around it.
    def denied(call, verdict)
      output = if verdict.legacy?
                 reason = verdict.reason.to_s.strip
                 "[#{call[:name]}] Error: blocked by guardrail: #{reason.empty? ? "blocked by hook" : reason}"
               else
                 "[#{call[:name]}] Error: #{verdict.deny_text}"
               end
      activity = ToolActivity.tool_activity_event(call[:name], call, output)
      { output: output, activity: activity.merge(status: "blocked", guardrail: verdict.to_activity) }
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
