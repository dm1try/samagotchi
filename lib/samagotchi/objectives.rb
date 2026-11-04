# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

require_relative "atomic_file"
require_relative "context_note"
require_relative "llm_context_stale"
require_relative "log"
require_relative "session"
require_relative "session_inbox"
require_relative "tools/objectives_tool"

module Samagotchi
  # A session's objectives: what the user wants it to achieve, a list they
  # type (/objectives, ObjectivesCommand). The list lives in the conversation
  # as a note entry (ContextNote::OBJECTIVES_HEADER, its payload under the
  # message's :objectives), each edit a whole new list that replaces the one
  # before it. Pure but for the file reads named below, built from a
  # conversation as WorkingSet is. The model's moves are its calls of the
  # objectives tool (Tools::ObjectivesTool), read back from the same
  # conversation: not entries. See docs/internals/objectives.md.
  module Objectives
    # Who a list's note is from (ContextNote's label).
    SOURCE = "objectives"
    ACTIVE = "active"
    DONE = "done"
    DROPPED = "dropped"
    STATUSES = [ACTIVE, DONE, DROPPED].freeze
    ID = /\AO(\d+)\z/
    # What a list with nothing left to send says, so that it still replaces
    # the one before it.
    NONE_LEFT = "(no objectives now)"
    # Cards a turn may leave: a model's proposals are for reading.
    PROPOSALS_PER_TURN = 3
    # Beside the session's notes/: what #with_lock takes.
    LOCK_FILE = "objectives.lock"
    # Proposal cards answered, {card id => APPLIED | DISMISSED}, so that a repeat
    # of a card's line can't apply again. Under #with_lock.
    CARDS_FILE = "objectives_cards.json"
    APPLIED = "applied"
    DISMISSED = "dismissed"
    # A text's own done-when: the last group, an earlier one stays text.
    DONE_WHEN = /\A(.*)\(done when:\s*(.*?)\s*\)\z/i

    # One objective: +id+ "O1", never reused; +status+ ACTIVE, DONE or
    # DROPPED; +done_when+ an optional hint, never enforced.
    Item = Data.define(:id, :text, :status, :done_when) do
      def initialize(id:, text:, status: ACTIVE, done_when: nil)
        super
      end

      # The line the frame and /objectives show.
      def line
        mark = status == ACTIVE ? "" : "[#{status}] "
        "#{id} #{mark}#{text}#{" (done when: #{done_when})" if done_when}"
      end

      def to_payload = { "id" => id, "text" => text, "status" => status, "done_when" => done_when }.compact
    end

    # What the model last said moved an objective: information only, read
    # from its tool call, and shown by /objectives.
    Move = Data.define(:id, :note, :evidence) do
      def line = evidence.empty? ? note : "#{note} (evidence: #{evidence})"
    end

    # What the user did to one objective between two lists, for the entry's
    # line: +kind+ added, done, dropped, reopened or reworded; +was+ a
    # reworded one's old text. Display only, computed from the two lists.
    Change = Data.define(:id, :kind, :text, :was) do
      def to_h = { id: id, kind: kind, text: text, was: was }.compact
    end

    # A change the model proposes (the objectives tool), shown to the user as a
    # card whose action is #line: the same edit they could type. +change+ add,
    # reword, done or drop; +note+ why.
    Proposal = Data.define(:change, :id, :text, :note, :was) do
      # +was+: what a reword was proposed against (Objectives.fingerprint).
      def initialize(change:, id:, text:, note:, was: nil)
        super
      end

      # A proposal against +list+: a reword keeps the item's done-when unless its
      # text brings one, and carries what it was proposed against.
      def self.against(list, change:, id:, text:, note:)
        item = change == "reword" ? list.find(id) : nil
        return new(change: change, id: id, text: text, note: note) unless item

        kept = item.done_when && !text.empty? && !text.match?(DONE_WHEN) ? "#{text} (done when: #{item.done_when})" : text
        new(change: change, id: id, text: kept, note: note, was: Objectives.fingerprint(item))
      end

      # What's wrong with it against +list+, nil when it can apply.
      def refusal(list)
        return "change must be add, reword, done or drop" unless %w[add reword done drop].include?(change)
        return "#{change} needs a text" if %w[add reword].include?(change) && text.empty?
        return nil if change == "add"

        list.find(id) ? nil : "no objective #{id} (this session's: #{list.items.map(&:id).join(", ")})"
      end

      # The /objectives line that applies it. An add's text can't split in two.
      def line
        case change
        when "add" then "/objectives add #{text.gsub(/(?<!\S)\|(?!\S)/, "/")}"
        when "reword" then "/objectives edit #{id} #{text}"
        else "/objectives #{change} #{id}"
        end
      end

      # The card's Apply: #line behind the prefix ObjectivesCommand reads.
      def action_line(card)
        line.sub("/objectives ", "/objectives --card #{card} #{"--was #{was} " if was}")
      end

      def title
        case change
        when "add" then "Add an objective?"
        when "reword" then "Reword #{id}?"
        when "done" then "Mark #{id} done?"
        else "Drop #{id}?"
        end
      end

      # The card's body: what, why, and the line for a terminal, which shows no button.
      def body = [(text unless text.empty?), (note unless note.empty?), "`#{line}`"].compact.join("\n\n")
    end

    # The list: its items and the number the next id takes (it only grows,
    # so a /objectives set doesn't reuse an id it dropped), and +moves+, the
    # latest Move per id, which #build folds from the tool calls (never in
    # the frame or the payload). Edits answer a new List.
    List = Data.define(:items, :next_number, :moves) do
      def initialize(items: [], next_number: 1, moves: {})
        super
      end

      # Nothing was ever set.
      def empty? = items.empty?

      def find(id) = items.find { |item| item.id == id }

      # @param text [String]
      # @param done_when [String, nil]
      # @return [List]
      def add(text, done_when: nil)
        with(items: items + [Item.new(id: "O#{next_number}", text: text, done_when: done_when)], next_number: next_number + 1)
      end

      # A new list in place of this one; the ids go on from this one's.
      # @param entries [Array<Hash>] {text:, done_when:}
      # @return [List]
      def set(entries)
        entries.reduce(with(items: [])) { |list, entry| list.add(entry[:text], done_when: entry[:done_when]) }
      end

      # @return [List]
      def mark(id, status)
        with(items: items.map { |item| item.id == id ? item.with(status: status) : item })
      end

      # @return [List]
      def reword(id, text, done_when: nil)
        with(items: items.map { |item| item.id == id ? item.with(text: text, done_when: done_when) : item })
      end

      # The note's text: what the model is shown (a dropped one isn't).
      def text
        lines = items.reject { |item| item.status == DROPPED }.map(&:line)
        lines.empty? ? NONE_LEFT : lines.join("\n")
      end

      # What the note carries, in one key style: strings, as a save leaves them.
      def to_payload = { "next" => next_number, "items" => items.map(&:to_payload) }

      # What the page draws: the items, each with its last move, and whether
      # the newest edit is still a file waiting to go in.
      def to_view(pending:)
        { items: items.map { |item| item_view(item) }, pending: pending }
      end

      private

      def item_view(item)
        move = moves[item.id]
        move ? item.to_payload.merge("move" => { "note" => move.note, "evidence" => move.evidence }) : item.to_payload
      end
    end

    module_function

    # One edit's read and write as one step, across threads (each anytime command
    # has its own) and processes: each note holds a whole list, so two edits that
    # read the same list would lose one. The worker's absorb holds it too, so an
    # edit reads neither between the note going into the conversation and its
    # file going. An edit's events go under it: the order is always this lock,
    # then the event log. Nothing takes this under the event log.
    def with_lock(session_dir)
      FileUtils.mkdir_p(session_dir)
      File.open(File.join(session_dir, LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      end
    end

    # An item's words, short: what a proposed reword was made against.
    def fingerprint(item) = Digest::SHA256.hexdigest("#{item.text}\0#{item.done_when}")[0, 12]

    # How a proposal card was answered, nil when it wasn't. Under #with_lock.
    def card_state(session_dir, card)
      JSON.parse(File.read(File.join(session_dir, CARDS_FILE)))[card]
    rescue SystemCallError, JSON::ParserError, TypeError
      nil
    end

    # Under #with_lock.
    def record_card(session_dir, card, state)
      path = File.join(session_dir, CARDS_FILE)
      known = begin
        JSON.parse(File.read(path))
      rescue SystemCallError, JSON::ParserError
        {}
      end
      AtomicFile.write(path, JSON.generate(known.merge(card => state)))
    end

    # The id a call names, as the list spells it.
    def move_id(call) = call[:id].to_s.strip.upcase

    # A call's text as one line.
    def clean(text) = text.to_s.gsub(/[[:space:]]+/, " ").strip

    # The list as +conversation+ leaves it, +pending+ over it: a pending file
    # is newer than anything the conversation holds. Pure.
    # @param conversation [Array<Hash>, nil] the stored entries
    # @param pending [Hash, nil] #pending_payload's
    # @param running [Array<Hash>, nil] the running turn's conversation, which
    #   +conversation+ (a session's messages) doesn't hold yet: its moves count
    # @return [List]
    def build(conversation, pending: nil, running: nil)
      conversation = Array(conversation)
      list = from_payload(pending) || conversation.reduce(List.new) do |so_far, message|
        (ContextNote.note?(message) && from_payload(ContextNote.fetch(message, :objectives))) || so_far
      end
      list.empty? ? list : list.with(moves: moves_in(conversation).merge(moves_in(Array(running))))
    end

    # The latest Move per id among the conversation's objectives calls that
    # recorded one (LLMContextStale.paired_runs, as the working set reads its
    # runs: a call_tool's too, both hosts' forms). Tools::ObjectivesTool
    # .recorded? is the check: a call with no list, a refused, a denied or an
    # interrupted one recorded nothing.
    # @return [Hash{String => Move}]
    def moves_in(conversation)
      LLMContextStale.paired_runs(conversation).each_with_object({}) do |run, moves|
        next unless run.call[:name] == Tools::ObjectivesTool::NAME

        id = move_id(run.call)
        next unless Tools::ObjectivesTool.recorded?(run.text, id)

        moves[id] = Move.new(id: id, note: clean(run.call[:note]), evidence: clean(run.call[:evidence]))
      end
    end

    # A session's list now, its unabsorbed newest file included.
    # @return [List]
    def current(session_id, conversation, state_dir:, running: nil)
      build(conversation, pending: pending_payload(Session.session_dir(session_id, state_dir: state_dir)), running: running)
    end

    # The list as the page draws it (List#to_view), nil with no list: the page
    # shows nothing then.
    # @return [Hash, nil]
    def view(session_id, conversation, state_dir:, running: nil)
      pending = pending_payload(Session.session_dir(session_id, state_dir: state_dir))
      list = build(conversation, pending: pending, running: running)
      list.empty? ? nil : list.to_view(pending: !pending.nil?)
    end

    # One note's list for the page's entry: its items and, when there was a
    # list before it, what changed.
    # @param payload [Object] the note's :objectives
    # @param before [List, nil] the list before this note
    # @return [Hash, nil] nil for what isn't a list
    def entry(payload, before: nil)
      list = from_payload(payload) or return nil

      fields = { items: list.items.map(&:to_payload) }
      fields[:changes] = changes(before, list).map(&:to_h) if before && !before.empty?
      fields
    end

    # What the user did between two lists, in the new list's order.
    # @return [Array<Change>]
    def changes(before, after)
      (before.items.map(&:id) | after.items.map(&:id)).filter_map do |id|
        change_of(before.find(id), after.find(id))
      end
    end

    # The newest objectives note waiting in +session_dir+'s notes/.
    # @return [Hash, nil] its payload
    def pending_payload(session_dir)
      SessionInbox.find_new_note_files(session_dir).reverse_each do |file|
        payload = SessionInbox.read_note(file)&.dig(:objectives)
        return payload if from_payload(payload)
      end
      nil
    end

    # @param payload [Object] a note's :objectives; either key style reads
    # @return [List, nil] nil for what isn't a list (+next+ not an Integer,
    #   +items+ not an Array): it can't wipe the fold or restart the ids
    def from_payload(payload)
      return nil unless payload.is_a?(Hash)

      payload = payload.transform_keys(&:to_s)
      return nil unless payload["next"].is_a?(Integer) && payload["items"].is_a?(Array)

      items = payload["items"].filter_map { |raw| item_of(raw) }
      highest = items.map { |item| item.id[ID, 1].to_i }.max || 0
      List.new(items: items, next_number: [payload["next"], highest + 1].max)
    end

    # A continue's copy: +previous+'s list as a note file in the new link,
    # read fresh, its unabsorbed newest file included. It runs inside the
    # continue's rollback, and a link without the list is still a good link:
    # a failure is logged. Not for a review link, whose next link's
    # participants could differ (as SessionChain.carried_answer).
    # @return [String, nil] the note file's path
    def carry(previous, to:, state_dir:)
      return nil if previous.review?

      list = current(previous.id, Session.load(previous.id, state_dir: state_dir).messages, state_dir: state_dir)
      return nil if list.empty?

      SessionInbox.write_note(to, text: list.text, source: SOURCE, objectives: list.to_payload, state_dir: state_dir)
    rescue StandardError => e
      Log.warn(:worker, "continue_objectives_failed", sid: previous.id, error: e.class.name, msg: e.message)
      nil
    end

    def change_of(was, now)
      return Change.new(id: was.id, kind: DROPPED, text: was.text, was: nil) unless now
      return Change.new(id: now.id, kind: "added", text: now.text, was: nil) unless was

      if now.text != was.text || now.done_when != was.done_when
        Change.new(id: now.id, kind: "reworded", text: now.text, was: was.text)
      elsif now.status != was.status
        Change.new(id: now.id, kind: now.status == ACTIVE ? "reopened" : now.status, text: now.text, was: nil)
      end
    end
    private_class_method :change_of

    def item_of(raw)
      return nil unless raw.is_a?(Hash)

      raw = raw.transform_keys(&:to_s)
      return nil unless ID.match?(raw["id"].to_s) && !raw["text"].to_s.empty?

      status = STATUSES.include?(raw["status"]) ? raw["status"] : ACTIVE
      Item.new(id: raw["id"].to_s, text: raw["text"].to_s, status: status, done_when: raw["done_when"]&.to_s)
    end
    private_class_method :item_of
  end
end
