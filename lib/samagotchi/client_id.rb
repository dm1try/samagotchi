# frozen_string_literal: true

module Samagotchi
  # Who sent a turn, a line or an answer: its client_id, as a turn's origin,
  # an input file and the events carry it. The one table of the ids chi
  # makes (ROWS: one Sender row each), and what each may do. No requires,
  # so any file can use it.
  module ClientId
    # A web tab (web:<random>, per tab); web:restart, the page's Restart.
    WEB_PREFIX = "web:"
    WEB_RESTART = "web:restart"
    # A web page's first prompt when creating a session.
    WEB_CREATE = "web:create"
    # The owner's turn or command route (POST /api/sessions/:id/turn,
    # /command) given no client_id (a script, curl with the owner's token):
    # named at that seam, a web tab's rights, never a silent nil.
    WEB_UNNAMED = "web:unnamed"
    # An attached chi TUI: tui:<pid>.
    TUI_PREFIX = "tui:"
    # chi send's turns and commands.
    CLI_SEND = "cli:send"
    # chi answer's answers (a parent agent's, Guardrails::ParentPolicy).
    CLI_ANSWER = "cli:answer"
    # An agent's chi send (Claude Code, Codex, an MCP host, another chi
    # session's shell; AgentCaller names it): agent:<name>. Not the owner:
    # it restarts no stopped session, brings back no archived one, runs no
    # ! line.
    AGENT_PREFIX = "agent:"
    # The longest name an agent's id carries (AgentCaller.clean).
    AGENT_NAME_MAX = 32
    # Another chi session's question (its model's ask_session tool):
    # session:<id8>. As an agent's, and always a visitor (Visitor); no
    # session command, never merged into a running turn.
    SESSION_PREFIX = "session:"
    # chi restart.
    CLI_RESTART = "cli:restart"
    # A delegating parent's task or follow-up: delegate:<parent8>.
    DELEGATE_PREFIX = "delegate:"
    # A delegate child's report (ChildReports): child:<child8>.
    CHILD_PREFIX = "child:"
    # A turn chi ran because an attached context source changed:
    # context:<name> (Worker's context wake).
    CONTEXT_PREFIX = "context:"
    # A turn chi ran because a peer agent's message asked: peer:<name>
    # (Worker's mail wake, WorkerInbound::MailWake).
    PEER_PREFIX = "peer:"
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
    # A participant's turn: participant:<participant id> (chi web stamps it
    # from the participant's token, never from the request's body). Not
    # their author (Steer::PARTICIPANT_PREFIX, "p:<id>"), which says who
    # wrote a turn: this says which sender delivered it.
    PARTICIPANT_PREFIX = "participant:"
    # compat shim review_client_id: the legacy review:<id> participant id
    # used before 0.172 (still in turn_drawings.jsonl, input files and an
    # older chi web still running): read it as a participant's, never the
    # owner's, and send it to a worker without Delivery::PARTICIPANT_ID_FEATURE.
    LEGACY_REVIEW_PREFIX = "review:"

    # A worker's own first prompt (spawn_session's) when no sender was
    # saved for it (WorkerInbound#initial_origin: a person's session saves
    # no first_turn_client_id, nor did an older chi): the owner's, as chi
    # send's. Seen in turn_drawings.jsonl and a turn's SSE origin, labelled
    # as no sender is (the TUI's "user", the web's none).
    FIRST_PROMPT = "spawn:first"
    # A person's answer to a card that queues a command (ContinueOffer's
    # Continue / Stop: a TUI's or the web's answer names no sender, only
    # chi answer's does): the owner's, labelled as no sender is.
    CARD_ANSWER = "card:answer"

    # One sender: its id (+match+: the whole id, or a prefix ending in ":"
    # for the ids that carry a suffix) and what it may do:
    #   human       — a human's input (a web tab, a chi TUI, chi send, a
    #                 participant: never automatic input);
    #   owner       — the owner's input: session commands (CommandIntake),
    #                 un-archive and wake resets (Worker#user_input);
    #   interactive — a screen that shows a command's reply and can answer
    #                 it (CacheConfirm, /parent-answers);
    #   wake        — the SessionInbox::WakePolicy row a delivery reads
    #                 (only :send un-stops and un-archives);
    #   origin      — LastTurn#origin / TurnOrigin#source;
    #   source      — a merged line's Steer source: a String, nil (the
    #                 user's own), :automatic ("automatic:<id>") or :named
    #                 (the client id itself: an agent's "agent:<name>");
    #   label       — the TUI's and the web's word for it (turn_events.js
    #                 CLIENT_LABELS keeps the same; nil: as no sender, the
    #                 TUI's "user", the web's none).
    Sender = Data.define(:match, :human, :owner, :interactive, :wake, :origin, :source, :label) do
      def prefix? = match.to_s.end_with?(":")
    end

    person = { human: true, owner: true, interactive: true, wake: :send, origin: "client", source: nil }
    unattended = { human: false, owner: false, interactive: false, wake: :automatic, origin: "client", source: :automatic,
                   label: "automatic" }

    # An agent's message: no human's, never the owner's; its source and
    # label carry its name (Steer.source_for_client, #label_for).
    agent = Sender.new(match: AGENT_PREFIX, human: false, owner: false, interactive: false, wake: :agent, origin: "agent",
                       source: :named, label: "agent")
    # Another chi session's question: delivered as an agent's is.
    session_question = agent.with(match: SESSION_PREFIX, origin: "session", label: "session")

    # A participant: a human's input, never the owner's.
    participant = Sender.new(match: PARTICIPANT_PREFIX, human: true, owner: false, interactive: false, wake: :participant,
                             origin: "participant", source: "participant", label: "invited")

    # Every id chi makes: an allowlist. Delegates, plugins, reminders,
    # context changes and any id chi doesn't know (UNKNOWN) are no human's.
    ROWS = [
      Sender.new(match: WEB_PREFIX, **person, label: "web"),
      Sender.new(match: WEB_RESTART, **person, label: "web"),
      Sender.new(match: WEB_CREATE, **person, label: "web"),
      Sender.new(match: WEB_UNNAMED, **person, label: "web"),
      Sender.new(match: TUI_PREFIX, **person, label: "tui"),
      Sender.new(match: CLI_SEND, **person, interactive: false, source: "chi_send", label: "chi send"),
      Sender.new(match: FIRST_PROMPT, **person, interactive: false, label: nil),
      Sender.new(match: CARD_ANSWER, **person, interactive: false, wake: :automatic, label: nil),
      # chi answer's: no human's input (a parent agent's), but CommandIntake
      # lets its commands run (CommandIntake::ALLOWED_IDS).
      Sender.new(match: CLI_ANSWER, **unattended, label: "chi answer"),
      Sender.new(match: CLI_RESTART, **unattended),
      Sender.new(match: DELEGATE_PREFIX, **unattended, wake: :delegate, origin: "delegate", source: "parent_agent",
                 label: "delegate"),
      Sender.new(match: CHILD_PREFIX, **unattended, origin: "delegate_report", source: "delegate_report",
                 label: "delegate report"),
      Sender.new(match: CONTEXT_PREFIX, **unattended, origin: "context"),
      Sender.new(match: PEER_PREFIX, **unattended, origin: "peer", label: "peer"),
      Sender.new(match: TASK_PREFIX, **unattended, origin: "task"),
      Sender.new(match: SYSTEM_PREFIX, **unattended, label: "reminder"),
      Sender.new(match: REMINDER, **unattended, origin: "reminder", label: "reminder"),
      Sender.new(match: SCHEDULE_PREFIX, **unattended, wake: :schedule, origin: "schedule", label: "schedule"),
      Sender.new(match: PLUGIN, **unattended, wake: :plugin, source: "plugin_send", label: "plugin"),
      Sender.new(match: RELAY_PREFIX, **unattended),
      agent,
      session_question,
      participant,
      # compat shim review_client_id: the legacy review:<id> id uses the
      # participant sender row too.
      participant.with(match: LEGACY_REVIEW_PREFIX)
    ].freeze

    # No client id: reaches only a worker's own seams (an input file from
    # an older chi, a Bridge POST /turn naming none). A human's (it counts
    # for a delegate child's report and the session's metrics) but never
    # the owner's: every sender names itself (POST /command refuses none;
    # a POST /turn's /word line from none is prose).
    NONE = Sender.new(match: nil, human: true, owner: false, interactive: false, wake: :automatic, origin: "client",
                      source: nil, label: nil)
    # An id chi doesn't know: automatic input, never a human's.
    UNKNOWN = Sender.new(match: nil, **unattended)

    EXACT_ROWS = ROWS.reject(&:prefix?).to_h { |row| [row.match, row] }.freeze
    # Longest first: system:schedule: before system:.
    PREFIX_ROWS = ROWS.select(&:prefix?).sort_by { |row| -row.match.length }.freeze

    module_function

    # The row for +client_id+: the whole id first, then its longest prefix;
    # NONE for nil, UNKNOWN for an id chi doesn't know ("" too).
    # @return [Sender]
    def sender(client_id)
      return NONE if client_id.nil?

      id = client_id.to_s
      EXACT_ROWS[id] || PREFIX_ROWS.find { |row| id.start_with?(row.match) } || UNKNOWN
    end

    # What sent a turn: "delegate" (a delegating parent), "delegate_report"
    # (a child's report), "context" (a context wake), "peer" (a peer's
    # message, a mail wake), "task" (a task finish
    # wake), "participant", "reminder", "schedule" (a durable
    # schedule's firing), else "client" (the owner, chi send, a plugin, nil).
    # @return [String]
    def origin(client_id) = sender(client_id).origin

    # Whether +client_id+ is a web tab or a chi TUI, which see a command's
    # reply and can send the line it asks for (CacheConfirm); chi send, a
    # delegate, a plugin, chi itself and nil are not.
    def interactive?(client_id) = sender(client_id).interactive

    # Whether +client_id+ (a turn's or a line's origin) is a human's input.
    def human?(client_id) = sender(client_id).human

    # Whether +client_id+ is the owner's input: not a participant's, not
    # automatic, never nil.
    def owner?(client_id) = sender(client_id).owner

    # The WakePolicy row a turn delivery from +client_id+ reads (deliver_turn's
    # two liveness checks): :send for a person (a web tab, a chi TUI, chi
    # send), :schedule, :plugin, :delegate or :participant for those
    # senders, :automatic for anything else (nil too: deliver_turn refuses it
    # first). Only :send un-stops a stopped session or starts an archived one.
    # @return [Symbol]
    def wake_kind(client_id) = sender(client_id).wake

    # Whether +client_id+ is a parent agent's line (chi send's, chi answer's,
    # an agent's): the ids chi web's parent gates hold to
    # guardrails.parent_answers (Web::SessionCreate#parent_gate and its
    # callers).
    def parent_line?(client_id) = [CLI_SEND, CLI_ANSWER].include?(client_id.to_s) || agent?(client_id)

    # The name in a mail wake's id (peer:<name>), cleaned as a label reads
    # it ("?" when nothing is left); nil for another id.
    def peer_name(client_id)
      return nil unless sender(client_id).match == PEER_PREFIX

      name = client_id.to_s.delete_prefix(PEER_PREFIX).downcase.gsub(/[^a-z0-9]/, "")[0, 24]
      name.empty? ? "?" : name
    end

    # The client id an agent's message carries: agent:<name> (a name
    # AgentCaller.clean gave).
    def agent(name) = "#{AGENT_PREFIX}#{name}"

    # Whether +client_id+ is an agent's (agent:<name>); another session's
    # question (session:) is not one.
    def agent?(client_id) = sender(client_id).match == AGENT_PREFIX

    # The client id another session's question carries: session:<id8>.
    def session(session_id) = "#{SESSION_PREFIX}#{session_id.to_s[0, 8]}"

    # Whether +client_id+ is another session's question (session:<id8>).
    def session?(client_id) = sender(client_id).match == SESSION_PREFIX

    # The id8 in a session question's id, cleaned again as a header or a
    # label reads it ("?" when nothing is left); nil for another id.
    def session_name(client_id)
      return nil unless session?(client_id)

      name = client_id.to_s.delete_prefix(SESSION_PREFIX).gsub(/[^A-Za-z0-9_-]/, "")[0, 8]
      name.empty? ? "?" : name
    end

    # The name in an agent's id, cleaned again as a header or a label
    # reads it (a thin client's id comes as it typed it): "agent" when
    # nothing is left; nil for an id that isn't an agent's.
    def agent_name(client_id)
      return nil unless agent?(client_id)

      name = client_id.to_s.delete_prefix(AGENT_PREFIX).downcase.gsub(/[^a-z0-9_-]/, "")[0, AGENT_NAME_MAX]
      name.empty? ? "agent" : name
    end

    # The client id a participant's turn carries (chi web's, from their
    # grant): participant:<participant id>.
    def participant(participant_id) = "#{PARTICIPANT_PREFIX}#{participant_id}"

    # Whether +client_id+ is a participant's (participant:, or legacy
    # review:).
    def participant?(client_id) = sender(client_id).wake == :participant

    # compat shim review_client_id: translate participant:<id> for a worker
    # that still expects review:<id>.
    def legacy_participant(client_id)
      id = client_id.to_s
      id.start_with?(PARTICIPANT_PREFIX) ? "#{LEGACY_REVIEW_PREFIX}#{id.delete_prefix(PARTICIPANT_PREFIX)}" : client_id
    end

    # The client id a delegating parent's task and follow-ups carry:
    # delegate:<parent8>.
    def delegate(parent_id) = "#{DELEGATE_PREFIX}#{parent_id.to_s[0, 8]}"

    # The client id a durable schedule's turn carries: system:schedule:<id>.
    def schedule(schedule_id) = "#{SCHEDULE_PREFIX}#{schedule_id}"

    # Whether +client_id+ is a schedule's firing.
    def schedule?(client_id) = client_id.to_s.start_with?(SCHEDULE_PREFIX)
  end
end
