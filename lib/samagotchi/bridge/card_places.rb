# frozen_string_literal: true

require_relative "../steer"

module Samagotchi
  class Bridge
    # Where a CardStore's entries sit in a session's messages: the turns the
    # page draws after each. The messages count, with the rule the page and
    # the recap share (Steer.turn_opening?); the store's turn log only orders
    # the ids. So a turn with no opening (a reminder, a Continue, a failed or
    # rolled-back one, a prompt stopped before the model) counts nothing, and
    # an opening with no id (/continue no's reason, Qwen's recovery line) counts
    # as it does on the page. Nothing orders such an opening against an entry, so
    # an entry says how many it came after (+past_idless+, #idless_after). Pure:
    # no Engine, no file.
    class CardPlaces
      # @param turn_log [Array<String>] the turn ids, oldest first
      # @param messages [Array<Hash>] the messages the page draws
      def initialize(turn_log, messages)
        positions = turn_log.each_with_index.to_h
        @ids = Array(messages).select { |message| Steer.turn_opening?(message) }.map { |message| message[:turn_id] || message["turn_id"] }
        @openings = @ids.size
        @opened = @ids.compact.to_set
        @places = @ids.map { |id| positions[id] }
        index_by_position(@places, turn_log.size)
        @positions = positions
      end

      # The openings after the last one whose turn is at or before the entry's
      # in the log (none: from the first one whose turn is later; none: 0),
      # less the ones with no id it came after. An entry from an older file
      # (+base_since+) has no id: all the log's turns are later, on top of what
      # it had counted.
      # @param entry [Hash] a store's entry: :turn_id, :base_since
      # @return [Integer]
      def turns_since(entry)
        position = @positions.fetch(entry[:turn_id], -1)
        at_or_before = position >= 0 ? @last_at_or_before[position] : nil
        since = if at_or_before
                  @openings - at_or_before - 1 - [entry[:past_idless].to_i, idless_run(at_or_before)].min
                else
                  later = @first_after[position + 1]
                  later ? @openings - later : 0
                end
        entry[:base_since].to_i + since
      end

      # The openings with no id right after the one +turn_id+ counts from: what
      # an entry shown now has come after. A rollback can only shorten the run, so
      # a count read back against it never eats a later turn.
      # @return [Integer]
      def idless_after(turn_id)
        position = @positions.fetch(turn_id, -1)
        at_or_before = position >= 0 ? @last_at_or_before[position] : nil
        at_or_before ? idless_run(at_or_before) : 0
      end

      # Where a log may start and still read an entry at +position+ the same: at
      # the opening that entry counts from, or at the entry's turn with none.
      # @return [Integer] a log position
      def log_start_for(position)
        at_or_before = @last_at_or_before[position]
        at_or_before ? @places[at_or_before] : position
      end

      # @return [Boolean] whether that turn has an opening in the messages
      def opened?(turn_id)
        @opened.include?(turn_id)
      end

      private

      def idless_run(opening)
        @ids.drop(opening + 1).take_while(&:nil?).size
      end

      # For each log position: the last opening at or before it, and the first
      # one at or after it. One pass each, for the store's many entries.
      def index_by_position(places, size)
        @last_at_or_before = Array.new(size)
        @first_after = Array.new(size + 1)
        places.each_with_index do |place, opening|
          next unless place

          @last_at_or_before[place] = opening
          @first_after[place] ||= opening
        end
        (1...size).each { |i| @last_at_or_before[i] = [@last_at_or_before[i - 1], @last_at_or_before[i]].compact.max }
        (size - 1).downto(0) { |i| @first_after[i] = [@first_after[i], @first_after[i + 1]].compact.min }
      end
    end
  end
end
