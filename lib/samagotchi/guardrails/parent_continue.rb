# frozen_string_literal: true

require_relative "../config"

module Samagotchi
  module Guardrails
    # Whether a parent agent may answer Continue to a session's step-limit
    # question (kind "continue", ContinueOffer): turn.parent_continue,
    # config.yml only, default true. Continue grants no permission (every
    # tool call still meets the guardrails), it spends time and tokens;
    # false makes parents stop-only. Checked by `chi answer` before it posts
    # and by the worker's question desk for an answer marked as chi
    # answer's, the way ParentApprovals is.
    module ParentContinue
      KEY = "turn.parent_continue"
      KIND = "continue"
      CONTINUE = "Continue"

      module_function

      # @return [Boolean] this process's setting
      def allowed?
        Config.get(KEY) != false
      end

      # Why a parent may not give this answer, or nil.
      # @param pending [Hash] the pending question (symbol or string keys)
      # @param selected [Array<String>] the selected labels
      # @return [Symbol, nil] :stop_only
      def refusal(pending, selected, allowed: allowed?)
        return nil if allowed
        return nil unless (pending[:kind] || pending["kind"]).to_s == KIND

        Array(selected).map(&:to_s).include?(CONTINUE) ? :stop_only : nil
      end

      def message
        "a parent agent may only stop this turn here (#{KEY}: false): answer Stop " \
          "(--option Stop --text WHY), or tell your user it waits"
      end
    end
  end
end
