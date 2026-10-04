# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../atomic_file"
require_relative "../events"

module Samagotchi
  class Bridge
    # The last cards (Engine#show_card), hook notices (:hook_notice) and
    # load warnings (:guardrail_warning), for a UI that joins later: the
    # Bridge's snapshot[:cards]. A persistent observer, like TurnAccumulator.
    #
    # A turn's own notice (no between_turns) is in_turn like a turn's card,
    # with the step it came in: +iteration+ and +calls+, the calls of that
    # iteration started before it (a before_tool_call hook's notice comes
    # before its call's row, so the web puts it above row calls + 1). The
    # loop's "asking again" row (:empty_answer_retry, after an empty or cut
    # answer) and a steer's cut row (:steer_cut) are kept the same way, and so is a question the turn asked
    # (:question_requested), with how it was answered or cancelled, so a
    # reload draws the resolved card where it was.
    #
    # A card with an earlier card's id replaces it where it was. Each entry
    # says where it belongs as the recap does: +turns_since+, the turns
    # completed after it (after its own turn for a card shown during one),
    # and +current+ for a card of the turn running now. A card that
    # isn't the turn's but comes while one runs (an anytime command's, such
    # as /btw) goes after that turn: its prompt is already in the history.
    # A failed turn leaves no prompt, so its cards stay before the next one.
    #
    # Notices (hook notices, load warnings, "asking again" rows) and cards
    # (with questions) are capped apart, +capacity+ each, so a burst of
    # notices can't push out a card. An open question (an approval too) is
    # never pushed out: the oldest other card or answered question goes.
    #
    # With a +path+ (the Bridge's: FILE in the session's folder) the store
    # saves its entries and turn count there on each change, and a later
    # worker's store starts from them, so a turn's cards and notices outlive
    # the worker that showed them; the web reads the file (.saved) for a
    # session no worker runs. Turns count on from the saved count: the
    # placement is relative (turns since), so only the turns after an entry
    # matter. The load warnings stay the worker's own (each start announces
    # its own), and a question still open when the worker went waits for no
    # one: neither is saved or seeded. Same caps as in memory. An entry from
    # an earlier worker lists with +earlier+: true (an attached TUI's resync
    # onto a new worker doesn't print those again).
    class CardStore
      CAPACITY = 20
      NOTICE_TYPES = %i[hook_notice guardrail_warning empty_answer_retry steer_cut].freeze
      FILE = "cards.json"
      # The events after which the file is written again: the ones that
      # change an entry or the turn count.
      SAVED_ON = (%i[card hook_notice empty_answer_retry steer_cut question_requested question_answered question_cancelled
                     question_relay turn_failed] + Events::TURN_KEPT).freeze

      # What a session's saved file lists, as a store started from it lists
      # (no turn running): the web's cards for a session no worker runs.
      # @param session_dir [String]
      # @return [Array<Hash>] [] without a readable file
      def self.saved(session_dir)
        new(path: File.join(session_dir, FILE)).list
      end

      # @param path [String, nil] the file the entries are saved in and
      #   started from; nil keeps them in memory only
      def initialize(capacity: CAPACITY, path: nil)
        @capacity = capacity
        @path = path
        @mutex = Mutex.new
        @entries = []
        @turns_done = 0
        @running = false
        @iteration = nil
        @calls = 0
        seed
      end

      def call(event)
        @mutex.synchronize do
          fold(event)
          save if SAVED_ON.include?(event[:type])
        end
      rescue StandardError
        nil # never break the running turn
      end

      # @return [Array<Hash>] oldest first: the card's (or notice's) fields
      #   plus turns_since: and current:, earlier: true for one an earlier
      #   worker saved, and during: true for a card that
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

      def save
        return unless @path

        entries = @entries.reject { |entry| entry[:type] == :guardrail_warning }
        # A session that never showed one gets no file (the turn count
        # only places entries relative to each other).
        return if entries.empty? && !File.exist?(@path)

        FileUtils.mkdir_p(File.dirname(@path))
        AtomicFile.write(@path, JSON.generate({ "version" => 1, "turns" => @turns_done, "entries" => entries }))
      rescue StandardError
        nil # a card that can't be saved still shows live
      end

      # The entries an earlier worker saved (a missing or broken file:
      # none), their types as symbols again; a card that came during that
      # worker's last turn stays where it was, as after a failed turn.
      def seed
        return unless @path && File.file?(@path)

        data = JSON.parse(File.read(@path), symbolize_names: true)
        return unless data.is_a?(Hash) && data[:turns].is_a?(Integer) && data[:entries].is_a?(Array)

        @turns_done = data[:turns]
        @entries = data[:entries].filter_map do |entry|
          next unless entry.is_a?(Hash) && entry[:type].is_a?(String) && entry[:turns].is_a?(Integer)

          entry = entry.merge(type: entry[:type].to_sym, earlier: true)
          entry unless entry[:type] == :guardrail_warning || open_question?(entry)
        end
        settle_during(after_turn: false)
      rescue StandardError
        @turns_done = 0
        @entries = []
      end

      def fold(event)
        case event[:type]
        when :turn_started
          @running = true
          @iteration = nil
          @calls = 0
        when :generation_started
          @iteration = event[:iteration]
          @calls = 0
        when :tool_call_started
          @iteration = event[:iteration]
          @calls = event[:call_index].to_i
        when :turn_failed
          @running = false
          settle_during(after_turn: false)
        # The turns that stay in the conversation.
        when *Events::TURN_KEPT
          @running = false
          @turns_done += 1
          settle_during(after_turn: true)
        when :card then add_card(event)
        when :hook_notice then add_notice(event)
        # What failed to load (guardrails, plugins): before the first turn
        # this worker runs, where it showed live.
        when :guardrail_warning then push({ type: :guardrail_warning, message: event[:message], label: event[:label] }
                                            .compact.merge(in_turn: false, turns: @turns_done))
        when :empty_answer_retry then add_turn_row(event.slice(:type, :attempt, :of, :stopped_by)) if @running
        when :steer_cut then add_turn_row(event.slice(:type, :source)) if @running
        when :question_requested
          add_turn_row({ type: :question, pending_question: Marshal.load(Marshal.dump(event[:pending_question])) }) if @running
        when :question_answered then resolve_question(event[:id], answer: event[:answer])
        when :question_cancelled then resolve_question(event[:id], cancelled: true, reason: event[:reason])
        when :question_relay then mark_relay(event[:id], event[:relayed_to])
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
        notice = event.slice(:type, :hook, :text, :level)
        if event[:between_turns] || !@running
          push(notice.merge(in_turn: false, turns: @turns_done))
        else
          add_turn_row(notice)
        end
      end

      # A row of the running turn's current step.
      def add_turn_row(row)
        push(row.merge(in_turn: true, turns: @turns_done, iteration: @iteration, calls: @calls).compact)
      end

      def resolve_question(id, **outcome)
        entry = @entries.reverse_each.find do |e|
          e[:type] == :question && e.dig(:pending_question, :id).to_s == id.to_s
        end
        entry&.merge!(Marshal.load(Marshal.dump(outcome.compact)))
      end

      # The open question was relayed to a parent's user, or no longer is.
      def mark_relay(id, relayed_to)
        entry = @entries.reverse_each.find do |e|
          e[:type] == :question && e.dig(:pending_question, :id).to_s == id.to_s
        end
        return unless entry

        if relayed_to
          entry[:pending_question][:relayed_to] = Marshal.load(Marshal.dump(relayed_to))
        else
          entry[:pending_question].delete(:relayed_to)
        end
      end

      def push(entry)
        @entries << entry
        notice = notice?(entry)
        kind = @entries.select { |e| notice?(e) == notice }
        return if kind.size <= @capacity

        evict = kind.find { |e| !open_question?(e) }
        @entries.delete_at(@entries.index { |e| e.equal?(evict) }) if evict
      end

      def notice?(entry) = NOTICE_TYPES.include?(entry[:type])

      def open_question?(entry)
        entry[:type] == :question && !entry.key?(:answer) && !entry[:cancelled]
      end
    end
  end
end
