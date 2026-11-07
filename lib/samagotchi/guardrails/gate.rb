# frozen_string_literal: true

require_relative "verdict"
require_relative "context"
require_relative "targets"
require_relative "approvals"
require_relative "protected_paths"
require_relative "../log"

module Samagotchi
  module Guardrails
    # Decides whether a tool call may run. The voters are before_tool_call
    # hooks: through event[:guardrail] (#deny!, #ask!) or the legacy flag
    # (event[:blocked] = true, optional event[:block_reason]). The flag is
    # folded into the verdict after each hook, so a later hook can't undo a
    # deny. A hook may replace event[:call]; the verdict carries the final
    # call.
    class Gate
      # What a call is judged in comes with it: #evaluate's +context:+, the
      # call's turn (TurnContext: its controller, model key and name, and
      # what +context_for+ and +checks_for+ make of it).
      #
      # @param hooks [Hooks::Registry, nil] the before_tool_call voters (the
      #   Engine's registry, built before its gate; nil: no hooks)
      # @param context_for [#call] (turn) → the Context for a call of that
      #   turn (the Engine's: session, interface, origin, the turn's git cache)
      # @param approver [#call, nil] (verdict, turn) settles an ask
      #   (GuardrailWiring#request_approval); without one an ask is denied
      # @param approvals_lookup [#call] returns the Approvals store (or nil)
      # @param checks_for [#call] (turn) → core checks (#check(verdict)) run
      #   on the final call after the hooks: protected paths, then the rules
      # @param tools [Tools::Registry, nil] the session's tools (the Engine's,
      #   built before its gate): a plugin tool's targets: say what its call
      #   acts on
      def initialize(hooks: nil, tools: nil, context_for: ->(_turn) { Context.new }, approver: nil, approvals_lookup: -> {},
                     checks_for: ->(_turn) { [] })
        @hooks = hooks
        @context_for = context_for
        @approver = approver
        @approvals_lookup = approvals_lookup
        @checks_for = checks_for
        @tools = tools
      end

      # @param call [Hash] the parsed tool call
      # @param context [TurnContext] the call's turn: a cancelled one's
      #   controller denies the call without a vote (a hook's stop_turn: the
      #   rest of a batch); its model key and name go to the targets
      #   (memory overlays, rules' models:)
      # @param iteration [Integer]
      # @param params [String] the call's one-line preview
      # @param verdict [Verdict, nil] the one the voters vote on (the test
      #   kit's recording one, maybe with a vote already in); default a new
      #   one for +call+
      # @return [Verdict]
      def evaluate(call, context:, iteration:, params:, verdict: nil)
        judged = @context_for.call(context)
        verdict ||= Verdict.new(call: call)
        verdict.call = call
        if context.cancelled?
          verdict.deny!("the turn was stopped", decided_by: "core")
          verdict.context = judged
          verdict.targets = targets_for(call, judged, context)
          return verdict
        end
        before = { type: :before_tool_call, iteration: iteration, call: call.dup, params: params,
                   blocked: verdict.deny?, block_reason: (verdict.reason if verdict.deny?), guardrail: verdict,
                   context: judged.to_h, targets: targets_for(call, judged, context).to_h }
        fire_each(:before_tool_call, before) do |event|
          verdict.legacy_deny!(event[:block_reason]) if event[:blocked]
          event[:blocked] = verdict.deny?
          event[:block_reason] = verdict.reason if verdict.deny?
        end
        verdict.call = before[:call] || call
        verdict.context = judged
        verdict.targets = targets_for(verdict.call, judged, context)
        Array(@checks_for.call(context)).each { |check| check.check(verdict) }
        verdict
      end

      # Settle an ask: the approver asks the user; with none, or one that
      # fails, it is denied.
      # @return [Verdict]
      # A stored approval that covers the call allows it without asking; an
      # answer that allows it beyond this once is stored.
      # @param context [TurnContext] the call's turn (the approver's)
      def settle_ask(verdict, context:)
        approvals = @approvals_lookup.call
        if !verdict.fresh_ask? && (entry = stored(approvals, verdict))
          verdict.settle!(:allow, decided_by: "approval")
          verdict.scope = entry["scope"]
          return verdict
        end
        return verdict.settle!(:deny, decided_by: "no one", note: "No one to approve it.") unless @approver

        @approver.call(verdict, context)
        return verdict.settle!(:deny, decided_by: "no one", note: "No one to approve it.") if verdict.ask?

        remember(approvals, verdict)
        verdict
      rescue StandardError => e
        verdict.settle!(:deny, decided_by: "core", note: "The approval failed (#{e.class}: #{e.message}).")
      end

      private

      def stored(approvals, verdict)
        approvals&.match(verdict)
      rescue StandardError
        nil
      end

      # A store that can't be written only means the next call asks again.
      def remember(approvals, verdict)
        return unless approvals && verdict.allow? && verdict.scope

        approvals.add(verdict, verdict.scope)
      rescue StandardError => e
        Log.warn(:guardrails, "approval_store_failed", echo: "[samagotchi:guardrails] could not store the approval: #{e.class}: #{e.message}", error: e.class.name)
      end

      def targets_for(call, judged, turn)
        Targets.for(call, judged, model_key: turn.model_key, model_name: turn.model_name, registry: @tools,
                                  surface: turn.surface)
      end

      # Registry#fire_each rescues a raising hook itself.
      def fire_each(name, event, &)
        @hooks&.fire_each(name, event, &)
      end
    end
  end
end
