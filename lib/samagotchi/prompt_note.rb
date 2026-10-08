# frozen_string_literal: true

module Samagotchi
  # A model note a session's system prompt carried (ModelNotes::Note
  # without its body): what the session file's `prompt_notes` records at
  # each prompt build, so /stats, /model, the web and a later comparison
  # read what the prompt really held. name: the memory name; scope:
  # "system" or "project"; chars: the body's length in the prompt; digest:
  # a short SHA-256 of that body (ModelNotes::Note#digest).
  PromptNote = Data.define(:name, :scope, :chars, :digest) do
    # @param note [ModelNotes::Note]
    def self.from_note(note)
      new(name: note.name, scope: note.scope, chars: note.chars, digest: note.digest)
    end

    # A saved or wire record (string or symbol keys); nil without a name.
    def self.from_h(raw)
      return raw if raw.is_a?(PromptNote)
      return nil unless raw.is_a?(Hash)

      get = ->(key) { raw.key?(key.to_s) ? raw[key.to_s] : raw[key] }
      name = get.call(:name).to_s.strip
      return nil if name.empty?

      chars = get.call(:chars)
      new(name: name, scope: get.call(:scope)&.to_s, chars: chars.is_a?(Numeric) ? chars.to_i : nil,
          digest: get.call(:digest)&.to_s)
    end

    # The records of a saved list (others dropped).
    # @return [Array<PromptNote>]
    def self.list(raw)
      Array(raw).filter_map { |entry| from_h(entry) }
    end

    # "model_notes_deepseek (system, 612 chars), model_notes_x (project,
    # 80 chars)": the line /model, /stats and chi self show; "" without
    # notes. As format.js promptNotesText (spec/shared/labels_matrix.json).
    # @param notes [Array<PromptNote, Hash>]
    def self.text(notes)
      list(notes).map(&:label).join(", ")
    end

    # "model_notes_deepseek (system, 612 chars)".
    def label
      details = [scope, chars && "#{chars} chars"].compact.reject { |part| part.to_s.empty? }
      details.empty? ? name : "#{name} (#{details.join(", ")})"
    end

    # The session file's record (string keys).
    def to_file = to_h.transform_keys(&:to_s)
  end
end
