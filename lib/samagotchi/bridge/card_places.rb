# frozen_string_literal: true

require_relative "../steer"

module Samagotchi
  class Bridge
    # Where a CardStore's entries sit in a session's messages: the turns the
    # page draws after each. The messages count, with the rule the page and
    # the recap share (Steer.turn_opening?); the store's turn log only orders
    # the ids. So a turn with no opening (a reminder, a Continue, a failed or
    # rolled-back one, a prompt stopped before the model) counts nothing, and
    # an opening with no turn id (/continue no's reason) counts as it does on
    # the page. Nothing orders such an opening against an entry, so
    # an entry says how many it came after (+past_idless+, #idless_after), and
    # which one that is when it has an id (+after_opening+, #after_opening).
    #
    # The same place as a stamp (#opening_of, Steer.opening_stamp): the id of
    # the opening the entry comes after (a prompt's turn_id, a line's
    # opening_id), which the page finds by its bubble, not by counting.
    # Pure: no Engine, no file.
    class CardPlaces
      # @param turn_log [Array<String>] the turn ids, oldest first
      # @param messages [Array<Hash>] the messages the page draws
      def initialize(turn_log, messages)
        positions = turn_log.each_with_index.to_h
        openings = Array(messages).select { |message| Steer.turn_opening?(message) }
        @ids = openings.map { |message| message[:turn_id] || message["turn_id"] }
        @stamps = openings.map { |message| stamp_of(message) }
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

      # The opening +entry+ comes after, as #turns_since counts: its id (a
      # prompt's turn_id, a line's opening_id), the page's stamp. nil when it
      # comes before every opening, when that opening has no id (a line an
      # older chi wrote), or for an entry from an older file (+base_since+):
      # the page counts those (turns_since).
      # @param entry [Hash] a store's entry: :turn_id, :past_idless, :after_opening, :base_since
      # @return [String, nil]
      def opening_of(entry)
        return nil if entry[:base_since]

        at_or_before = counted_from(entry[:turn_id])
        return nil unless at_or_before

        run = at_or_before..(at_or_before + idless_run(at_or_before))
        # The line it saved it came after, while that line is in the run (as
        # the count past it, the two save together); else the count's.
        after = entry[:after_opening] && @stamps.index(entry[:after_opening])
        @stamps[after && run.cover?(after) ? after : [at_or_before + entry[:past_idless].to_i, run.end].min]
      end

      # The id of the last opening with no turn id right after the one
      # +turn_id+ counts from (#idless_after's run), nil when there is none or
      # it has no id either.
      # @return [String, nil]
      def after_opening(turn_id)
        at_or_before = counted_from(turn_id)
        return nil unless at_or_before

        run = idless_run(at_or_before)
        run.positive? ? @stamps[at_or_before + run] : nil
      end

      # The openings with no id right after the one +turn_id+ counts from: what
      # an entry shown now has come after. A rollback can only shorten the run, so
      # a count read back against it never eats a later turn.
      # @return [Integer]
      def idless_after(turn_id)
        at_or_before = counted_from(turn_id)
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

      # The last opening whose turn is at or before +turn_id+'s in the log
      # (an index into the openings), nil for none.
      def counted_from(turn_id)
        position = @positions.fetch(turn_id, -1)
        position >= 0 ? @last_at_or_before[position] : nil
      end

      def stamp_of(message) = Steer.opening_stamp(message)

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
