# frozen_string_literal: true

require_relative "token_usage"

module Samagotchi
  # One part of a session's system prompt, as its size: what the session
  # file's `prompt_parts` records at each prompt build and the web's head view
  # draws (the text itself is not kept). kind: a SystemPrompt::KINDS word, or
  # "tools" (the tool declarations, wherever the model gets them); label: what
  # the row says ("AGENTS.md", "N declared"); chars: the part's length in the
  # prompt (a multi-item section's headings and joins are in its first part,
  # so a section's parts sum to its text); tokens: chars at TokenUsage's one
  # ratio; ref: the bare memory name (identity, notes, preloads), the file
  # path (agents, appended), "bundle/name" (plugins), the scope (indexes),
  # else nil.
  PromptPart = Data.define(:kind, :label, :chars, :tokens, :ref) do
    # A part of +chars+ characters, its tokens counted by the one ratio.
    def self.build(kind:, label:, chars:, ref: nil)
      new(kind: kind.to_s, label: label.to_s, chars: chars, tokens: tokens_for(chars), ref: ref&.to_s)
    end

    # @return [Integer] the tokens +chars+ characters count as
    def self.tokens_for(chars) = (chars / TokenUsage::CHARS_PER_TOKEN).ceil

    # A saved or wire record (string or symbol keys); nil without a kind.
    def self.from_h(raw)
      return raw if raw.is_a?(PromptPart)
      return nil unless raw.is_a?(Hash)

      get = ->(key) { raw.key?(key.to_s) ? raw[key.to_s] : raw[key] }
      kind = get.call(:kind).to_s.strip
      return nil if kind.empty?

      chars = get.call(:chars)
      chars = chars.is_a?(Numeric) ? chars.to_i : 0
      tokens = get.call(:tokens)
      new(kind: kind, label: get.call(:label).to_s, chars: chars,
          tokens: tokens.is_a?(Numeric) ? tokens.to_i : tokens_for(chars), ref: get.call(:ref)&.to_s)
    end

    # The records of a saved list (others dropped).
    # @return [Array<PromptPart>]
    def self.list(raw)
      Array(raw).filter_map { |entry| from_h(entry) }
    end

    # The session file's record (string keys).
    def to_file = to_h.transform_keys(&:to_s)
  end
end
