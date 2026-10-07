# frozen_string_literal: true

require_relative "tool_response"
require_relative "context_note"

module Samagotchi
  # chi's own ids for tool outputs, one per run ("t41"), saved on the
  # tool_response entry as tool_ids (ToolResponse.joined: one per call of
  # the batch; ToolResponse.single: its one call). A strategy's edits
  # (LLMContextView) name the outputs they change by them; the prompt never
  # shows them under none.
  #
  # The next id is one past the highest the conversation holds, read when
  # the runs are added: the ids live on the entries, so they go wherever
  # the entries go (a turn's result, a save and load, --resume, a plugin's
  # sessions.fork) with no counter of their own to keep in step. A rollback
  # drops the later entries and their ids with them; an id handed out
  # again after it names an output nothing else refers to any more (an
  # edit is saved on the entry it changes, so it went too).
  #
  # Copies of an entry share its tool_ids Array (a checkpoint, a fork and
  # duplicate_conversation copy the top level only): set it, never change
  # it in place.
  #
  # An entry saved before the ids has none: #refs derives them on read
  # from its index and the run's position ("e12.1"), marked derived, so a
  # later strategy can refuse to change what it can't name for sure.
  # #refs_at counts that index as if the conversation had its system head:
  # each request puts a head on the stored messages
  # (ContextNote.with_system_head replaces a saved one, and adds one to a
  # head-less fork or a session before its first save), so an entry's
  # derived id is the same in the stored session, every request and the
  # warm-up, and an edit saved under it still names its run.
  module ToolIds
    PATTERN = /\At(\d+)\z/
    DERIVED_PREFIX = "e"

    # One run's id in an entry: the id, the run's position (0-based) and
    # whether it was derived.
    Ref = Data.define(:id, :run, :derived) do
      def derived? = derived
    end

    module_function

    # +count+ ids for runs about to go on +conversation+.
    # @return [Array<String>]
    def next_ids(conversation, count)
      first = highest(conversation) + 1
      Array.new(count) { |offset| "t#{first + offset}" }
    end

    # The highest stored id's number in +conversation+, 0 for none.
    def highest(conversation)
      Array(conversation).reduce(0) do |max, entry|
        next max unless entry.is_a?(Hash) && entry[:role].to_s == "tool_response"

        Array(entry[:tool_ids]).reduce(max) do |acc, id|
          (match = PATTERN.match(id.to_s)) ? [acc, match[1].to_i].max : acc
        end
      end
    end

    # The ids of +conversation+[+index+]'s runs: #refs, a derived id
    # counted as if the conversation had its system head.
    # @return [Array<Ref>]
    def refs_at(conversation, index)
      refs(conversation[index], ContextNote.system_head?(conversation.first) ? index : index + 1)
    end

    # The ids of +entry+'s runs (+index+ its place in the conversation):
    # the stored tool_ids, else derived ones, one per run (a chat result
    # paired by tool_call_id is one run; a native entry has a run per
    # "[name]" part, ToolResponse.split).
    # @return [Array<Ref>]
    def refs(entry, index)
      ids = Array(entry[:tool_ids])
      return ids.each_with_index.map { |id, run| Ref.new(id: id.to_s, run: run, derived: false) } unless ids.empty?

      count = entry[:tool_call_id] ? 1 : [ToolResponse.split(entry[:content]).size, 1].max
      Array.new(count) { |run| Ref.new(id: "#{DERIVED_PREFIX}#{index}.#{run + 1}", run: run, derived: true) }
    end
  end
end
