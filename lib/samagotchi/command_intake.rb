# frozen_string_literal: true

require_relative "client_id"

module Samagotchi
  # Who may send a session command as a message (a turn's text: chi send -m
  # "/model x", a web page's first message, an input file, a session's
  # first prompt), and what a line from anyone else is. The one rule the
  # two intakes ask (WorkerInbound#queue_as_command, Bridge#handle_post_turn)
  # and the senders that refuse up front (Tools::Delegate, Schedules#add).
  # No Engine needed: a schedule's tick and the CLI have none.
  #
  # From a sender that may not, a /word line is plain prompt text (the
  # model reads it) and a ! line (a shell command: SessionCommands#shell
  # runs it with no Gate) is refused with REFUSED, never run.
  module CommandIntake
    # A shell line's prefix: !<cmd>, and !rollback (SessionCommands::
    # SHELL_BANG_PREFIX, which a spec keeps the same: SessionCommands is too
    # big a load for the bundle test kit's budget).
    SHELL_PREFIX = "!"

    # The one text a refused shell line gets: the Bridge's 403 detail, the
    # worker's command_ran error, a delegate's or a schedule's refusal.
    REFUSED = "a message that starts with ! is a shell command, which only a person runs as a message " \
              "(a web tab, a chi TUI, chi send); from a delegate, a schedule or another automatic sender it is not run. " \
              "Say what to run in words instead (\"run `ls`\"), or leave out the leading !"

    # The Bridge's error code for it (403).
    REFUSED_ERROR = "command_not_permitted"

    # chi answer's marker: a parent agent's /continue yes and
    # /parent-answers (Worker#as_parent? holds it to its own rules).
    ALLOWED_IDS = [ClientId::CLI_ANSWER].freeze

    module_function

    # Whether a message from +client_id+ may run as a session command: a
    # human's input (ClientId.human?: a web tab, a chi TUI, chi send, no
    # client) but a participant's (review:, refused on its own), and chi
    # answer's. A delegate, a child's report, a context or task wake, a
    # schedule, a reminder, a relay and a plugin may not (the bundles that
    # send, coordinator and skills, send prose).
    def allowed?(client_id)
      ALLOWED_IDS.include?(client_id.to_s) || (ClientId.human?(client_id) && !ClientId.review?(client_id))
    end

    # Whether +text+ would be a shell line (!<cmd>, !rollback) if a command:
    # what a delegate's task or a schedule's prompt may not start with.
    def shell_line?(text) = text.to_s.lstrip.start_with?(SHELL_PREFIX)

    # Whether the command line +line+ from +client_id+ is a shell line that
    # must not run.
    def refused?(line, client_id) = shell_line?(line) && !allowed?(client_id)
  end
end
