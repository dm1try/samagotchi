# frozen_string_literal: true

require "digest"
require_relative "token_usage"

module Samagotchi
  # One part of a session's system prompt, as its size and its place: what
  # the session file's `prompt_parts` records at each prompt build and the
  # web's head view draws (the text itself is not kept: the sent prompt is,
  # as the session's messages[0]). kind: a SystemPrompt::KINDS word, or
  # "tools" (the tool declarations, wherever the model gets them); label:
  # what the row says ("AGENTS.md", "N declared"); chars: the part's length
  # in the prompt (a multi-item section's headings and joins are in its
  # first part, so a section's parts sum to its text); tokens: chars at
  # TokenUsage's one ratio; ref: the bare memory name (identity, notes,
  # preloads), the file path (agents, appended), "bundle/name" (plugins),
  # the scope (indexes), else nil; scope: a memory part's scope, "project"
  # or "system" (identity: system; a note: its own; a preload: the scope
  # that answered), so the page tells a project x from a system x; nil for
  # other kinds and in a file written before it (the page then matches by
  # name alone).
  #
  # Where it sits in the prompt the build made (docs/internals/working-set.md,
  # Prompt parts as sent), each nil in a file an older chi wrote and left
  # out of #to_h when nil, as scope is:
  # at: the offset its lead starts at; len: its length, lead included (NOT
  # chars: a section's first part is charged its joins); lead: the lead's
  # length (what chi adds before the item's own text: the "System identity
  # …:" line, a note's "## name", a file's header), so the sent slice is
  # head[at, len] and the item's own text head[at + lead, len - lead]. The
  # tools part has one only where the declarations are in the prompt
  # (native: inside the base text, whose slice leaves them out, or Gemma's
  # tail); on a chat host they are a request field. digest: 12 hex of
  # SHA-256 over the item's own text (as PromptNote's); head: 16 hex of
  # SHA-256 of the whole built prompt, the same on every part of a build,
  # so a reader knows whether a saved head is the one the parts were built
  # with. params: how to fetch the item again (string keys): a memory's
  # requested_scope, model_key, fallback_model_key, project_dir,
  # system_dir; a file's path; the tools' [{name, chars}] (chars only where
  # the renderer gives one per tool).
  PromptPart = Data.define(:kind, :label, :chars, :tokens, :ref, :scope, :at, :len, :lead, :digest, :head, :params) do
    def initialize(kind:, label:, chars:, tokens:, ref: nil, scope: nil, at: nil, len: nil, lead: nil, digest: nil, head: nil,
                   params: nil)
      super
    end

    # The fields that say where a part sits (left out of #to_h when nil).
    PLACE = %i[at len lead digest head params].freeze

    # A part of +chars+ characters, its tokens counted by the one ratio.
    def self.build(kind:, label:, chars:, ref: nil, scope: nil, **place)
      new(kind: kind.to_s, label: label.to_s, chars: chars, tokens: tokens_for(chars), ref: ref&.to_s, scope: scope&.to_s,
          **place.slice(*PLACE))
    end

    # @return [Integer] the tokens +chars+ characters count as
    def self.tokens_for(chars) = (chars / TokenUsage::CHARS_PER_TOKEN).ceil

    # The short digests: an item's text (12 hex), the whole prompt (16).
    def self.digest_of(text, size = 12) = Digest::SHA256.hexdigest(text.to_s)[0, size]

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
      int = ->(key) { get.call(key).is_a?(Integer) ? get.call(key) : nil }
      text = ->(key) { get.call(key).is_a?(String) ? get.call(key) : nil }
      params = get.call(:params)
      new(kind: kind, label: get.call(:label).to_s, chars: chars,
          tokens: tokens.is_a?(Numeric) ? tokens.to_i : tokens_for(chars), ref: get.call(:ref)&.to_s,
          scope: get.call(:scope)&.to_s, at: int.call(:at), len: int.call(:len), lead: int.call(:lead),
          digest: text.call(:digest), head: text.call(:head), params: params.is_a?(Hash) ? stringified(params) : nil)
    end

    # +value+ with string keys all the way down (params as a file reads them).
    def self.stringified(value)
      case value
      when Hash then value.to_h { |key, inner| [key.to_s, stringified(inner)] }
      when Array then value.map { |inner| stringified(inner) }
      else value
      end
    end

    # The records of a saved list (others dropped).
    # @return [Array<PromptPart>]
    def self.list(raw)
      Array(raw).filter_map { |entry| from_h(entry) }
    end

    # Each part's key, from the parts list alone (chi web's route takes it,
    # the page's ws_sections.js startRows has the twin): "kind:ref" (the
    # label without a ref), "@scope" when it has one, "#n" for the nth
    # repeat of that in parts order (a duplicate preload: "preloads:x#2").
    # spec/shared/prompt_part_keys.json holds both sides to one list.
    # @param parts [Array<PromptPart, Hash>]
    # @return [Array<String>]
    def self.keys(parts)
      seen = Hash.new(0)
      list(parts).map do |part|
        key = "#{part.kind}:#{part.ref || part.label}"
        key = "#{key}@#{part.scope}" if part.scope
        seen[key] += 1
        seen[key] == 1 ? key : "#{key}##{seen[key]}"
      end
    end

    # The record (the wire's, the file's): without scope and the place
    # fields when it has none, so a part that has none reads as an older
    # chi wrote it.
    def to_h
      hash = super
      hash.delete(:scope) if scope.nil?
      PLACE.each { |key| hash.delete(key) if hash[key].nil? }
      hash
    end

    # The session file's record (string keys).
    def to_file = to_h.transform_keys(&:to_s)
  end
end
