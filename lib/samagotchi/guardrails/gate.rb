# frozen_string_literal: true

require_relative "verdict"

module Samagotchi
  module Guardrails
    # Decides whether a tool call may run. Today the only voters are
    # before_tool_call hooks, through the legacy veto: a hook sets
    # event[:blocked] = true with an optional event[:block_reason], and may
    # replace event[:call]. The hooks share one event hash, so the last
    # write to :blocked wins.
    class Gate
      # @param hooks_lookup [#call] returns the Hooks::Registry (or nil);
      #   read per call, since the Engine sets the kernel's hooks after
      #   the kernel is built.
      def initialize(hooks_lookup)
        @hooks_lookup = hooks_lookup
      end

      # @param call [Hash] the parsed tool call
      # @param iteration [Integer]
      # @param params [String] the call's one-line preview
      # @return [Verdict]
      def evaluate(call, iteration:, params:)
        before = { type: :before_tool_call, iteration: iteration, call: call.dup, params: params,
                   blocked: false, block_reason: nil }
        fire(:before_tool_call, before)
        final = before[:call] || call
        return Verdict.new(:deny, call: final, reason: before[:block_reason]) if before[:blocked]

        Verdict.new(:allow, call: final)
      end

      private

      # A failing hook must not break the turn.
      def fire(name, event)
        @hooks_lookup.call&.fire(name, event)
      rescue StandardError
        nil
      end
    end
  end
end
