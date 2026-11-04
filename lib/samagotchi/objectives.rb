# frozen_string_literal: true

require_relative "context_note"
require_relative "log"
require_relative "session"
require_relative "session_inbox"

module Samagotchi
  # A session's objectives: what the user wants it to achieve, a list they
  # type (/objectives, ObjectivesCommand). The list lives in the conversation
  # as a note entry (ContextNote::OBJECTIVES_HEADER, its payload under the
  # message's :objectives), each edit a whole new list that replaces the one
  # before it. Pure but for the file reads named below, built from a
  # conversation as WorkingSet is. See docs/internals/objectives.md.
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

    # The list: its items and the number the next id takes (it only grows,
    # so a /objectives set doesn't reuse an id it dropped). Edits answer a
    # new List.
    List = Data.define(:items, :next_number) do
      def initialize(items: [], next_number: 1)
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

      # The note's text: what the model is shown (a dropped one isn't).
      def text
        lines = items.reject { |item| item.status == DROPPED }.map(&:line)
        lines.empty? ? NONE_LEFT : lines.join("\n")
      end

      # What the note carries, in one key style: strings, as a save leaves them.
      def to_payload = { "next" => next_number, "items" => items.map(&:to_payload) }
    end

    module_function

    # The list as +conversation+ leaves it, +pending+ over it: a pending file
    # is newer than anything the conversation holds. Pure.
    # @param conversation [Array<Hash>, nil] the stored entries
    # @param pending [Hash, nil] #pending_payload's
    # @return [List]
    def build(conversation, pending: nil)
      from_payload(pending) || Array(conversation).reduce(List.new) do |list, message|
        (ContextNote.note?(message) && from_payload(ContextNote.fetch(message, :objectives))) || list
      end
    end

    # A session's list now, its unabsorbed newest file included.
    # @return [List]
    def current(session_id, conversation, state_dir:)
      build(conversation, pending: pending_payload(Session.session_dir(session_id, state_dir: state_dir)))
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
