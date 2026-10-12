# frozen_string_literal: true

require_relative "../steer"

module Samagotchi
  module LLM
    # Which plugin steers ride in the tool result before them on the chat
    # wire (ChatLoop#wire_messages), instead of going as a user message of
    # their own. A user message there is a new query for the chat template
    # and for ChatLoop#reasoning_boundary: the turn's reasoning would stop
    # being sent and the server would prefill again. A plugin's prod
    # (check-in, agents-md, skills) is no new query, so it is appended to
    # that tool message (Steer.folded_text). A person's steer, input lines
    # and anything not right after a paired tool result stay user messages.
    #
    # Wire-only: the stored conversation keeps the steer as its own message.
    # The plan reads only an entry and the ones before it (plus pairing,
    # which a later entry never changes), so once a tool message carries a
    # steer every later request renders it the same way: the prefix stays
    # byte-identical for the prompt cache.
    module SteerFold
      module_function

      # A plugin's steer (not a person's, not one that may cut: the user, chi
      # send, a parent agent, a hook with no label) with text content.
      def foldable?(entry)
        return false unless Steer.steer?(entry)
        return false unless (entry[:role] || entry["role"]).to_s == "user"
        return false unless (entry[:content] || entry["content"]).is_a?(String)

        !Steer.cuts?(entry[:source] || entry["source"])
      end

      # +conversation+'s folds: {steer index => tool result index}. A
      # foldable steer right after a tool result whose call id is in
      # +paired+ (ChatLoop#paired_call_ids) folds into it; one right after
      # a folded steer folds into the same result (one drain's steers, in
      # order). Anything else before it: not folded.
      # @return [Hash{Integer => Integer}]
      def plan(conversation, paired:)
        paired = paired.to_set
        conversation.each_with_index.with_object({}) do |(entry, index), folds|
          next if index.zero? || !foldable?(entry)

          before = conversation[index - 1]
          if folds.key?(index - 1)
            folds[index] = folds[index - 1]
          elsif tool_result?(before) && paired.include?(before[:tool_call_id] || before["tool_call_id"])
            folds[index] = index - 1
          end
        end
      end

      def tool_result?(entry) = (entry[:role] || entry["role"]).to_s == "tool_response"
    end
  end
end
