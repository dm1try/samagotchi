# frozen_string_literal: true

module Samagotchi
  # One edit of what the model is sent (LLMContextView): a tool output,
  # named by its id (ToolIds), sent as a stub instead of its text. Saved
  # on the tool_response entry it changes, under +edits+ (plan D3), keyed
  # by the id, as plain JSON: {"t42" => {"kind" => "stale", "note" => …,
  # "by" => …, "staged_at" => …, "applied_at" => …}}, so it goes wherever
  # the entry goes and a save and load keeps it as written.
  #
  # Copies of an entry share its edits Hash: a rollback checkpoint
  # (Engine#clone_messages), the kernel's duplicate_conversation and a
  # plugin's sessions.fork copy each entry's top level only. So the edits
  # are replaced, never changed in place (.store), or an edit would reach
  # a checkpoint it was rolled back from.
  #
  # kind: :stale (chi saw a later read or edit supersede it) or :forget
  # (the model forgot it, its note keeping the finding); note: what the
  # stub says; by: who made it ("chi", the model); staged_at/applied_at:
  # ISO 8601 times, applied_at nil while it waits to reach the prompt.
  LLMContextEdit = Data.define(:id, :kind, :note, :by, :staged_at, :applied_at) do
    def applied? = !applied_at.nil?

    # What the model reads instead of the output, after the output's
    # "[name]" lead.
    def stub
      kind == :forget ? "(forgotten) #{note}" : note.to_s
    end

    # The saved form, without the id (it is the key).
    def to_h
      { "kind" => kind.to_s, "note" => note, "by" => by, "staged_at" => staged_at, "applied_at" => applied_at }
    end
  end

  class LLMContextEdit
    KINDS = %i[stale forget].freeze

    # +hash+ as saved (string or symbol keys), or nil for one of no known
    # kind.
    def self.from_h(id, hash)
      return nil unless hash.is_a?(Hash)

      field = ->(key) { hash.key?(key.to_s) ? hash[key.to_s] : hash[key] }
      kind = field.call(:kind).to_s.to_sym
      return nil unless KINDS.include?(kind)

      new(id: id.to_s, kind: kind, note: field.call(:note).to_s, by: field.call(:by), staged_at: field.call(:staged_at),
          applied_at: field.call(:applied_at))
    end

    # +entry+ with +edit+ saved on it: a new edits Hash, never the old one
    # changed (copies of the entry share that one).
    def self.store(entry, edit)
      entry[:edits] = (entry[:edits].is_a?(Hash) ? entry[:edits] : {}).merge(edit.id => edit.to_h)
      entry
    end

    # The edits saved on +entry+, by id.
    # @return [Hash{String => LLMContextEdit}]
    def self.on(entry)
      saved = entry[:edits]
      return {} unless saved.is_a?(Hash)

      saved.each_with_object({}) do |(id, hash), edits|
        edit = from_h(id, hash)
        edits[edit.id] = edit if edit
      end
    end
  end
end
