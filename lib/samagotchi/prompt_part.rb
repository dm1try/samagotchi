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
  # else nil; scope: a memory part's scope, "project" or "system" (identity:
  # system; a note: its own; a preload: the scope that answered), so the
  # page tells a project x from a system x; nil for other kinds and in a
  # file written before it (the page then matches by name alone).
  PromptPart = Data.define(:kind, :label, :chars, :tokens, :ref, :scope) do
    def initialize(kind:, label:, chars:, tokens:, ref: nil, scope: nil)
      super
    end

    # A part of +chars+ characters, its tokens counted by the one ratio.
    def self.build(kind:, label:, chars:, ref: nil, scope: nil)
      new(kind: kind.to_s, label: label.to_s, chars: chars, tokens: tokens_for(chars), ref: ref&.to_s, scope: scope&.to_s)
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
          tokens: tokens.is_a?(Numeric) ? tokens.to_i : tokens_for(chars), ref: get.call(:ref)&.to_s,
          scope: get.call(:scope)&.to_s)
    end

    # The records of a saved list (others dropped).
    # @return [Array<PromptPart>]
    def self.list(raw)
      Array(raw).filter_map { |entry| from_h(entry) }
    end

    # The record (the wire's, the file's): without scope when it has none,
    # so a part that has no scope reads as an older chi wrote it.
    def to_h
      hash = super
      hash.delete(:scope) if scope.nil?
      hash
    end

    # The session file's record (string keys).
    def to_file = to_h.transform_keys(&:to_s)
  end
end
