# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../atomic_file"
require_relative "../events"
require_relative "card_places"

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
    # answer), a steer's cut row (:steer_cut) and a ✂ row (:llm_context_edited,
    # LLMContextNotice) are kept the same way, and so is a question the turn asked
    # (:question_requested), with how it was answered or cancelled, so a
    # reload draws the resolved card where it was.
    #
    # A card with an earlier card's id replaces it where it was. Each entry
    # holds the id of the turn it belongs to or follows (+turn_id+: the running
    # turn's, else the last one's, nil before any) and lists with +turns_since+,
    # the turns drawn after it, counted from the messages the page draws
    # (CardPlaces, with the turn log the store keeps), and +current+ for a card
    # of the turn running now. A card that isn't the turn's but comes while one
    # runs (an anytime command's, such as /btw) goes after that turn: its prompt
    # is already in the history. Listed against messages, an in-turn entry of a
    # turn that left no opening there (failed, rolled back, stopped before the
    # model) stays where it was as a between-turns one: a card or hook notice
    # without its actions; its other rows (no step to sit in) aren't listed. A
    # kept Continue or reminder turn never has an opening: its entries are
    # +continued+ and stay rows.
    #
    # Notices (hook notices, load warnings, "asking again" rows), ✂ rows
    # and cards (with questions) are capped apart, +capacity+ each, so a
    # burst of notices can't push out a card, nor a long turn's ✂ rows a
    # hook's notice. An open question (an approval too) is
    # never pushed out: the oldest other card or answered question goes.
    #
    # With a +path+ (the Bridge's: FILE in the session's folder) the store
    # saves its entries and turn log there on each change, and a later
    # worker's store starts from them, so a turn's cards and notices outlive
    # the worker that showed them; the web reads the file (.saved) for a
    # session no worker runs. The load warnings stay the worker's own (each
    # start announces its own), and a question still open when the worker went
    # waits for no one: neither is saved or seeded. Same caps as in memory. An
    # entry from an earlier worker lists with +earlier+: true (an attached TUI's
    # resync onto a new worker doesn't print those again). An earlier card shown
    # during a turn (+in_turn+) comes back without its actions: they belong
    # to a turn no worker runs any more (check-in's Nudge would steer the
    # new worker's turn). A card shown between turns (github-pr's offer,
    # btw, coordinator) keeps its buttons.
    #
    # A file from before the log (version 1) keeps its places: each entry's
    # count becomes +base_since+, and new openings add to it (#seed_v1).
    class CardStore
      CAPACITY = 20
      NOTICE_TYPES = %i[hook_notice guardrail_warning empty_answer_retry steer_cut].freeze
      # Capped apart from the notices.
      LLM_CONTEXT_TYPES = %i[llm_context_edited].freeze
      LLM_CONTEXT_FIELDS = %i[type moment why freed_tokens tail_tokens staged text groups].freeze
      FILE = "cards.json"
      # The events after which the file is written again: the ones that
      # change an entry or the turn log.
      SAVED_ON = (%i[turn_started card hook_notice empty_answer_retry steer_cut llm_context_edited question_requested question_answered
                     question_cancelled question_relay] + Events::TURN_END).freeze
      # What only the store reads: never listed.
      INTERNAL_FIELDS = %i[turn_id continued base_since past_idless during].freeze

      # What a session's saved file lists, as a store started from it lists
      # (no turn running): the web's cards for a session no worker runs.
      # @param session_dir [String]
      # @param messages [Array<Hash>, nil] the session's messages, for the
      #   places (#list)
      # @return [Array<Hash>] [] without a readable file
      def self.saved(session_dir, messages: nil)
        new(path: File.join(session_dir, FILE)).list(messages: messages)
      end

      # @param path [String, nil] the file the entries are saved in and
      #   started from; nil keeps them in memory only
      # @param messages [#call, nil] the session's messages now (Session#messages:
      #   a running turn leaves them alone, a change replaces the array, so any
      #   thread may read them): where an opening with no id sits against an
      #   entry, and how far the saved log must reach. Read at an idle show, a turn's
      #   end and each save, never to push a running turn's row.
      def initialize(capacity: CAPACITY, path: nil, messages: nil)
        @capacity = capacity
        @path = path
        @messages = messages
        @mutex = Mutex.new
        @entries = []
        @turn_log = []
        @running_turn = nil
        @continuing = false
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

      # @param messages [Array<Hash>, nil] the messages the page draws. Without
      #   them (a body re-read, a trace): no turns_since:, nothing to tell a turn
      #   that left nothing by.
      # @return [Array<Hash>] oldest first: the card's (or notice's) fields
      #   plus current:, turns_since: with +messages+, earlier: true for one an
      #   earlier worker saved, and during: true for a card that came while the
      #   running turn runs but isn't that turn's (it goes after the running
      #   turn's prompt)
      def list(messages: nil)
        @mutex.synchronize do
          places = messages && !@entries.empty? ? CardPlaces.new(@turn_log, messages) : nil
          @entries.filter_map { |entry| listed(entry, places) }
        end
      end

      private

      def listed(entry, places)
        current = current?(entry)
        shown = places && left_nothing?(entry, current, places) ? between_turns(entry) : entry
        return unless shown

        out = shown.except(*INTERNAL_FIELDS)
        out[:turns_since] = places.turns_since(entry) if places
        out[:current] = current
        out[:during] = true if entry[:during]
        out
      end

      # The turn running now's own. An entry with no anchor is none's: nil ==
      # nil would make every one the running turn's while nothing runs.
      def current?(entry)
        entry[:in_turn] && @running_turn && entry[:turn_id] == @running_turn ? true : false
      end

      # An in-turn entry whose turn has no opening in the messages, and was no
      # kept Continue or reminder (those never have one).
      def left_nothing?(entry, current, places)
        entry[:in_turn] && !current && !entry[:continued] && entry[:turn_id] && !places.opened?(entry[:turn_id])
      end

      # Of a turn that left nothing, what stays where it was: a card without
      # its actions (their turn is gone), a hook's notice; its other rows have
      # no step to sit in.
      def between_turns(entry)
        case entry[:type]
        when :card then entry.merge(in_turn: false, **(entry.key?(:actions) ? { actions: [] } : {}))
        when :hook_notice then entry.except(:iteration, :calls).merge(in_turn: false)
        end
      end

      def save
        return unless @path

        entries = @entries.reject { |entry| entry[:type] == :guardrail_warning }
        # A session that never showed one gets no file.
        return if entries.empty? && !File.exist?(@path)

        FileUtils.mkdir_p(File.dirname(@path))
        AtomicFile.write(@path, JSON.generate({ "version" => 2, "turn_log" => pruned_log(entries), "entries" => entries }))
      rescue StandardError
        nil # a card that can't be saved still shows live
      end

      # The log from the opening the earliest anchor counts from: a turn before
      # that orders nothing. All of it when an entry has no anchor, or none does
      # yet (such an entry counts from the log's first turn), or with no messages
      # to find that opening in.
      def pruned_log(entries)
        positions = @turn_log.each_with_index.to_h
        anchors = entries.map { |entry| positions[entry[:turn_id]] }
        return @turn_log if anchors.empty? || anchors.include?(nil) || !@messages

        @turn_log.drop(CardPlaces.new(@turn_log, @messages.call).log_start_for(anchors.min))
      end

      # The entries an earlier worker saved (a missing or broken file: none),
      # their types as symbols again. A card that came during that worker's
      # last turn stays where it was, as after a failed turn, or after that
      # turn when the worker was killed in it: the messages say which.
      def seed
        return unless @path && File.file?(@path)

        data = JSON.parse(File.read(@path), symbolize_names: true)
        return unless data.is_a?(Hash) && data[:entries].is_a?(Array)

        if data[:turn_log].is_a?(Array)
          @turn_log = data[:turn_log].grep(String)
          @entries = seeded(data[:entries])
        elsif data[:turns].is_a?(Integer)
          seed_v1(data)
        end
      rescue StandardError
        @turn_log = []
        @entries = []
      end

      # A file from before the turn log: each entry's place by the count it was
      # saved with, killed turn included (nothing in it can say where a drifted
      # card was). New openings add to it. The next save keeps +base_since+.
      # Can go a retention period after the release that wrote version 2.
      def seed_v1(data)
        killed_in_turn = data[:running] == true
        turns_done = data[:turns] + (killed_in_turn ? 1 : 0)
        olds = data[:entries].select { |entry| entry.is_a?(Hash) && entry[:turns].is_a?(Integer) }
        @entries = seeded(olds.map do |entry|
          turns = entry[:during] && killed_in_turn ? turns_done : entry[:turns]
          entry.except(:turns).merge(base_since: [turns_done - turns - (entry[:in_turn] ? 1 : 0), 0].max)
        end)
      end

      def seeded(entries)
        entries.filter_map do |entry|
          next unless entry.is_a?(Hash) && entry[:type].is_a?(String) && sound_place?(entry)

          entry = entry.except(:during).merge(type: entry[:type].to_sym, earlier: true)
          entry = entry.merge(actions: []) if entry[:type] == :card && entry[:in_turn] && entry.key?(:actions)
          entry unless entry[:type] == :guardrail_warning || open_question?(entry)
        end
      end

      # A hand-edited or foreign file's entry goes, rather than break every later
      # listing of the session.
      def sound_place?(entry)
        return false unless entry[:turn_id].nil? || entry[:turn_id].is_a?(String)

        entry.values_at(:base_since, :past_idless).compact.all? { |count| count.is_a?(Integer) && !count.negative? }
      end

      def fold(event)
        case event[:type]
        when :turn_started
          @turn_log << event[:turn_id] if event[:turn_id]
          @running_turn = event[:turn_id]
          @continuing = event[:continue] ? true : false
          @iteration = nil
          @calls = 0
        when :generation_started
          @iteration = event[:iteration]
          @calls = 0
        when :tool_call_started
          @iteration = event[:iteration]
          @calls = event[:call_index].to_i
        when *Events::TURN_END then end_turn(event)
        when :card then add_card(event)
        when :hook_notice then add_notice(event)
        # What failed to load (guardrails, plugins): before the first turn
        # this worker runs, where it showed live. The Engine announces it inside
        # that turn: it anchors before the turn.
        when :guardrail_warning then push({ type: :guardrail_warning, message: event[:message], label: event[:label] }
                                            .compact.merge(in_turn: false, turn_id: @running_turn ? @turn_log[-2] : @turn_log.last))
        when :empty_answer_retry then add_turn_row(event.slice(:type, :attempt, :of, :stopped_by, :malformed)) if @running_turn
        when :steer_cut then add_turn_row(event.slice(:type, :source)) if @running_turn
        when :llm_context_edited then add_turn_row(Marshal.load(Marshal.dump(event.slice(*LLM_CONTEXT_FIELDS)))) if @running_turn
        when :question_requested
          add_turn_row({ type: :question, pending_question: Marshal.load(Marshal.dump(event[:pending_question])) }) if @running_turn
        when :question_answered then resolve_question(event[:id], answer: event[:answer])
        when :question_cancelled then resolve_question(event[:id], cancelled: true, reason: event[:reason])
        when :question_relay then mark_relay(event[:id], event[:relayed_to])
        end
      end

      # The running turn ended. A :during card now reads as after it when its
      # opening is in the messages, and as before the next turn when not. A
      # failed Continue or wake left nothing either, opening or not.
      def end_turn(event)
        settle_past_idless
        @entries.each do |entry|
          entry.delete(:during)
          entry.delete(:continued) if entry[:turn_id] == @running_turn && !Events.kept_turn?(event)
        end
        @running_turn = nil
      end

      # What the running turn showed that isn't its own (an anytime command's
      # card) goes after that turn, so after any opening with no id inside it. The
      # end event's messages hold the turn; its own rows count such a line as usual.
      def settle_past_idless
        shown = @entries.select { |entry| entry[:turn_id] == @running_turn && !entry[:in_turn] }
        return if shown.empty? || !@messages

        run = CardPlaces.new(@turn_log, @messages.call).idless_after(@running_turn)
        shown.each { |entry| entry[:past_idless] = run if run.positive? }
      end

      # The entry's anchor: the running turn, else the last one.
      def anchor = @running_turn || @turn_log.last

      def add_card(event)
        card = event.slice(:type, :id, :source, :title, :body, :level, :actions)
        index = @entries.index { |entry| entry[:type] == :card && entry[:id] == card[:id] }
        if index
          # Replaced where it was: the first one's place stays.
          old = @entries[index]
          @entries[index] = card.merge(updated: true, **old.slice(:in_turn, :turn_id, :during, :continued, :base_since, :past_idless))
        else
          entry = card.merge(in_turn: event[:in_turn] ? true : false, turn_id: anchor)
          entry[:during] = true if @running_turn && !event[:in_turn]
          entry[:continued] = true if @running_turn && event[:in_turn] && @continuing
          push(entry)
        end
      end

      def add_notice(event)
        notice = event.slice(:type, :hook, :text, :level, :fallback_for)
        if event[:between_turns] || !@running_turn
          push(notice.merge(in_turn: false, turn_id: anchor))
        else
          add_turn_row(notice)
        end
      end

      # A row of the running turn's current step.
      def add_turn_row(row)
        entry = row.merge(in_turn: true, turn_id: @running_turn, iteration: @iteration, calls: @calls).compact
        entry[:continued] = true if @continuing
        push(entry)
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
        note_past_idless(entry) unless @running_turn
        @entries << entry
        cap = cap_class(entry)
        kind = @entries.select { |e| cap_class(e) == cap }
        return if kind.size <= @capacity

        evict = kind.find { |e| !open_question?(e) }
        @entries.delete_at(@entries.index { |e| e.equal?(evict) }) if evict
      end

      # Shown between turns: below the openings with no id already there.
      def note_past_idless(entry)
        return unless @messages

        run = CardPlaces.new(@turn_log, @messages.call).idless_after(entry[:turn_id])
        entry[:past_idless] = run if run.positive?
      end

      # Which cap +entry+ counts against: :notice, :llm_context or :card.
      def cap_class(entry)
        return :llm_context if LLM_CONTEXT_TYPES.include?(entry[:type])

        NOTICE_TYPES.include?(entry[:type]) ? :notice : :card
      end

      def open_question?(entry)
        entry[:type] == :question && !entry.key?(:answer) && !entry[:cancelled]
      end
    end
  end
end
