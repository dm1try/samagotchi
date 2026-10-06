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
    # chi answer's answers (a parent agent's, Guardrails::ParentApprovals).
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
    # chi's own turns; system:reminder, the turn queued when reminders are due.
    SYSTEM_PREFIX = "system:"
    REMINDER = "system:reminder"
    # A plugin's message (Plugin::Sessions#send).
    PLUGIN = "plugin"
    # A relayed answer (RelayVerifier): relay:<parent8>.
    RELAY_PREFIX = "relay:"

    # Input a human typed: a web tab, a chi TUI, chi send, and nil (a
    # worker's initial prompt; a web client may send none). An allowlist:
    # delegates, plugins, reminders, context changes and any id chi doesn't
    # know are not.
    HUMAN_PREFIXES = [WEB_PREFIX, TUI_PREFIX].freeze
    HUMAN_IDS = [CLI_SEND].freeze

    module_function

    # Whether +client_id+ (a turn's or a line's origin) is a human's input.
    def human?(client_id)
      return true if client_id.nil?

      id = client_id.to_s
      HUMAN_IDS.include?(id) || HUMAN_PREFIXES.any? { |prefix| id.start_with?(prefix) }
    end
  end
end
