# frozen_string_literal: true

require_relative "turn_flow"
require_relative "commands/registry"
require_relative "llm_context_command"
require_relative "thinking_command"
require_relative "toolkit_command"
require_relative "parent_answers_command"
require_relative "title_command"
require_relative "reasoning_history_command"
require_relative "working_set_command"
require_relative "recap_command"

module Samagotchi
  # The session commands' catalogue: their names, the registry of the
  # built-ins (SessionCommands' handlers, which #run instance_execs on a
  # SessionCommands, so the blocks name methods only the runner has) and
  # the class-level reads the UIs make of it (builtin_name, ui_only_entry,
  # delete_on_exit?…). No Engine, no tool: the attached TUI, chi web,
  # chi send and the prompt history require this file, not
  # session_commands (which loads tools/execute and tools/builtins for
  # !cmd and /context). SessionCommands includes it (its constants) and
  # forwards the class methods, so SessionCommands.x keeps working.
  module SessionCommandCatalog
    MODEL_COMMAND = "/model"
    MODELS_COMMAND = "/models"
    GUARDRAILS_COMMAND = "/guardrails"
    CONTEXT_COMMAND = "/context"
    HELP_COMMAND = "/help"
    LLM_CONTEXT_COMMAND = LLMContextCommand::NAME
    THINKING_COMMAND = ThinkingCommand::NAME
    TOOLKIT_COMMAND = ToolkitCommand::NAME
    PARENT_ANSWERS_COMMAND = ParentAnswersCommand::NAME
    TITLE_COMMAND = TitleCommand::NAME
    REASONING_HISTORY_COMMAND = ReasoningHistoryCommand::NAME
    WORKING_SET_COMMAND = WorkingSetCommand::NAME
    RECAP_COMMAND = RecapCommand::NAME
    # A literal: ObjectivesCommand loads on first use (SessionCommands autoloads it).
    OBJECTIVES_COMMAND = "/objectives"
    ROLLBACK_COMMAND = "!rollback"
    CONTINUE_COMMAND = TurnFlow::CONTINUE_COMMAND
    SHELL_BANG_PREFIX = "!"
    # /exit --delete: delete the session on the way out.
    EXIT_DELETE_FLAG = "--delete"

    # Puts the built-in commands into +registry+, in lookup order (!rollback
    # before !cmd): the ones #run runs, then the UIs' own (local: Tab and
    # help only).
    #
    # While a turn runs, a show form (the name alone) runs at once beside
    # it (it only reads); setting forms and !cmd run after the turn; !rollback
    # and /continue are refused (Commands::Registry::MID_TURN).
    def self.register_builtins(registry)
      registry.register(ROLLBACK_COMMAND, "discard the interrupted turn and restore the pre-turn state",
                        id: :rollback) { |_text| rollback }
      registry.register("!", "run a shell command; its output goes into the conversation",
                        id: :shell, mid_turn: :queue, match: ->(text) { text.match?(/\A!\s*\S/) }) { |text| shell(text) }
      # #run passes who sent it (as_parent:) per call.
      registry.register(CONTINUE_COMMAND, "answer the continue offer (yes, no or no, <reason>)") { |text| continue_command(text) }
      # It reads the hosts only (the registry is mutex-guarded): mid-turn too.
      registry.register(MODELS_COMMAND, "list the hosts' models (/models <text> filters)", anytime: true) do |text|
        reply(models_listing(text.delete_prefix(MODELS_COMMAND).strip))
      end
      registry.register(GUARDRAILS_COMMAND, "list guardrails, revoke an approval or flag a System 1 auto-allow",
                        mid_turn: show_mid_turn(GUARDRAILS_COMMAND)) do |text|
        guardrails(text.delete_prefix(GUARDRAILS_COMMAND).strip)
      end
      # The list only reads the store; attach and decline only write it (the
      # note waits for the next between-turn delivery): mid-turn too.
      registry.register(CONTEXT_COMMAND, "list the attached context and its candidates (chi context); attach NAME, " \
                                         "decline NAME: a candidate", anytime: true,
                                                                     match: ->(text) { text.match?(%r{\A/context(?:\s+.*)?\z}i) }) do |text|
        context_command(text.strip.sub(%r{\A/context}i, "").strip)
      end
      registry.register(MODEL_COMMAND, "show or switch the model", mid_turn: show_mid_turn(MODEL_COMMAND),
                        match: ->(text) { text.match?(%r{\A/model(?:\s+.*)?\z}) }) { |text| model(text) }
      # Setting it saves the session; it takes effect at the next turn's start.
      registry.register(LLM_CONTEXT_COMMAND, "show or set this session's LLM context strategy, apply rule and budget",
                        id: :llm_context, mid_turn: show_mid_turn(LLM_CONTEXT_COMMAND), match: ->(text) { text.match?(%r{\A/llm-context(?:\s+.*)?\z}) }) { |text| llm_context(text) }
      registry.register(THINKING_COMMAND, "show or set this session's thinking level (off|low|medium|high|default)",
                        id: :thinking, mid_turn: show_mid_turn(THINKING_COMMAND), match: ->(text) { text.match?(%r{\A/thinking(?:\s+.*)?\z}) }) { |text| thinking(text) }
      registry.register(REASONING_HISTORY_COMMAND, "show or set which of its reasoning this session's model gets back (drop|turn|all|default)",
                        id: :reasoning_history, mid_turn: show_mid_turn(REASONING_HISTORY_COMMAND),
                        match: ->(text) { text.match?(%r{\A/reasoning-history(?:\s+.*)?\z}) }) { |text| reasoning_history(text) }
      registry.register(TOOLKIT_COMMAND, "show or change the tools this session declares (NAME, add TOOL, remove TOOL)",
                        id: :toolkit, mid_turn: show_mid_turn(TOOLKIT_COMMAND),
                        match: ->(text) { text.match?(%r{\A/toolkit(?:\s+.*)?\z}) }) { |text| toolkit(text) }
      # The list reads only: mid-turn too; an op waits for the turn's end
      # (the next turn's first request is the first with it).
      registry.register(WORKING_SET_COMMAND, "list the working set; drop, undrop, pin or unpin an item (drop KEY…)",
                        id: :working_set, mid_turn: show_mid_turn(WORKING_SET_COMMAND),
                        match: ->(text) { text.match?(%r{\A/working-set(?:\s+.*)?\z}) }) { |text| working_set(text) }
      # Tighten-only from anyone; loosening is a user's at a UI (#run's user_ui:).
      registry.register(PARENT_ANSWERS_COMMAND, "show or set what a parent agent may answer here (hard|standard|soft|default; " \
                                                "never looser than config.yml's)",
                        id: :parent_answers, mid_turn: show_mid_turn(PARENT_ANSWERS_COMMAND),
                        match: ->(text) { text.match?(%r{\A/parent-answers(?:\s+.*)?\z}) }) { |text| parent_answers(text) }
      # Only a name: renaming a running session doesn't wait for its turn.
      registry.register(TITLE_COMMAND, "show or set this session's title (--clear: back to its first message)",
                        id: :title, anytime: true, match: ->(text) { text.match?(%r{\A/title(?:\s+.*)?\z}) }) { |text| title(text) }
      # An edit only writes a note file (it goes in between turns): mid-turn too.
      registry.register(OBJECTIVES_COMMAND, "show or edit what this session is to achieve (set A | B, add TEXT, edit ID TEXT, done ID…, drop ID…, undo ID…, check ID, track)",
                        id: :objectives, anytime: true) { |text| objectives(text) }
      registry.register(HELP_COMMAND, "list the commands, the bundles' too", anytime: true) { |_text| reply(help_listing) }
      registry.register("/stats", "show the session's stats", local: true)
      # /recap with words (on|off|default, or a slip: the usage) runs here:
      # it toggles the idle job only, so it doesn't wait for a running turn.
      # The bare /recap shows the recap: the UIs' own, under the same name
      # (Registry#register); /help lists the name once, with this entry's
      # description.
      registry.register(RECAP_COMMAND, "show the session's recap (in a terminal); on|off|default sets this session's own",
                        id: :recap_setting, anytime: true, match: ->(text) { text.match?(%r{\A/recap\s+\S}) }) { |text| recap_setting(text) }
      registry.register(RECAP_COMMAND, "show the session's recap", local: true, match: ->(text) { text == RECAP_COMMAND })
      # Bare `exit` too; any case; --delete after it.
      registry.register("/exit", "leave (--delete also deletes the session)", local: true,
                                                                              match: exit_match("/?exit"))
      registry.register("/quit", "leave, like /exit", id: :exit, local: true, match: exit_match("/quit"))
      registry.register("/archive", "leave and archive the session: hidden from the lists, kept for good", local: true,
                                                                                                          match: ->(text) { text.casecmp?("/archive") })
      # The terminal's: the web has no worker to leave running.
      registry.register("/detach", "leave and keep the worker running", local: true, uis: [:attached],
                                                                        match: ->(text) { text.casecmp?("/detach") })
      # /cut TEXT and /queue TEXT while a turn runs: a delivery the UIs parse
      # themselves (ComposerRoute.steer_choice) before any command check; the
      # entries exist for Tab completion and /help. The web composer sends
      # /cut too (its queue is Alt+Enter). The attached TUI queues in its
      # worker's input files.
      registry.register("/cut", "cut the running generation and go in now (/cut TEXT)",
                        local: true, uis: %i[attached web], match: ->(text) { text.casecmp?("/cut") || text.match?(%r{\A/cut\s+\S}) })
      registry.register("/queue", "run as the next turn after this one (/queue TEXT)",
                        local: true, uis: [:attached], match: ->(text) { text.casecmp?("/queue") || text.match?(%r{\A/queue\s+\S}) })
      # Takes back the newest message this attached TUI queued, before it
      # runs (the worker's POST turn/dequeue); the web has × on the bubble.
      registry.register("/unqueue", "remove your newest queued message before it runs", local: true, uis: [:attached],
                                                                                          match: ->(text) { text.casecmp?("/unqueue") })
      # chi share for the attached session (TerminalUI::ParticipantCommands):
      # a participant's turns run on its worker.
      registry.register("/share", "invite someone into this session (/share NAME [--expires 3d] [--cap 2])",
                        local: true, uis: [:attached], match: ->(text) { text.match?(%r{\A/share(?:\s.*)?\z}i) })
      registry.register("/participants", "list this session's participants (revoke [P], cap P DOLLARS)",
                        local: true, uis: [:attached], match: ->(text) { text.match?(%r{\A/participants(?:\s.*)?\z}i) })
      registry
    end

    # @return [#call] line → :anytime for +name+ alone (it shows), else
    #   :queue (it sets what the next turn runs under)
    def self.show_mid_turn(name)
      ->(text) { text == name ? :anytime : :queue }
    end
    private_class_method :show_mid_turn

    # @param word [String] the regexp source of the exit word
    def self.exit_match(word)
      pattern = /\A#{word}(?:\s+#{EXIT_DELETE_FLAG})?\z/i
      ->(text) { text.match?(pattern) }
    end
    private_class_method :exit_match

    # @return [Boolean] an exit line (/exit, /quit, exit) that deletes the session too
    def self.delete_on_exit?(line) = line.to_s.split.last.to_s.casecmp?(EXIT_DELETE_FLAG)

    # The built-ins alone, for callers without an Engine (an attached TUI
    # before its snapshot names the session's commands, specs).
    # @return [Commands::Registry] frozen
    def self.builtin_registry
      @builtin_registry ||= register_builtins(Commands::Registry.new).freeze
    end

    # The UI-only built-in command +text+ is a line of (/stats, /exit, …), or
    # nil: neither a worker nor a one-shot run (chi send, chi -p
    # --non-interactive) runs it, so they refuse it rather than send it to
    # the model as a prompt. What the UIs run: the line as the entry's match
    # takes it — bare "exit" too (/exit's match), but not with arguments
    # ("/exit --delete" is a UI line; "/stats please" is a prompt), as in a
    # terminal.
    # @return [Commands::Registry::Entry, nil]
    def self.ui_only_entry(text)
      line = text.to_s.strip
      return nil unless line.start_with?("/", "!") || line.match?(/\Aexit\z/i)

      entry = builtin_registry.lookup_local(line)
      return nil unless entry
      return entry if line == entry.name

      line.match?(/\Aexit\z/i) ? entry : nil
    end

    # Why a UI-only command isn't run by +runner+ ("chi send"): /stats points
    # at its model-free reader (naming the session +id+ when there is one),
    # which reads the session's machine: under chi --remote NAME (+remote+)
    # it runs there.
    # @return [String]
    def self.ui_only_refusal(name, id, runner:, remote: nil)
      return "#{name} is a terminal and web command; #{runner} doesn't run it" unless name == "/stats"

      "#{name} is a terminal and web command; use chi sessions stats #{id ? id[0, 8] : "ID"}#{" on #{remote}" if remote}"
    end

    # The name of this chi's own session command +line+ is (one a worker
    # runs), or nil. A worker that answers such a line unknown_command runs
    # an older chi that doesn't have it yet (/llm-context against 0.39.0):
    # the UIs say so (BridgeClient.stale_worker_message) instead of "not a
    # session command".
    # @return [String, nil]
    def self.builtin_name(line) = builtin_registry.lookup(line)&.name

    # How help and errors name an entry (the shell's "!" is "!<cmd>").
    def self.display_name(entry) = entry.name == SHELL_BANG_PREFIX ? "#{SHELL_BANG_PREFIX}<cmd>" : entry.name
  end
end
