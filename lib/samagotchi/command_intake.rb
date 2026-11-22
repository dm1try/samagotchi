# frozen_string_literal: true

require_relative "client_id"

module Samagotchi
  # Who may send a session command as a message (a turn's text: chi send -m
  # "/model x", a web page's first message, an input file, a session's
  # first prompt), and what a line from anyone else is. The one rule the
  # three intakes ask (WorkerInbound#queue_as_command, Bridge#handle_post_turn,
  # the Bridge's POST /command: #refused? before #allowed?) and the senders
  # that refuse up front (Tools::Delegate, Schedules#add).
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
              "(a web tab, a chi TUI, chi send); from an agent, a delegate, a schedule or another automatic sender " \
              "it is not run. " \
              "Say what to run in words instead (\"run `ls`\"), or leave out the leading !"

    # The Bridge's error code for it (403), and for COMMAND_REFUSED.
    REFUSED_ERROR = "command_not_permitted"

    # The one text a session command line gets on the Bridge's explicit
    # command route (POST /command) from a sender that may not send one
    # (#allowed?): a participant, a delegate, a plugin, an id chi doesn't
    # know. Its shell lines get REFUSED.
    COMMAND_REFUSED = "a session command runs only when you send it (a web tab, a chi TUI, chi send), an agent sends it " \
                      "or chi answer does; " \
                      "from a participant, a delegate, a plugin or another automatic sender it is not run"

    # chi answer's marker (a parent agent's /continue yes and
    # /parent-answers; Worker#as_parent? holds those to its own rules): any
    # command, with chi send's trust.
    ALLOWED_IDS = [ClientId::CLI_ANSWER].freeze

    # The Bridge's answer to a /turn line whose command hides its arguments
    # (/callback's one-time code) that can't run as a command (with images,
    # from a sender above): refused, never a message for the model.
    PRIVATE_REFUSED = [{ "Allow" => "POST" }, 400,
                       { error: "private_command",
                         detail: "/callback runs only as a command: send it alone, without images" }].freeze

    module_function

    # Whether a message from +client_id+ may run as a session command: the
    # owner's input (ClientId.owner?: a web tab, a chi TUI, chi send, a
    # worker's own first prompt, a person's card answer) and chi answer's.
    # No client id is no one's: refused (every sender names itself). A
    # participant (participant:) is refused on its own.
    # A delegate, a child's report, a context or task wake, a schedule, a
    # reminder, a relay and a plugin may not (the bundles that send,
    # coordinator and skills, send prose). An agent (agent:<name>) may, as
    # chi send's could: but never a ! line (#refused?).
    def allowed?(client_id)
      ALLOWED_IDS.include?(client_id.to_s) || ClientId.owner?(client_id) || ClientId.agent?(client_id)
    end

    # Whether a ! line from +client_id+ may run: a sender #allowed? but an
    # agent's (chi answer keeps its rights).
    def shell_allowed?(client_id) = allowed?(client_id) && !ClientId.agent?(client_id)

    # Whether +text+ would be a shell line (!<cmd>, !rollback) if a command:
    # what a delegate's task or a schedule's prompt may not start with.
    def shell_line?(text) = text.to_s.lstrip.start_with?(SHELL_PREFIX)

    # Whether the command line +line+ from +client_id+ is a shell line that
    # must not run: asked before #allowed? at each intake.
    def refused?(line, client_id) = shell_line?(line) && !shell_allowed?(client_id)

    # The refusal text for +line+ from a sender that may not send commands.
    def refusal(line) = shell_line?(line) ? REFUSED : COMMAND_REFUSED
  end
end
