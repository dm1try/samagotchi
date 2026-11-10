# frozen_string_literal: true

require_relative "../context_note"
require_relative "../steer"
require_relative "../turn_note"
require_relative "turn_drawings"

module Samagotchi
  class Bridge
    # A session's messages cut into turns the way the Engine cuts a turn's
    # own messages (its end event's `kept_from`/`kept_to`, Engine#end_turn),
    # read back from the messages alone: what a turn drawing names (its
    # from/to) for a turn that has none (Bridge::TurnDrawings).
    #
    # A turn starts at the reminder lines just before its opening (they
    # went into it: `kept_from` sits before the due reminders), else at its
    # opening (Steer.turn_opening?: a prompt, a wake turn's report), else at
    # the first message after a wake turn's note (the note was there before
    # the turn began: outside, the turn's opening by its id), else at a
    # message no opening came before (a reminder's or a Continue's turn: no
    # prompt). It ends at its last own message: context notes after it, a
    # `!cmd`'s record and a wake's note stay outside, between the turns.
    # A Continue's steps right after the turn it continues read as that
    # turn's (no message tells them apart), as the page groups them.
    module TurnRanges
      # One turn's messages, `messages[from...to]`.
      # +id+: the turn's display id: its opening's turn_id, else
      # "m<from>-<digest8>" (a turn saved before turn ids, a turn with no
      # opening); a later range repeating an id gets "<id>~<from>", so no two
      # ranges share one. +turn_id+: the opening's own turn_id (nil for none).
      # +opening+: the opening's index (a wake note's sits before +from+),
      # nil for a turn with none.
      Range = Data.define(:from, :to, :id, :turn_id, :opening) do
        def range = (from...to)

        # Whether +id+ is a turn's own (not made up here): what an action
        # (Revise, the answer's key) may carry.
        def own_id? = !turn_id.nil? && id == turn_id
      end

      REMINDER = "[SYSTEM: REMINDERS DUE "

      module_function

      # @param messages [Array<Hash>] a session's messages (symbol or string keys)
      # @return [Array<Range>] oldest first
      def of(messages)
        list = Array(messages)
        cuts = cut(list)
        seen = {}
        cuts.map do |from, to, opening|
          turn_id = opening && fetch(list[opening], :turn_id)
          turn_id = nil unless turn_id.is_a?(String) && !turn_id.empty?
          id = turn_id || "m#{from}-#{TurnDrawings.digest(list[from])[0, 8]}"
          id = "#{id}~#{from}" if seen.key?(id)
          seen[id] = true
          Range.new(from: from, to: to, id: id, turn_id: turn_id, opening: opening)
        end
      end

      # Each range's turn record (the session's timing turn records, string
      # or symbol keys): the one with its turn's id, else, for a turn saved
      # before turn ids, the record at its place among the turns with an
      # opening, a failure's that kept nothing not counted (its prompt went
      # back: no opening; the page's timing.js promptRecord rule). A range
      # whose id repeats an earlier one's (…~N) gets none: whose it is
      # can't be told.
      # @return [Array<Hash, nil>] one per range
      def records(ranges, turn_records)
        records = Array(turn_records).grep(Hash)
        placed = records.reject { |record| unopened_record?(record) }
        by_id = {}
        records.each { |record| by_id[fetch(record, :id)] ||= record }
        place = -1
        ranges.map do |range|
          place += 1 if range.opening
          if range.turn_id
            range.own_id? ? by_id[range.turn_id] : nil
          elsif range.opening
            placed[place]
          end
        end
      end

      # [from, to, opening] per turn.
      def cut(list)
        out = []
        turn = nil
        pending = nil
        close = lambda do
          out << [turn[:from], turn[:last] + 1, turn[:opening]] if turn && turn[:last]
          turn = nil
        end
        list.each_with_index do |message, i|
          next unless message.is_a?(Hash)

          if Steer.shell_line?(message)
            close.call
            pending = nil
          elsif fetch(message, :role).to_s == "system"
            if Steer.turn_prompt?(message)
              # A wake's note: the turn it opens starts after it.
              close.call
              pending = nil
              turn = { from: nil, last: nil, opening: i, turn_id: fetch(message, :turn_id) }
            elsif reminder?(message)
              close.call if turn&.dig(:last)
              pending ||= i
            elsif rolled_back?(message)
              # A failure that handed its prompt back (TurnNote.failed, no work
              # kept): the failed turn's own range, its note alone, as the
              # Engine kept it; never the turn before's.
              close.call if turn&.dig(:last)
              out << [pending || i, i + 1, nil]
              turn = nil
              pending = nil
            elsif TurnNote.note?(message)
              turn ||= { from: pending || i, last: nil, opening: nil }
              turn[:from] ||= pending || i
              turn[:last] = i
              pending = nil
            end
            # A context note, the system head: nobody's own.
          elsif Steer.turn_opening?(message)
            id = fetch(message, :turn_id)
            if turn && id && turn[:turn_id] == id && Steer.input?(message)
              # A second opening line of the turn (a wake turn's report after its note).
              turn[:from] ||= pending || i
              turn[:last] = i
            else
              close.call
              turn = { from: pending || i, last: i, opening: i, turn_id: id }
            end
            pending = nil
          else
            turn ||= { from: pending || i, last: nil, opening: nil }
            turn[:from] ||= pending || i
            turn[:last] = i
            pending = nil
          end
        end
        close.call
        out
      end
      private_class_method :cut

      # The note of a failure that kept nothing (TurnNote.failed, not
      # .failed_after): its prompt went back or its turn left no step.
      def rolled_back?(message)
        TurnNote.note?(message) && fetch(message, :content).to_s.start_with?(TurnNote::OPEN + TurnNote::FAILED)
      end
      private_class_method :rolled_back?

      # A turn record that left no opening (a failure that kept nothing:
      # its prompt went back): it has no place among the openings.
      def unopened_record?(record)
        failure = fetch(record, :failure)
        fetch(record, :status).to_s == "failed" && failure.is_a?(Hash) && !fetch(failure, :kept_steps)
      end
      private_class_method :unopened_record?

      def reminder?(message)
        !ContextNote.note?(message) && fetch(message, :content).to_s.start_with?(REMINDER)
      end
      private_class_method :reminder?

      def fetch(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end
      private_class_method :fetch
    end
  end
end
