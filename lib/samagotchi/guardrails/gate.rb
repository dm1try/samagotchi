# frozen_string_literal: true

require_relative "verdict"
require_relative "context"
require_relative "targets"

module Samagotchi
  module Guardrails
    # Decides whether a tool call may run. The voters are before_tool_call
    # hooks: through event[:guardrail] (#deny!, #ask!) or the legacy flag
    # (event[:blocked] = true, optional event[:block_reason]). The flag is
    # folded into the verdict after each hook, so a later hook can't undo a
    # deny. A hook may replace event[:call]; the verdict carries the final
    # call.
    class Gate
      # @param hooks_lookup [#call] returns the Hooks::Registry (or nil);
      #   read per call, since the Engine sets the kernel's hooks after
      #   the kernel is built.
      # @param context_lookup [#call] returns the Context for this call
      #   (the Engine's: session, interface, origin, per-turn git cache)
      # @param model_key_lookup [#call] the model key (memory overlays)
      def initialize(hooks_lookup, context_lookup: -> { Context.new }, model_key_lookup: -> {})
        @hooks_lookup = hooks_lookup
        @context_lookup = context_lookup
        @model_key_lookup = model_key_lookup
      end

      # @param call [Hash] the parsed tool call
      # @param iteration [Integer]
      # @param params [String] the call's one-line preview
      # @return [Verdict]
      def evaluate(call, iteration:, params:)
        context = @context_lookup.call
        verdict = Verdict.new(call: call)
        before = { type: :before_tool_call, iteration: iteration, call: call.dup, params: params,
                   blocked: false, block_reason: nil, guardrail: verdict,
                   context: context.to_h, targets: targets_for(call, context).to_h }
        fire_each(:before_tool_call, before) do |event|
          verdict.legacy_deny!(event[:block_reason]) if event[:blocked]
          event[:blocked] = verdict.deny?
          event[:block_reason] = verdict.reason if verdict.deny?
        end
        verdict.call = before[:call] || call
        verdict.context = context
        verdict.targets = targets_for(verdict.call, context)
        verdict
      end

      private

      def targets_for(call, context)
        Targets.for(call, context, model_key: @model_key_lookup.call)
      end

      # Registry#fire_each rescues a raising hook itself.
      def fire_each(name, event, &after_each)
        @hooks_lookup.call&.fire_each(name, event, &after_each)
      end
    end
  end
end
