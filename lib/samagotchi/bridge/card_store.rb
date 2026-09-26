# frozen_string_literal: true

module Samagotchi
  class Bridge
    # The last cards (Engine#show_card) and between-turns notices
    # (:hook_notice with between_turns), for a UI that joins later: the
    # Bridge's snapshot[:cards]. A persistent observer, like
    # TurnAccumulator.
    #
    # A card with an earlier card's id replaces it where it was. Each entry
    # says where it belongs as the recap does: +turns_since+, the turns
    # completed after it (after its own turn for a card shown during one),
    # and +current+ for a card of the turn running now. Turns count from
    # this worker's start; the ones before it are in no entry. A card that
    # isn't the turn's but comes while one runs (an anytime command's, such
    # as /btw) goes after that turn: its prompt is already in the history.
    # A failed turn leaves no prompt, so its cards stay before the next one.
    class CardStore
      CAPACITY = 20
      # A failed turn's prompt goes back to the composer: no turn in the
      # conversation.
      TURN_ENDS = %i[turn_completed turn_canceled].freeze

      def initialize(capacity: CAPACITY)
        @capacity = capacity
        @mutex = Mutex.new
        @entries = []
        @turns_done = 0
        @running = false
      end

      def call(event)
        @mutex.synchronize { fold(event) }
      rescue StandardError
        nil # never break the running turn
      end

      # @return [Array<Hash>] oldest first: the card's (or notice's) fields
      #   plus turns_since: and current:, and during: true for a card that
      #   came while the running turn runs but isn't that turn's (it goes
      #   after the running turn's prompt)
      def list
        @mutex.synchronize do
          @entries.map do |entry|
            turns = entry[:turns]
            current = entry[:in_turn] && @running && turns == @turns_done
            since = @turns_done - turns - (entry[:in_turn] && !current ? 1 : 0)
            listed = entry.except(:turns, :during).merge(turns_since: [since, 0].max, current: current ? true : false)
            listed[:during] = true if entry[:during]
            listed
          end
        end
      end

      private

      def fold(event)
        case event[:type]
        when :turn_started then @running = true
        when :turn_failed
          @running = false
          settle_during(after_turn: false)
        when *TURN_ENDS
          @running = false
          @turns_done += 1
          settle_during(after_turn: true)
        when :card then add_card(event)
        when :hook_notice then add_notice(event) if event[:between_turns]
        end
      end

      def add_card(event)
        card = event.slice(:type, :id, :source, :title, :body, :level, :actions)
        index = @entries.index { |entry| entry[:type] == :card && entry[:id] == card[:id] }
        if index
          # Replaced where it was: the first one's place stays.
          old = @entries[index]
          @entries[index] = card.merge(updated: true, **old.slice(:in_turn, :turns, :during))
        else
          entry = card.merge(in_turn: event[:in_turn] ? true : false, turns: @turns_done)
          entry[:during] = true if @running && !event[:in_turn]
          push(entry)
        end
      end

      # The turn a :during card came in has ended: it counts as after that
      # turn when the turn is in the history.
      def settle_during(after_turn:)
        @entries.each do |entry|
          next unless entry.delete(:during)

          entry[:turns] = @turns_done if after_turn
        end
      end

      def add_notice(event)
        push(event.slice(:type, :hook, :text, :level).merge(in_turn: false, turns: @turns_done))
      end

      def push(entry)
        @entries << entry
        @entries.shift while @entries.size > @capacity
      end
    end
  end
end
