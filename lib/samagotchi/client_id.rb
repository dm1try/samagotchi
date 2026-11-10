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
    # A web page's first prompt when creating a session.
    WEB_CREATE = "web:create"
    # The owner's turn route (POST /api/sessions/:id/turn) given no client_id
    # (a script, curl with the owner's token): named at that seam, a web tab's
    # rights, never a silent nil.
    WEB_UNNAMED = "web:unnamed"
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
    # A durable schedule's turn (chi schedule, the schedule tools):
    # system:schedule:<schedule id>.
    SCHEDULE_PREFIX = "system:schedule:"
    # A plugin's message (Plugin::Sessions#send).
    PLUGIN = "plugin"
    # A relayed answer (RelayVerifier): relay:<parent8>.
    RELAY_PREFIX = "relay:"
    # A participant's review turn: review:<participant id> (chi web stamps
    # it from the participant's token, never from the request's body).
    REVIEW_PREFIX = "review:"

    # Input a human typed: a web tab, a chi TUI, chi send, a participant
    # (review:, a person or an agent they run: never automatic input), and
    # nil, which reaches only a worker's own seams: its initial prompt
    # (spawn_session saves no first_turn_client_id for a person's), a Bridge
    # POST /turn naming none (the Bridge's secret holder: a local TUI or chi
    # web, which names its sender) and an input file from an older chi.
    # SessionManager.deliver_turn refuses nil; chi web's turn route names it
    # (WEB_UNNAMED). An allowlist: delegates, plugins, reminders, context
    # changes and any id chi doesn't know are not.
    HUMAN_PREFIXES = [WEB_PREFIX, TUI_PREFIX, REVIEW_PREFIX].freeze
    HUMAN_IDS = [CLI_SEND].freeze

    # A person at a screen that shows a command's reply and can answer it
    # (#interactive?): a web tab, an attached chi TUI.
    INTERACTIVE_PREFIXES = [WEB_PREFIX, TUI_PREFIX].freeze

    # A turn's origin by its sender (#origin, LastTurn#origin): the ids chi
    # runs turns for on its own, by prefix, and a participant's ("review");
    # system:reminder is "reminder", anything else "client".
    # Which SessionInbox::WakePolicy row a turn delivery from a sender reads
    # (#wake_kind): a person's (:send: un-stops, un-archives) by allowlist,
    # like HUMAN_PREFIXES; the unattended senders' own rows; any other id
    # the safe :automatic row (no un-stop, no un-archive).
    PERSON_WAKE_PREFIXES = [WEB_PREFIX, TUI_PREFIX].freeze
    WAKE_PREFIXES = { SCHEDULE_PREFIX => :schedule, DELEGATE_PREFIX => :delegate,
                      REVIEW_PREFIX => :participant }.freeze

    ORIGIN_PREFIXES = { DELEGATE_PREFIX => "delegate", CHILD_PREFIX => "delegate_report",
                        CONTEXT_PREFIX => "context", TASK_PREFIX => "task", REVIEW_PREFIX => "review",
                        SCHEDULE_PREFIX => "schedule" }.freeze

    module_function

    # What sent a turn: "delegate" (a delegating parent), "delegate_report"
    # (a child's report), "context" (a context wake), "task" (a task finish
    # wake), "review" (a participant), "reminder", "schedule" (a durable
    # schedule's firing), else "client" (the owner, chi send, a plugin, nil).
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

    # The WakePolicy row a turn delivery from +client_id+ reads (deliver_turn's
    # two liveness checks): :send for a person (a web tab, a chi TUI, chi
    # send), :schedule, :plugin, :delegate or :participant for those
    # senders, :automatic for anything else (nil too: deliver_turn refuses it
    # first). Only :send un-stops a stopped session or starts an archived one.
    # @return [Symbol]
    def wake_kind(client_id)
      id = client_id.to_s
      return :send if id == CLI_SEND || PERSON_WAKE_PREFIXES.any? { |prefix| id.start_with?(prefix) }
      return :plugin if id == PLUGIN

      WAKE_PREFIXES.each { |prefix, kind| return kind if id.start_with?(prefix) }
      :automatic
    end

    # The client id a participant's turn carries (chi web's, from their
    # grant): review:<participant id>.
    def review(participant_id) = "#{REVIEW_PREFIX}#{participant_id}"

    # Whether +client_id+ is a participant's (review:).
    def review?(client_id) = client_id.to_s.start_with?(REVIEW_PREFIX)

    # The client id a delegating parent's task and follow-ups carry:
    # delegate:<parent8>.
    def delegate(parent_id) = "#{DELEGATE_PREFIX}#{parent_id.to_s[0, 8]}"

    # The client id a durable schedule's turn carries: system:schedule:<id>.
    def schedule(schedule_id) = "#{SCHEDULE_PREFIX}#{schedule_id}"

    # Whether +client_id+ is a schedule's firing.
    def schedule?(client_id) = client_id.to_s.start_with?(SCHEDULE_PREFIX)
  end
end
