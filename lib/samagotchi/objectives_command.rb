# frozen_string_literal: true

require_relative "note_delivery"
require_relative "objectives"
require_relative "objectives_check"

module Samagotchi
  # /objectives: with no arguments the session's list (Objectives), each
  # objective's latest move under it (the model's objectives tool; a move
  # changes nothing); `set`, `add`, `edit`, `done`, `drop` and `undo` edit it. An edit is a
  # whole new list in a note file (NoteDelivery, with its refusal of a chi REPL's session), so it is
  # safe from any thread, a turn running or not: it goes into the conversation
  # at the worker's next pass between turns, and a second edit stacks on an
  # unabsorbed first. Nothing here saves the session.
  class ObjectivesCommand
    NAME = "/objectives"
    USAGE = "usage: #{NAME} [set A | B | add TEXT | edit ID TEXT | done ID… | drop ID… | undo ID… | check ID] " \
            "(a text may end \"(done when: …)\"; lines work as | does)".freeze
    NONE = "no objectives; #{NAME} set A | B sets them".freeze
    BETWEEN_TURNS = "(an edit goes into the conversation between turns)"
    # A proposal card's action (Tools::ObjectivesTool): the edit, then the card
    # folds to a line, once: it is recorded, so a repeat applies nothing. A
    # reword's --was says what it was proposed against. The prefix is the
    # card's own; nobody types it.
    CARD = /\A--card\s+(\S+)\s*(?:--was\s+(\S+)\s*)?/
    FOLDS = { Objectives::APPLIED => "Proposal applied", Objectives::DISMISSED => "Proposal dismissed" }.freeze
    DISMISS = "dismiss"
    CHECK = /\Acheck(?:\s|\z)/i

    # @param engine [Engine] #session, #session_state_dir
    def initialize(engine:)
      @engine = engine
    end

    # @param args [String] what follows /objectives
    # @return [Array(String, Symbol)] the reply, and :ok or :error
    def run(args)
      args = args.to_s.strip
      return run_line(args) if args.empty?
      # Not under the lock: a model request. Takes it only to start.
      return ObjectivesCheck.run(@engine, args.split(/\s+/, 2).last) if args.match?(CHECK)

      locked(@engine.session) do
        card, was = args.match(CARD)&.captures
        card ? run_card(card, was, args.sub(CARD, "")) : run_line(args)
      end
    end

    private

    def run_card(card, was, line)
      dir = Session.session_dir(@engine.session.id, state_dir: @engine.session_state_dir)
      answered = Objectives.card_state(dir, card)
      if answered
        fold(card, answered, line)
        return ["this proposal was already #{answered}", :ok]
      end

      output, status = line == DISMISS ? ["", :ok] : run_line(line, was: was)
      return [output, status] unless status == :ok

      state = line == DISMISS ? Objectives::DISMISSED : Objectives::APPLIED
      Objectives.record_card(dir, card, state)
      fold(card, state, line)
      [output, status]
    end

    # An edit's read and write as one step (Objectives.with_lock); a show, alone
    # or an edit's "(no change)", reads as it always did.
    def locked(session, &)
      return yield if session.nil?

      Objectives.with_lock(Session.session_dir(session.id, state_dir: @engine.session_state_dir), &)
    end

    def fold(card, state, line)
      @engine.show_card(source: Objectives::SOURCE, id: card, title: FOLDS.fetch(state),
                        body: state == Objectives::APPLIED ? line : "")
    end

    def run_line(args, was: nil)
      session = @engine.session or return ["no session yet", :error]
      # The running turn's moves aren't in session.messages yet. A snapshot from
      # this thread, read only: an entry is there whole or not yet, and a call
      # with no result yet pairs with nothing.
      list = Objectives.current(session.id, session.messages, state_dir: @engine.session_state_dir,
                                                              running: @engine.live_conversation&.dup)
      verb, rest = args.to_s.strip.split(/\s+/, 2)
      return [listing(list, session), :ok] if verb.nil?

      edited = Objectives::Edit.apply(list, verb.downcase, rest.to_s, was: was)
      return [USAGE, :error] if edited.nil?
      return [edited, :error] if edited.is_a?(String)
      return ["#{listing(list, session)}\n(no change)", :ok] if edited == list

      deliver(edited, session)
    end

    def deliver(list, session)
      result = NoteDelivery.deliver(session.id, text: list.text, source: Objectives::SOURCE,
                                                state_dir: @engine.session_state_dir, objectives: list.to_payload)
      return ["refused: #{NoteDelivery::REPL_REFUSAL}", :error] unless result.delivered?

      @engine.announce_objectives(session)
      ["#{lines_of(list)}\n#{BETWEEN_TURNS}", :ok]
    rescue SessionInbox::NoteRejected => e
      [e.message, :error]
    end

    def listing(list, session)
      return NONE if list.empty?

      dir = Session.session_dir(session.id, state_dir: @engine.session_state_dir)
      checks = ObjectivesCheck.view_of(dir, list)
      pending = Objectives.pending_payload(dir)
      pending ? "#{lines_of(list, checks)}\n#{BETWEEN_TURNS}" : lines_of(list, checks)
    end

    def lines_of(list, checks = {})
      ["objectives:", *list.items.flat_map { |item| item_lines(item, list.moves[item.id], checks[item.id]) }].join("\n")
    end

    def item_lines(item, move, check)
      ["  #{item.line}", *("    last move: #{move.line}" if move), *("    #{ObjectivesCheck.line_of(check)}" if check)]
    end
  end
end
