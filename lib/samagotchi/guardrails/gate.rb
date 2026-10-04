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
      # @param hooks_lookup [#call] returns the Hooks::Registry (or nil);
      #   read per call, since the Engine sets the kernel's hooks after
      #   the kernel is built.
      # @param context_lookup [#call] returns the Context for this call
      #   (the Engine's: session, interface, origin, per-turn git cache)
      # @param model_key_lookup [#call] the model key (memory overlays, rules' models:)
      # @param model_name_lookup [#call] the bare model name (rules' models:)
      # @param approver [#call, nil] settles an ask (Engine#request_approval);
      #   without one an ask is denied
      # @param approvals_lookup [#call] returns the Approvals store (or nil)
      # @param checks_lookup [#call] core checks (#check(verdict)) run on the
      #   final call after the hooks: protected paths, then the rules
      # @param cancelled_lookup [#call] true once the turn was cancelled (a
      #   hook's stop_turn): the rest of a batch is denied without a vote
      # @param tools_lookup [#call] returns the Tools::Registry (or nil): a
      #   plugin tool's targets: say what its call acts on
      def initialize(hooks_lookup, context_lookup: -> { Context.new }, model_key_lookup: -> {}, model_name_lookup: -> {},
                     approver: nil, approvals_lookup: -> {}, checks_lookup: -> { [] }, cancelled_lookup: -> { false },
                     tools_lookup: -> {})
        @hooks_lookup = hooks_lookup
        @context_lookup = context_lookup
        @model_key_lookup = model_key_lookup
        @model_name_lookup = model_name_lookup
        @approver = approver
        @approvals_lookup = approvals_lookup
        @checks_lookup = checks_lookup
        @cancelled_lookup = cancelled_lookup
        @tools_lookup = tools_lookup
      end

      # @param call [Hash] the parsed tool call
      # @param iteration [Integer]
      # @param params [String] the call's one-line preview
      # @return [Verdict]
      def evaluate(call, iteration:, params:)
        context = @context_lookup.call
        verdict = Verdict.new(call: call)
        if @cancelled_lookup.call
          verdict.deny!("the turn was stopped", decided_by: "core")
          verdict.context = context
          verdict.targets = targets_for(call, context)
          return verdict
        end
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
        Array(@checks_lookup.call).each { |check| check.check(verdict) }
        verdict
      end

      # Settle an ask: the approver asks the user; with none, or one that
      # fails, it is denied.
      # @return [Verdict]
      # A stored approval that covers the call allows it without asking; an
      # answer that allows it beyond this once is stored.
      def settle_ask(verdict)
        approvals = @approvals_lookup.call
        if (entry = stored(approvals, verdict))
          verdict.settle!(:allow, decided_by: "approval")
          verdict.scope = entry["scope"]
          return verdict
        end
        return verdict.settle!(:deny, decided_by: "no one", note: "No one to approve it.") unless @approver

        @approver.call(verdict)
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

      def targets_for(call, context)
        Targets.for(call, context, model_key: @model_key_lookup.call, model_name: @model_name_lookup.call,
                                   registry: @tools_lookup.call)
      end

      # Registry#fire_each rescues a raising hook itself.
      def fire_each(name, event, &)
        @hooks_lookup.call&.fire_each(name, event, &)
      end
    end
  end
end
