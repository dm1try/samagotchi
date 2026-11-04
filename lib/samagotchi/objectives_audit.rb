# frozen_string_literal: true

require_relative "config"
require_relative "context_note"
require_relative "log"
require_relative "objectives"
require_relative "system_one/question"

module Samagotchi
  # System 1 watching the objectives, in audit: one yes/no per active objective on
  # what just came in (a user's message, a note) and what just went out (a finished
  # answer), each saved as a run for `chi judgments`. Nothing acts on it: no card,
  # no wake, no push, nothing in a prompt. A per-message judge didn't work as a
  # gate on the pod (AUC .5 to .66), so this only collects: docs/system-one.md.
  #
  # Off unless objectives.system_one says audit, a list has an active objective and
  # System 1 has a host. The asks run on SideJudgments' threads, one in flight per
  # direction; what comes meanwhile is a saved skip, with no request.
  class ObjectivesAudit
    MODE = "audit"
    INCOMING = "objectives.incoming"
    OUTGOING = "objectives.outgoing"
    QUESTION_ID = "affects"
    # The most objectives one message asks about.
    MAX_OBJECTIVES = 6
    # What the state carries of a message: a message's head, an answer's tail.
    MESSAGE_CHARS = 2000
    # Narrow triggers: under these there is too little to affect anything.
    INCOMING_MIN_CHARS = 40
    OUTGOING_MIN_CHARS = 400
    COMMAND_LINE = %r{\A\s*[/!]}
    QUESTIONS = {
      INCOMING => "A user works with a coding agent session toward the objective in the state. The state's message just " \
                  "came in, from the user or as a note. Could it change that objective: what it means, whether it still " \
                  "stands, how it is to be met, or whether it is met?",
      OUTGOING => "A coding agent works toward the objective in the state. The state's message is the end of its finished " \
                  "answer. Does it report something that moves that objective on, blocks it, or changes whether it still stands?"
    }.freeze

    # Whether this use is on: config.yml, read at each ask.
    def self.on? = Config.get("objectives.system_one").to_s.strip.downcase == MODE

    # @param client_for [#call] (judgment, session) → a recording client, nil with no host or no saving
    # @param side [SideJudgments]
    # @param state_dir [#call] → the sessions folder
    def initialize(client_for:, side:, state_dir:)
      @client_for = client_for
      @side = side
      @state_dir = state_dir
    end

    # A user's message, at its turn's start: the caller says it is the owner's.
    def incoming(session, text)
      guarded do
        next unless self.class.on? && text.to_s.strip.length >= INCOMING_MIN_CHARS && !text.match?(COMMAND_LINE)

        ask(INCOMING, session, text.to_s.strip[0, MESSAGE_CHARS])
      end
    end

    # A note that just went into the conversation.
    # @param note [Hash] SessionInbox.read_note's
    def note(session, note)
      guarded do
        next unless Objectives.outside_note?(note[:source], note[:objectives])

        incoming(session, note[:text].to_s)
      end
    end

    # A finished answer of the owner's turn: the caller says so.
    def outgoing(session, text)
      guarded do
        next unless self.class.on? && text.to_s.strip.length >= OUTGOING_MIN_CHARS

        ask(OUTGOING, session, text.to_s.strip[-MESSAGE_CHARS..] || text.to_s.strip)
      end
    end

    private

    def ask(judgment, session, message)
      return if session.nil? || session.id.nil? || session.scratch || session.review?

      items = Objectives.current(session.id, session.messages, state_dir: @state_dir.call).items
                        .select { |item| item.status == Objectives::ACTIVE }.first(MAX_OBJECTIVES)
      return if items.empty?

      client = @client_for.call(judgment, session) or return

      states = items.map { |item| { "objective" => objective_text(item), "message" => message.scrub } }
      questions = { QUESTION_ID => SystemOne::Question.new(id: QUESTION_ID, type: "noul", instructions: QUESTIONS.fetch(judgment)) }
      kind = judgment.tr(".", "_").to_sym
      return states.each { |state| client.skip(state: state, questions: questions, reason: "busy") } if @side.in_flight?(kind)

      @side.start(kind, warn: method(:warned)) do
        states.each { |state| client.ask(state: state, questions: questions) }
      end
    end

    # What the objective says, with no id or status: a judgment's state stays
    # comparable across sessions.
    def objective_text(item) = item.done_when ? "#{item.text} (done when: #{item.done_when})" : item.text

    def guarded
      yield
    rescue StandardError => e
      warned(e)
    end

    def warned(error)
      Log.warn(:system_one, "objectives_audit_failed", error: error.class.name, msg: error.message.to_s[0, 200])
    end
  end
end
