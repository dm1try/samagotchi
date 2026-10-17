# frozen_string_literal: true

require_relative "../log"
require_relative "anthropic_wire"
require_relative "openai_chat"

module Samagotchi
  module LLM
    # The preserved-thinking recovery of AnthropicMessages (Claude 5.x: a
    # replayed thinking block is bound to the prefix it was made under, and
    # a prefix that changed gets a signature 400): which step a 400 takes
    # (#advance), the body that step sends (#recovered_body) and the
    # response's ThinkingDrop (#with_thinking_drop). One per adapter; a
    # request's own state is a Recovery.
    class AnthropicBindingRecovery
      # The beta header thinking.block_binding needs, and the behaviour the
      # recovery asks for: the API drops a thinking block whose prefix
      # changed (and every thinking block after it) for that request.
      BINDING_BETA = "thinking-binding-controls-2026-08-01"
      DROP_BLOCK = { prefix_mismatch_behavior: "drop_block" }.freeze
      # A signature 400 that drop_block can settle: the block is valid but
      # bound to another prefix. Without it the signature itself is bad
      # (tampered, unreadable, another provider's): only a strip helps.
      BOUND_ELSEWHERE_RE = /bound to a different conversation/i
      # The block a signature 400 names: an index into the body sent.
      BLOCK_PATH_RE = /messages\.(\d+)\.content\.(\d+)/
      # The only drop the loop settles: a model_binding_mismatch (a /model
      # downgrade) keeps its blocks, a switch back reads them again.
      PREFIX_DROP = "prefix_binding_mismatch"
      # The 400's undocumented diagnosis header, kept on the ProviderError and
      # logged as `diagnosis`.
      DIAGNOSIS_HEADER = "anthropic-thinking-prefix-mismatch"

      # One request's binding recovery (#advance): the step taken
      # (nil, :drop_block or :strip), the steps tried, where a strip starts
      # ([message, block] in the body), the last signature 400 and the body
      # it answered, and the first 400's last sentence and diagnosis for the log line.
      Recovery = Struct.new(:step, :tried, :strip_from, :signature, :why, :diagnosis)

      # @param refusals [RefusalMemo] the adapter's (the :binding_controls
      #   the host refused is remembered there)
      # @param host_name [String] for the log lines
      # @param budget_form [#call] model -> whether it gets the budget form
      #   (AnthropicMessages#budget_form?)
      def initialize(refusals:, host_name:, budget_form:)
        @refusals = refusals
        @host_name = host_name
        @budget_form = budget_form
      end

      # The step a signature 400 for +body+ takes (set on +recovery+, once
      # each per request), or nil: the error goes on as it is.
      # - drop_block: the same body with thinking.block_binding and the beta
      #   header, for a block bound to another prefix, when the host takes
      #   the controls and the body's thinking can carry them (adaptive,
      #   enabled, or none: then adaptive; not disabled, nor none for a
      #   model on the budget form);
      # - strip: the block the 400 names (else the first replayed thinking
      #   block) and every thinking block after it removed, for a bad
      #   signature, where drop_block can't apply, when the host refused
      #   the controls (remembered for the host), or after a second
      #   signature 400.
      def advance(error, body, recovery, model)
        return nil if body.nil? || error.status != 400

        if error.thinking_binding_unsupported? && recovery.step == :drop_block
          unless @refusals.refused?(:binding_controls)
            @refusals.remember(:binding_controls)
            Log.info(:http, "binding_controls_refused", host: @host_name, detail: error.detail.to_s[0, 200])
          end
          return strip_step(recovery)
        end
        return nil unless error.thinking_signature?

        recovery.diagnosis ||= error.diagnosis
        recovery.signature = [error.detail.to_s, body]
        case recovery.step
        when nil
          return nil if thinking_positions(body).empty?

          recovery.why = last_sentence(error.detail.to_s)
          return strip_step(recovery) unless drop_block_fits?(error, body, model)

          recovery.step = :drop_block
        when :drop_block then strip_step(recovery)
        end
      end

      # +body+ as the recovery step sends it, and the identities a strip
      # removed (nil for none).
      def recovered_body(body, recovery)
        case recovery.step
        when :drop_block then [body.merge(thinking: drop_block_thinking(body[:thinking])), nil]
        when :strip then stripped_body(body, recovery.strip_from)
        else [body, nil]
        end
      end

      # +response+ with the blocks this request went without
      # (ThinkingDrop), logged: a strip's, or drop_block's
      # prefix_binding_mismatch entries mapped by path into +body+ (the
      # body sent); any other entry is counted as kept, never settled.
      def with_thinking_drop(response, recovery, body, stripped, transformations, model)
        if recovery.step == :strip
          identities = stripped
          kept = 0
        else
          drops = Array(transformations).select { |entry| entry["type"] == "thinking_dropped" }
          prefix, others = drops.partition { |entry| entry["reason"] == PREFIX_DROP }
          identities = prefix.filter_map { |entry| identity_at(body, entry["path"]) }.uniq.freeze
          kept = others.size
        end
        fields = { host: @host_name, model: model.to_s, how: recovery.step.to_s, dropped: identities.size,
                   kept: kept, why: recovery.why }
        fields[:diagnosis] = recovery.diagnosis if recovery.diagnosis
        Log.info(:http, "thinking_recovered", **fields)
        return response if identities.empty?

        response.with(thinking_drop: ThinkingDrop.new(identities: identities, how: recovery.step))
      end

      private

      def drop_block_fits?(error, body, model)
        return false unless BOUND_ELSEWHERE_RE.match?(error.detail.to_s) && !@refusals.refused?(:binding_controls)

        case body[:thinking]
        when nil then !@budget_form.call(model)
        when Hash then %w[adaptive enabled].include?(body[:thinking][:type].to_s)
        else false
        end
      end

      # The strip, from the block the last signature 400 names in the body
      # it answered (a thinking block there), else the first replayed one.
      def strip_step(recovery)
        return nil if recovery.tried.include?(:strip)

        detail, body = recovery.signature
        positions = thinking_positions(body)
        named = detail.to_s.match(BLOCK_PATH_RE)&.captures&.map(&:to_i)
        recovery.strip_from = positions.include?(named) ? named : positions.first
        recovery.step = recovery.strip_from && :strip
      end

      # [message, block] of every thinking or redacted_thinking block in
      # +body+'s messages.
      def thinking_positions(body)
        Array(body[:messages]).each_with_index.flat_map do |message, n|
          Array(message[:content]).each_with_index.filter_map { |block, m| [n, m] if AnthropicWire.thinking_block?(block) }
        end
      end

      # The body's thinking with block_binding: drop_block (adaptive
      # without one: the binding controls need adaptive or enabled).
      def drop_block_thinking(thinking)
        thinking = thinking.is_a?(Hash) ? thinking.transform_keys(&:to_sym) : {}
        thinking = { type: "adaptive" } unless %w[adaptive enabled].include?(thinking[:type].to_s)
        thinking.merge(block_binding: DROP_BLOCK)
      end

      # +body+ without the thinking blocks from +from+ on (a trailing run:
      # what Messages takes; a gap in the middle it refuses), and their
      # identities. A message left empty says the placeholder.
      def stripped_body(body, from)
        first_message, first_block = from
        removed = []
        messages = body[:messages].each_with_index.map do |message, n|
          next message if n < first_message

          content = message[:content].each_with_index.reject do |block, m|
            drop = (n > first_message || m >= first_block) && AnthropicWire.thinking_block?(block)
            removed << AnthropicWire.block_identity(block) if drop
            drop
          end.map(&:first)
          next message if content.size == message[:content].size

          message.merge(content: content.empty? ? [{ type: "text", text: AnthropicWire::PLACEHOLDER }] : content)
        end
        [body.merge(messages: messages), removed.compact.uniq.freeze]
      end

      def identity_at(body, path)
        n, m = path.to_s.match(BLOCK_PATH_RE)&.captures&.map(&:to_i)
        return nil unless n

        block = Array(body[:messages])[n]&.then { |message| Array(message[:content])[m] }
        AnthropicWire.thinking_block?(block) ? AnthropicWire.block_identity(block) : nil
      end

      # The last sentence of a 400 (what it says changed: "The `system`
      # prompt differs …"), at most 200 characters.
      def last_sentence(detail)
        detail.strip.split(/(?<=\.)\s+/).last.to_s[0, 200]
      end
    end
  end
end
