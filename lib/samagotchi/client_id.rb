# frozen_string_literal: true

module Samagotchi
  # Who sent a turn, a line or an answer: its client_id, as a turn's origin,
  # an input file and the events carry it. The one table of the ids chi
  # makes, and of which of them are a human's input (#human?). No requires,
  # so any file can use it.
  module ClientId
    # A web tab (web:<random>, per tab); web:restart, the page's Restart.
    WEB_PREFIX = "web:"
    WEB_RESTART = "web:restart"
    # An attached chi TUI: tui:<pid>.
    TUI_PREFIX = "tui:"
    # chi send's turns and commands.
    CLI_SEND = "cli:send"
    # chi answer's answers (a parent agent's, Guardrails::ParentPolicy).
    CLI_ANSWER = "cli:answer"
    # chi restart.
    CLI_RESTART = "cli:restart"
    # A delegating parent's task or follow-up: delegate:<parent8>.
    DELEGATE_PREFIX = "delegate:"
    # A delegate child's report (ChildReports): child:<child8>.
    CHILD_PREFIX = "child:"
    # A turn chi ran because an attached context source changed:
    # context:<name> (Worker's context wake).
    CONTEXT_PREFIX = "context:"
    # A turn chi ran because a background task this session started
    # finished unseen: task:<task id> (Worker's task finish wake).
    TASK_PREFIX = "task:"
    # chi's own turns; system:reminder, the turn queued when reminders are due.
    SYSTEM_PREFIX = "system:"
    REMINDER = "system:reminder"
    # A plugin's message (Plugin::Sessions#send).
    PLUGIN = "plugin"
    # A relayed answer (RelayVerifier): relay:<parent8>.
    RELAY_PREFIX = "relay:"
    # A participant's review turn: review:<participant id> (chi web stamps
    # it from the participant's token, never from the request's body).
    REVIEW_PREFIX = "review:"

    # Input a human typed: a web tab, a chi TUI, chi send, a participant
    # (review:, a person or an agent they run: never automatic input), and
    # nil (a worker's initial prompt; a web client may send none). An
    # allowlist: delegates, plugins, reminders, context changes and any id
    # chi doesn't know are not.
    HUMAN_PREFIXES = [WEB_PREFIX, TUI_PREFIX, REVIEW_PREFIX].freeze
    HUMAN_IDS = [CLI_SEND].freeze

    # A person at a screen that shows a command's reply and can answer it
    # (#interactive?): a web tab, an attached chi TUI.
    INTERACTIVE_PREFIXES = [WEB_PREFIX, TUI_PREFIX].freeze

    # A turn's origin by its sender (#origin, LastTurn#origin): the ids chi
    # runs turns for on its own, by prefix, and a participant's ("review");
    # system:reminder is "reminder", anything else "client".
    ORIGIN_PREFIXES = { DELEGATE_PREFIX => "delegate", CHILD_PREFIX => "delegate_report",
                        CONTEXT_PREFIX => "context", TASK_PREFIX => "task", REVIEW_PREFIX => "review" }.freeze

    module_function

    # What sent a turn: "delegate" (a delegating parent), "delegate_report"
    # (a child's report), "context" (a context wake), "task" (a task finish
    # wake), "review" (a participant), "reminder", else "client" (the
    # owner, chi send, a plugin, nil).
    # @return [String]
    def origin(client_id)
      id = client_id.to_s
      return "reminder" if id == REMINDER

      ORIGIN_PREFIXES.each { |prefix, origin| return origin if id.start_with?(prefix) }
      "client"
    end

    # Whether +client_id+ is a web tab or a chi TUI, which see a command's
    # reply and can send the line it asks for (CacheConfirm); chi send, a
    # delegate, a plugin, chi itself and nil are not.
    def interactive?(client_id)
      id = client_id.to_s
      INTERACTIVE_PREFIXES.any? { |prefix| id.start_with?(prefix) }
    end

    # Whether +client_id+ (a turn's or a line's origin) is a human's input.
    def human?(client_id)
      return true if client_id.nil?

      id = client_id.to_s
      HUMAN_IDS.include?(id) || HUMAN_PREFIXES.any? { |prefix| id.start_with?(prefix) }
    end

    # The client id a participant's turn carries (chi web's, from their
    # grant): review:<participant id>.
    def review(participant_id) = "#{REVIEW_PREFIX}#{participant_id}"

    # Whether +client_id+ is a participant's (review:).
    def review?(client_id) = client_id.to_s.start_with?(REVIEW_PREFIX)
  end
end
