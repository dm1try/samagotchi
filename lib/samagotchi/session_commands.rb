# frozen_string_literal: true

require_relative "config"
require_relative "model_profile"
require_relative "served_model"
require_relative "prompt_note"
require_relative "turn_flow"
require_relative "cache_confirm"
require_relative "tools/execute"
require_relative "tools/builtins"
require_relative "tools/context_read"
require_relative "tools/peers"
require_relative "commands/registry"
require_relative "llm_context_command"
require_relative "thinking_command"
require_relative "toolkit_command"
require_relative "parent_answers_command"
require_relative "title_command"
require_relative "reasoning_history_command"
require_relative "working_set_command"
require_relative "recap_command"
require_relative "guardrails/parent_policy"
require_relative "system_one/log"
require_relative "system_one/record"

module Samagotchi
  # The session commands a REPL and a session worker both run: /model,
  # /models, /llm-context, /guardrails, /context, !rollback, !cmd and the answer to a continue offer. They act on
  # the Engine and its TurnFlow; the host prints the result's output and
  # runs a continue turn when asked to (#run never runs a turn).
  #
  # /stats, /recap, /exit, /quit, /archive and /detach are the terminal
  # UIs' own: they are in the registry (local:) for Tab and help, and so
  # both TUIs read the same words (Registry#lookup_local gives the entry,
  # its id says what to do), but #run never runs them.
  class SessionCommands
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
    # A remote catalog has hundreds of ids (OpenRouter ~380): plain /models
    # shows this many per host; /models <text> lists every match.
    MODELS_PER_HOST = 20
    ROLLBACK_COMMAND = "!rollback"
    CONTINUE_COMMAND = TurnFlow::CONTINUE_COMMAND
    SHELL_BANG_PREFIX = "!"
    ALIAS_USAGE = "usage /model <model> --alias <name> [--default]"
    # /exit --delete: delete the session on the way out.
    EXIT_DELETE_FLAG = "--delete"

    # /help's note per listed mid_turn (the web's command list says the same).
    MID_TURN_NOTES = { "anytime" => "mid-turn too", "depends" => "show: mid-turn too" }.freeze

    # Commands that may ask before a change that restarts the prompt cache
    # (CacheConfirm): #run passes them its confirm flag.
    CONFIRMING = %i[model llm_context thinking reasoning_history toolkit].freeze

    # @!attribute status [Symbol] :ok, or :error when the line was refused
    # @!attribute output [String, nil] what to tell the user
    # @!attribute changed [Array<Symbol>] :messages and/or :model
    # @!attribute model_name [String] the Engine's model after the command
    # @!attribute resume [Boolean] the host must now run the continue turn
    # @!attribute shell [Boolean] output is a !cmd's own output
    # @!attribute decision [Symbol, nil] an answer to the continue offer:
    #   :resume, :abort, :abort_with_reason or :invalid
    # @!attribute confirm [CacheConfirm::Confirm, nil] a costly change asks
    #   first (nothing changed): the line that applies it
    Result = Struct.new(:status, :output, :changed, :model_name, :resume, :shell, :decision, :confirm, keyword_init: true)

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
      # It only reads the store: mid-turn too.
      registry.register(CONTEXT_COMMAND, "list the attached context (chi context)", anytime: true,
                                                                                   match: ->(text) { text.casecmp?(CONTEXT_COMMAND) }) do |_text|
        reply(context_listing)
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
      # The REPL owns its session: it answers /detach with a note, and doesn't offer it.
      registry.register("/detach", "leave and keep the worker running", local: true, uis: [:attached],
                                                                        match: ->(text) { text.casecmp?("/detach") })
      # /cut TEXT and /queue TEXT while a turn runs: a delivery the UIs parse
      # themselves (ComposerRoute.steer_choice) before any command check; the
      # entries exist for Tab completion and /help. The web composer sends
      # /cut too (its queue is Alt+Enter). Both terminals queue: the REPL in
      # its own list, the attached TUI's worker in its input files.
      registry.register("/cut", "cut the running generation and go in now (/cut TEXT)",
                        local: true, uis: %i[repl attached web], match: ->(text) { text.casecmp?("/cut") || text.match?(%r{\A/cut\s+\S}) })
      registry.register("/queue", "run as the next turn after this one (/queue TEXT)",
                        local: true, uis: %i[repl attached], match: ->(text) { text.casecmp?("/queue") || text.match?(%r{\A/queue\s+\S}) })
      # Takes back the newest message this attached TUI queued, before it
      # runs (the worker's POST turn/dequeue); the web has × on the bubble.
      registry.register("/unqueue", "remove your newest queued message before it runs", local: true, uis: [:attached],
                                                                                          match: ->(text) { text.casecmp?("/unqueue") })
      # chi share for the attached session (TerminalUI::ParticipantCommands):
      # a participant's turns run on its worker, so the REPL points there.
      registry.register("/share", "invite someone to review this session (/share NAME [--agent] [--expires 3d] [--cap 2])",
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

    # @return [String, nil] the model /model clear goes back to; nil when none
    attr_reader :default_model

    # @param default_model [String, nil] the config default, which /model clear
    #   restores and /model names (the Engine may have started elsewhere, e.g.
    #   on a resumed session's model); nil when the config names no default
    # @param save [#call] saves a session (a worker passes its state dir)
    # @param registry [Commands::Registry] the commands #run looks lines up in
    def initialize(engine:, turn_flow:, default_model:, save: ->(session) { session.save },
                   registry: self.class.builtin_registry)
      @engine = engine
      @turn_flow = turn_flow
      @default_model = default_model
      @save = save
      @registry = registry
    end

    # @return [Commands::Registry]
    attr_reader :registry

    # /help: every command in the registry, the UIs' own and the bundles'
    # too: the session's commands first, then the bundles', then the UIs'
    # own (marked by UI), each group by name.
    # @return [String]
    def help_listing
      # A name with a UI's entry and the session's (/recap): listed once,
      # as the session's (registered first).
      entries = @registry.entries.uniq(&:name).sort_by { |entry| [help_group(entry), entry.name] }
      width = entries.map { |entry| self.class.display_name(entry).length }.max
      lines = entries.map do |entry|
        notes = []
        notes << entry.source unless entry.source == "core"
        notes << MID_TURN_NOTES[entry.mid_turn_label] if MID_TURN_NOTES[entry.mid_turn_label]
        notes << "#{ui_words(entry.uis)} only" if entry.local
        line = "  #{self.class.display_name(entry).ljust(width)}  #{entry.description}"
        notes.empty? ? line : "#{line}  (#{notes.join("; ")})"
      end
      "commands:\n#{lines.join("\n")}"
    end

    # Where a UI's own entry runs, for /help: both terminals are
    # "terminal" (also for no uis: every terminal), then "web".
    # @param uis [Array<Symbol>, nil]
    # @return [String] "terminal", "repl", "terminal and web" …
    def ui_words(uis)
      return "terminal" if uis.nil?

      terminals = uis & %i[repl attached]
      words = terminals.size == 2 ? ["terminal"] : terminals.map(&:to_s)
      words << "web" if uis.include?(:web)
      words.join(" and ")
    end

    # How help and errors name an entry (the shell's "!" is "!<cmd>").
    def self.display_name(entry) = entry.name == SHELL_BANG_PREFIX ? "#{SHELL_BANG_PREFIX}<cmd>" : entry.name

    # @param confirm [Boolean] a costly setting change asks first
    #   (CacheConfirm): true for a person at a web tab or
    #   a TUI; false applies it at once (chi send, a delegate, a plugin,
    #   chi -p)
    # @param as_parent [Boolean] a parent agent sent it (client cli:answer):
    #   a /continue yes is held to guardrails.parent_answers, as chi
    #   answer --option Continue is (Guardrails::ParentPolicy)
    # @param user_ui [Boolean] a user at a UI sent it (the REPL, an attached
    #   TUI, the web; not a piped or marked one): only such a line loosens
    #   /parent-answers
    # @return [Result, nil] nil when +line+ is not one of these commands
    def run(line, confirm: true, as_parent: false, user_ui: false)
      text = line.to_s.strip
      entry = @registry.lookup(text)
      return nil unless entry&.handler
      return run_bundle_command(entry, text, confirm: confirm) unless entry.source == "core"

      # Only commands that may ask take the flag.
      return send(entry.id, text, confirm: confirm) if CONFIRMING.include?(entry.id)
      # Who sent it goes to its handler per call, never through an ivar:
      # an anytime command runs on another thread against this instance.
      return continue_command(text, as_parent: as_parent) if entry.id == :continue
      return parent_answers(text, user_ui: user_ui) if entry.id == :parent_answers

      instance_exec(text, &entry.handler)
    end

    # /continue [yes|no|no, <reason>]: the continue offer's answer.
    def continue_command(text, as_parent: false)
      return reply("nothing to continue") unless @turn_flow.awaiting_continue?

      answer = text.delete_prefix(CONTINUE_COMMAND).strip
      continue_answer(answer.empty? ? CONTINUE_COMMAND : answer, as_parent: as_parent)
    end

    # Answer the pending continue offer (yes / no / no, <reason>).
    # @param as_parent [Boolean] a parent agent's answer: a yes its strategy
    #   doesn't allow is refused (the offer stays; decision :invalid)
    # @return [Result] resume: true on yes
    def continue_answer(text, as_parent: false)
      decision, reason = TurnFlow.continue_decision(text)
      if decision == :resume && as_parent &&
         (refusal = Guardrails::ParentPolicy.continue_refusal(strategy: Guardrails::ParentPolicy.for_session(@engine.session)))
        return reply(refusal, status: :error).tap { |result| result.decision = :invalid }
      end

      result = case decision
               when :resume then Result.new(status: :ok, changed: [], model_name: model_name, resume: true, shell: false)
               when :abort
                 @turn_flow.abort_continue!
                 save_session
                 reply("turn not continued; its work so far stays (!rollback erases it)", changed: [:messages])
               when :abort_with_reason
                 @turn_flow.abort_continue!(reason: reason)
                 save_session
                 reply("turn not continued; noted your reason", changed: [:messages])
               else
                 reply("answer yes, no, or no, <reason>", status: :error)
               end
      result.decision = decision
      result
    end

    private

    # The resolved ref (what the session stores and --alias/--default write).
    def model_name = @engine.effective_model_ref

    # A bundle plugin's command: its handler gets the text after the name
    # (--yes kept); what it returns is the output (nil: nothing to show),
    # or [output, CacheConfirm::Confirm or nil] for a change that asks
    # first (ctx.cache_confirm), and a raise is an error result. The
    # sender's +confirm+ (false once the line has --yes) reaches
    # ctx.cache_confirm through the thread (CacheConfirm.asking).
    def run_bundle_command(entry, text, confirm: false)
      args = text.delete_prefix(entry.name).strip
      _, yes = CacheConfirm.split(args)
      output, ask = bundle_reply(CacheConfirm.asking(confirm && !yes) { entry.handler.call(args) })
      reply(output, confirm: ask)
    rescue StandardError => e
      reply("#{entry.name}: #{e.class}: #{e.message}", status: :error)
    end

    # A plugin command's return value as [output, confirm]: a String (or
    # anything, shown as text) or nil, or [text, Confirm/nil].
    def bundle_reply(value)
      if value.is_a?(Array) && value.size == 2 && (value[1].nil? || value[1].is_a?(CacheConfirm::Confirm))
        text, ask = value
        return [text.nil? ? nil : text.to_s, ask]
      end

      [value.nil? ? nil : value.to_s, nil]
    end

    def help_group(entry)
      return 2 if entry.local

      entry.source == "core" ? 0 : 1
    end

    def reply(output, status: :ok, changed: [], confirm: nil)
      Result.new(status: status, output: output, changed: changed, model_name: model_name, resume: false, shell: false,
                 confirm: confirm)
    end

    # Explicit escape hatch after a Ctrl-C: discard the salvaged partial
    # turn and restore the pre-turn checkpoint.
    def rollback
      offered = @turn_flow.awaiting_continue?
      return reply("nothing to rollback") unless @turn_flow.rollback!

      save_session
      result = reply("salvaged turn discarded; restored pre-turn state", changed: [:messages])
      # It discarded the turn a continue was offered for: that offer's no.
      result.decision = :abort if offered
      result
    end

    # The output goes into the conversation for the next turn. Not saved
    # here (as in the REPL, the next turn saves it). No parent-session
    # marker: the user runs this, not the model. A worker's `chi --model X`
    # default is unset, though: it was that run's, not the default of a chi
    # run here (Tools::Builtins.cli_model_unset).
    def shell(text)
      command = text.delete_prefix(SHELL_BANG_PREFIX).strip
      return reply("!: please provide a shell command after '!'", status: :error) if command.empty?

      # Killed at the limit, never handed over: the output goes in a user
      # message, which no one reads a task id from (created_ids_in).
      output = Samagotchi::Tools::Execute.call(command, env: Samagotchi::Tools::Builtins.cli_model_unset, on_timeout: :kill)
      @engine.append_messages([{ role: "user", content: "!(#{command})\n#{output}" }])
      # Rolling back past this would silently drop the command output.
      @turn_flow.note_conversation_changed
      Result.new(status: :ok, output: output, changed: [:messages], model_name: model_name, resume: false, shell: true)
    end

    # /guardrails: the rules (by source), what failed to load, the stored
    # approvals, numbered; /guardrails revoke N removes approval N.
    # /context: what context_read without a name gives the model.
    def context_listing
      session = @engine.session
      return "no session yet" unless session

      peers = Tools::Peers.new(session_id: session.id, cwd: session.working_directory, state_dir: @engine.peer_state_dir)
      Tools::ContextRead.call("", peers: peers)
    end

    def guardrails(args)
      return guardrails_revoke(args.delete_prefix("revoke").strip) if args.start_with?("revoke")
      return guardrails_wrong(args.sub(/\Awrong\b/, "").strip) if args.match?(/\Awrong(?:\s|\z)/)
      return reply("usage: /guardrails [revoke N | wrong [N]]", status: :error) unless args.empty?

      reply(guardrails_listing)
    end

    def guardrails_wrong(arg)
      unless arg.empty? || arg.match?(/\A[1-9]\d*\z/)
        return reply("usage: /guardrails wrong [N] (N from /guardrails)", status: :error)
      end

      index = arg.empty? ? 1 : arg.to_i
      entry = system_one_auto_allows[index - 1]
      return reply("no unlabelled System 1 auto-allows in this session (see /guardrails)") unless entry
      unless system_one_log.label(entry["id"], "should_have_asked")
        return reply("could not label System 1 auto-allow #{index} (see the guardrails log)", status: :error)
      end

      call = shorten_call(entry["call"].to_s.gsub(/\s+/, " "))
      probability = entry["p"].nil? ? "unknown" : format("%.2f", entry["p"].to_f)
      reply("labelled auto-allow #{index}: #{entry["rule"]}: #{call} (p=#{probability}); " \
            "the rule will ask again until its record is rebuilt")
    end

    def system_one_log
      SystemOne::Log.new(dir: File.dirname(@engine.guardrail_approvals.path))
    end

    def system_one_auto_allows(entries = system_one_entries)
      session_id = @engine.session&.id
      return [] unless session_id

      entries.select do |entry|
        entry["session_id"] == session_id && entry["decision"] == "auto" && entry["answer"].nil?
      end.last(20).reverse
    end

    def system_one_entries
      log = system_one_log
      File.file?(log.path) ? log.entries : []
    end

    def system_one_listing(lines)
      entries = system_one_entries
      mode = Config.get("guardrails.system_one.mode").to_s
      return if mode == "off" && entries.empty?

      lines << "System 1 (#{mode}):"
      auto_allows = system_one_auto_allows(entries)
      lines << "  auto-allows (this session, newest first; /guardrails wrong N):"
      if auto_allows.empty?
        lines << "    (none)"
      else
        auto_allows.each_with_index do |entry, index|
          call = shorten_call(entry["call"].to_s.gsub(/\s+/, " "))
          probability = entry["p"].nil? ? "unknown" : format("%.2f", entry["p"].to_f)
          lines << "    #{index + 1}. #{entry["rule"]}: #{call} (p=#{probability})"
        end
      end

      rules = entries.filter_map { |entry| entry["rule"] }.uniq.sort
      lines << "  records:"
      if rules.empty?
        lines << "    (none)"
      else
        rules.each do |rule|
          summary = SystemOne::Record.new(entries, rule: rule).summary
          counts = summary.reject { |key, _| key == :rule }.map { |key, value| "#{key}=#{value}" }.join(", ")
          lines << "    #{rule}: #{counts}"
        end
      end
    end

    CALL_SHOWN = 100

    def shorten_call(call)
      call.length > CALL_SHOWN ? "#{call[0, CALL_SHOWN - 1]}…" : call
    end

    def guardrails_listing
      rules = @engine.guardrail_rules
      approvals = @engine.guardrail_approvals.entries
      lines = ["guardrails: #{rules.enabled? ? "on" : "off (guardrails.enabled: false; denies still apply)"}"]
      lines << if rules.mode == "strict" then "mode: strict (every rule votes)"
               else "mode: auto (rules marked strict only don't vote; guardrails.mode: strict in config.yml for those)"
               end
      name = @engine.guardrail_model_name
      key = @engine.model_key
      lines << "model: #{name || "none"} — #{Guardrails::ModelSize.describe(name, key)}"
      failures = @engine.guardrail_failures.list
      unless failures.empty?
        lines << "failed to load:"
        failures.each do |f|
          lines << "  #{f.what}: #{f.reason}#{" (required: every tool call is denied)" if f.required}"
        end
      end
      disabled = rules.rules.count { |rule| rules.disabled?(rule) }
      lines << "rules (#{rules.rules.size}#{", #{disabled} disabled" if disabled.positive?}):"
      lines << "  (none; add them under guardrails.rules in config.yml, or install a bundle that ships them)" if rules.rules.empty?
      rules.rules.each_with_index do |rule, idx|
        match = [
          ("tool #{rule.tools.join(",")}" if rule.tools),
          ("command /#{shorten_pattern(rule.command.source)}/" if rule.command),
          ("path #{rule.path}" if rule.path),
          ("git #{rule.git}" if rule.git),
          ("touches #{rule.touches}" if rule.touches),
          ("rm #{rule.rm}" if rule.rm),
          ("memory #{rule.memory}" if rule.memory),
          ("models #{rule.models.join(",")}" if rule.models),
          ("modes #{rule.modes.join(",")}" if rule.modes),
          ("skip_read_only" if rule.skip_read_only)
        ].compact.join(", ")
        off = "disabled (guardrails.disable) — " if rules.disabled?(rule)
        off ||= "(#{rule.modes.join(", ")} only) — " unless rule.for_mode?(rules.mode)
        off ||= "off for this model — " unless rule.for_model?(name, key)
        lines << "  #{idx + 1}. #{rule.id}: #{off}#{rule.verdict} (#{match}) — #{rule.reason} [#{rule.source}]"
      end
      rules.unmatched_disables.each { |entry| lines << "  guardrails.disable: #{entry} matches no rule" }
      lines << "  core: deny writes to the approval store and installed bundles; ask before editing config.yml or the hooks dir"
      lines << "approvals (#{approvals.size}):"
      lines << "  (none)" if approvals.empty?
      approvals.each_with_index { |entry, idx| lines << "  #{idx + 1}. #{approval_line(entry)}" }
      lines << "revoke one with /guardrails revoke N" unless approvals.empty?
      system_one_listing(lines)
      lines.join("\n")
    end

    PATTERN_SHOWN = 80

    # A regex source cut to PATTERN_SHOWN characters, the last one "…".
    def shorten_pattern(source)
      source.length > PATTERN_SHOWN ? "#{source[0, PATTERN_SHOWN - 1]}…" : source
    end

    def approval_line(entry)
      what = entry["key"] ? entry["key"].tr("\n", " ") : "any call rule #{entry["rule"]} asks about"
      where = if entry["scope"] == "session" then "session #{entry["session_id"].to_s[0, 8]}"
              elsif entry["repo"] then "in repo #{entry["repo"]}"
              else "in #{entry["repo_root"]}"
              end
      rule = entry["rule"] ? " (rule #{entry["rule"]}, #{entry["source"]})" : ""
      "#{entry["scope"]}: #{what} — #{where}#{rule}, #{entry["created_at"]}"
    end

    def guardrails_revoke(arg)
      return reply("usage: /guardrails revoke N (N from /guardrails)", status: :error) unless arg.match?(/\A\d+\z/)

      removed = @engine.guardrail_approvals.revoke(arg.to_i - 1)
      return reply("no approval #{arg} (see /guardrails)", status: :error) unless removed

      reply("revoked approval #{arg}: #{approval_line(removed)}")
    end

    def save_session
      session = @engine.session
      return unless session

      @engine.store_model!(session)
      @save.call(session)
    end

    # /llm-context (LLMContextCommand); :llm_context in changed when it set
    # the session's values.
    def llm_context(text, confirm: true)
      output, changed, ask = LLMContextCommand.new(engine: @engine, save: ->(session) { save_setup(session) })
                                              .run(text.delete_prefix(LLM_CONTEXT_COMMAND), confirm: confirm)
      # What the model has of each item is the next turn's strategy's: the
      # working set goes out again (sent only when it differs).
      @engine.announce_working_set if changed
      reply(output, changed: changed ? [:llm_context] : [], confirm: ask)
    rescue ArgumentError => e
      reply(e.message, status: :error)
    end

    # /thinking (ThinkingCommand); :thinking in changed when it set the
    # session's level.
    def thinking(text, confirm: true)
      output, changed, ask = ThinkingCommand.new(engine: @engine, save: ->(session) { save_setup(session) })
                                            .run(text.delete_prefix(THINKING_COMMAND), confirm: confirm)
      reply(output, changed: changed ? [:thinking] : [], confirm: ask)
    rescue ArgumentError => e
      reply(e.message, status: :error)
    end

    # /reasoning-history (ReasoningHistoryCommand); :reasoning_history in
    # changed when it set the session's level.
    def reasoning_history(text, confirm: true)
      output, changed, ask = ReasoningHistoryCommand.new(engine: @engine, save: ->(session) { save_setup(session) })
                                                    .run(text.delete_prefix(REASONING_HISTORY_COMMAND),
                                                         confirm: confirm)
      reply(output, changed: changed ? [:reasoning_history] : [], confirm: ask)
    rescue ArgumentError => e
      reply(e.message, status: :error)
    end

    # /toolkit (ToolkitCommand); :toolkit in changed when it set the
    # session's toolkit.
    def toolkit(text, confirm: true)
      output, changed, ask = ToolkitCommand.new(engine: @engine, save: ->(session) { save_setup(session) })
                                           .run(text.delete_prefix(TOOLKIT_COMMAND), confirm: confirm)
      reply(output, changed: changed ? [:toolkit] : [], confirm: ask)
    rescue ArgumentError => e
      reply(e.message, status: :error)
    end

    # /parent-answers (ParentAnswersCommand); :parent_answers in changed
    # when it set the session's own level.
    def parent_answers(text, user_ui: false)
      output, changed, status = ParentAnswersCommand.new(engine: @engine, save: ->(session) { save_setup(session) })
                                                    .run(text.delete_prefix(PARENT_ANSWERS_COMMAND), user_ui: user_ui)
      reply(output, status: status, changed: changed ? [:parent_answers] : [])
    end

    # /working-set (WorkingSetCommand): an op that changes the conversation
    # (changed :messages: the worker saves it, the web reads it again)
    # closes the rollback window (a rollback past it would drop it
    # silently, as !cmd); a pin changes the session's working_set_pins.
    # Either way the working set goes out again (held after the command's
    # command_ran).
    def working_set(text)
      output, changed, status = WorkingSetCommand.new(engine: @engine, save: ->(_session) { save_session })
                                                 .run(text.delete_prefix(WORKING_SET_COMMAND))
      @turn_flow.note_conversation_changed if changed.include?(:messages)
      @engine.announce_working_set unless changed.empty?
      reply(output, status: status, changed: changed)
    rescue ArgumentError => e
      reply(e.message, status: :error)
    end

    # /title (TitleCommand); :title in changed when it named the session or
    # cleared its name. A plain save: no setting moved, and it may run on
    # an anytime thread beside a turn.
    def title(text)
      output, changed, status = TitleCommand.new(engine: @engine).run(text.delete_prefix(TITLE_COMMAND))
      reply(output, status: status, changed: changed ? [:title] : [])
    end

    # /recap on|off|default (RecapCommand); :recap in changed when this
    # session's own recap.enabled moved. It doesn't save: its host does on
    # a changed result (Worker#run_command, the REPL).
    def recap_setting(text)
      output, changed, status = RecapCommand.new(engine: @engine).run(text.delete_prefix(RECAP_COMMAND))
      reply(output, status: status, changed: changed ? [:recap] : [])
    end

    # A session setting changed (/llm-context, /thinking, /reasoning-history):
    # saved with its model.
    def save_setup(session)
      @engine.store_model!(session)
      @save.call(session)
    end

    # /model; a switch to another model asks first (CacheConfirm, cost
    # :full: the new model has no cache of the conversation), --yes applies.
    def model(text, confirm: true)
      suffix, yes = CacheConfirm.split(text.delete_prefix(MODEL_COMMAND), downcase: false)
      output, switched, ask = model_command("#{MODEL_COMMAND} #{suffix}", confirm: confirm && !yes)
      reply(output, changed: switched ? [:model] : [], confirm: ask)
    rescue ModelProfile::MissingModel => e
      # A model qualified with an unknown host: nothing switched.
      reply(e.message, status: :error)
    end

    # @param input [String] the /model line, --yes taken out
    # @param confirm [Boolean] a switch to another model asks first
    # @return [Array(String, Boolean, CacheConfirm::Confirm|nil)] the message,
    #   whether the model changed, and the confirm it asks for (nothing
    #   changed then)
    def model_command(input, confirm: false)
      suffix = input.delete_prefix(MODEL_COMMAND).strip
      if suffix.empty?
        return ["runtime model: #{model_name}#{model_note}#{served_note}#{sampling_note}#{steer_cut_after_note}#{thinking_note}#{reasoning_history_note}#{notes_note}", false] if @default_model.nil? || model_name == @engine.model_ref_for(@default_model)

        return ["runtime model: #{model_name}#{model_note("default: #{@default_model}")}#{served_note}#{sampling_note}#{steer_cut_after_note}#{thinking_note}#{reasoning_history_note}#{notes_note}", false]
      end

      # Parse flags: --default and --alias <name> / --alias=<name> (tolerant order)
      tokens = suffix.split(/\s+/)
      persist_default = false
      alias_name = nil
      alias_seen = false
      model_parts = []
      i = 0
      while i < tokens.length
        tok = tokens[i]
        if tok == "--default"
          persist_default = true
          i += 1
        elsif tok == "--alias"
          return ["multiple --alias flags are not supported: #{ALIAS_USAGE}", false] if alias_seen

          alias_seen = true
          nxt = tokens[i + 1]
          return ["--alias requires a name: #{ALIAS_USAGE}", false] if nxt.nil? || nxt.strip.empty? || nxt.start_with?("-")

          alias_name = nxt.strip
          i += 2
        elsif tok.start_with?("--alias=")
          return ["multiple --alias flags are not supported: #{ALIAS_USAGE}", false] if alias_seen

          alias_seen = true
          val = tok.delete_prefix("--alias=").strip
          return ["--alias requires a name: #{ALIAS_USAGE}", false] if val.empty? || val.start_with?("-")

          alias_name = val
          i += 1
        else
          model_parts << tok
          i += 1
        end
      end

      arg = model_parts.join(" ").strip

      if alias_name
        return ["--alias requires a model name: #{ALIAS_USAGE}", false] if arg.empty?
        return ["--alias cannot be combined with clear/default/none/off", false] if ConfigFile::RESERVED_MODEL_ALIASES.include?(arg.downcase)

        # Validate the alias before switching, so a bad one changes nothing.
        invalid = ConfigFile.model_alias_error(alias_name, arg)
        return ["invalid alias: #{invalid}", false] if invalid

        ask = confirm && model_ask(arg, input)
        return ask if ask

        switch_model(arg, persist_default: persist_default)

        begin
          previous = ConfigFile.write_model_alias!(alias_name, model_name)
        rescue ArgumentError => e
          return ["invalid alias: #{e.message} (runtime model set to #{model_name}#{model_note})", true]
        rescue StandardError => e
          return ["runtime model set to #{model_name}#{model_note} but failed to persist alias: #{e.message}", true]
        end

        key = alias_name.strip.downcase
        warn_prefix = previous ? "warning: overwriting alias '#{key}' (#{previous} -> #{model_name}); " : ""
        base = persist_default ? "runtime model set to #{model_name}#{model_note} and default updated#{thinking_note}#{reasoning_history_note}" : "runtime model set to #{model_name}#{model_note}#{thinking_note}#{reasoning_history_note}"
        ["#{warn_prefix}#{base}; alias '#{key}' -> '#{model_name}' persisted", true]
      else
        return ["--default requires a model name: usage /model --default <name> or /model <name> [--default]", false] if arg.empty?

        if ConfigFile::RESERVED_MODEL_ALIASES.include?(arg.downcase)
          return ["--default cannot be combined with clear/default/none/off", false] if persist_default
          raise ModelProfile::MissingModel, "no default model is configured (set default.model in config.yml, or /model <name> --default)" if @default_model.nil?

          ask = confirm && model_ask(@default_model, input)
          return ask if ask

          switch_model(@default_model)
          return ["runtime model reset to #{model_name}#{model_note}#{thinking_note}#{reasoning_history_note}#{notes_note}", true]
        end

        ask = confirm && model_ask(arg, input)
        return ask if ask

        switch_model(arg, persist_default: persist_default)
        if persist_default
          ["runtime model set to #{model_name}#{model_note} and default updated#{thinking_note}#{reasoning_history_note}#{notes_note}", true]
        else
          ["runtime model set to #{model_name}#{model_note}#{thinking_note}#{reasoning_history_note}#{notes_note}", true]
        end
      end
    end

    # The reply that asks before switching to +name+ (CacheConfirm), nil
    # when it needn't: the name is checked first (a typo errors at once,
    # MissingModel), and its resolved ref against the current one (the same
    # model costs nothing; any other restarts the whole cache).
    # @param line [String] the /model line as typed (its flags too), --yes taken out
    def model_ask(name, line)
      ref = @engine.model_switch_ref(name)
      step = CacheConfirm.ask(line: line, cost: :full, changed: ref != model_name, engine: @engine)
      return nil unless step

      ["runtime model: #{model_name}\nSwitching to #{ref} restarts the prompt cache: the new model has no cache of " \
       "this conversation.\n#{step.text}", false, step]
    end

    # Engine owns the switch (alias resolution, profile, kernel, client and
    # the optional default persist); the session keeps the new model.
    def switch_model(name, persist_default: false)
      @engine.switch_model!(name, persist_default: persist_default)
      @default_model = @engine.default_model_name if persist_default
      persist_session_model
      # The ctx % on the new model's window, before its first turn; saved
      # too, so the session's card (the hub's summary reads analytics.json)
      # stops showing the old model's % before a turn ends.
      @engine.announce_switched_context!
      @engine.metrics.persist(state_dir: @engine.session_state_dir)
    end

    def persist_session_model
      session = @engine.session
      return unless session

      @engine.store_model!(session)
      begin
        @save.call(session)
      rescue StandardError
        nil
      end
    end

    # "; served: <name>" when the server serves another model than asked
    # and its host's served: doesn't expect it.
    def served_note
      served, asked = @engine.served_model
      ServedModel.differs?(asked, served) && !@engine.served_expected?(served) ? "; served: #{served}" : ""
    rescue StandardError
      ""
    end

    # "; sampling: temperature=0.6 (hosts.work)" when the model has any.
    def sampling_note
      summary = @engine.sampling_summary
      summary ? "; sampling: #{summary}" : ""
    rescue StandardError
      ""
    end

    # "; steer cut: after 60 s (models: qwen)", or "; steer cut: never
    # (hosts.splash)" for 0 or less, when the model has one configured;
    # "" for the default.
    def steer_cut_after_note
      summary = @engine.steer_cut_summary
      summary ? "; steer cut: #{summary}" : ""
    rescue StandardError
      ""
    end

    # "; notes: model_notes_deepseek (system, 612 chars)": the model notes
    # the session's prompt carries (after a switch, the ones the new
    # model's prompt loads); "" without any.
    def notes_note
      text = PromptNote.text(@engine.prompt_notes)
      text.empty? ? "" : "; notes: #{text}"
    rescue StandardError
      ""
    end

    # "; thinking: off (models: qwen)" when the model has a level set.
    def thinking_note
      summary = @engine.thinking_summary
      summary ? "; thinking: #{summary}" : ""
    rescue StandardError
      ""
    end

    # "; reasoning history: drop (models: qwen)" when the chat model has a
    # level set.
    def reasoning_history_note
      summary = @engine.reasoning_history_summary
      summary ? "; reasoning history: #{summary}" : ""
    rescue StandardError
      ""
    end

    # " (default: x, profile=qwen36, name)": +extra+ and the prompt profile,
    # which a chat host's model doesn't have (its loop uses none); "" when
    # there is neither.
    def model_note(extra = nil)
      parts = [extra, (profile_note unless chat_model?)].compact
      parts.empty? ? "" : " (#{parts.join(", ")})"
    end

    def chat_model?
      @engine.chat_model?
    rescue StandardError
      false
    end

    # "profile=qwen36, server (chat_template)": the profile and where it came from.
    def profile_note
      resolution = @engine.profile_resolution
      "profile=#{resolution.profile.name}, #{resolution.label}"
    end

    # @param filter [String] only ids containing it (any case); "" lists
    #   up to MODELS_PER_HOST per host
    def models_listing(filter = "")
      needle = filter.downcase
      registry = @engine.host_registry
      # Aggregate across all hosts (lazy discovery, skip-on-error)
      results = registry.list_all_models
      return "no hosts configured" if results.nil? || results.empty?

      aliases = ConfigFile.model_aliases
      by_model = Hash.new { |h, k| h[k] = [] }
      # A bare alias shows next to its id on every host, a host:model one
      # only under its host.
      aliases.each do |alias_name, model_id|
        host, bare = registry.parse_qualified_model(model_id)
        by_model[host ? "#{host}:#{bare}".downcase : model_id.downcase] << alias_name
      end
      by_model.each_value { |v| v.uniq!; v.sort! }

      seen = Set.new
      lines = []
      host_rows = HostModel.rows(results, registry.entries)
      # Sort hosts for deterministic output
      results.keys.sort.each do |hname|
        data = results[hname]
        host_label = "#{hname} (#{data[:host]}:#{data[:port]})"
        # Declared ids (hosts.<name>.models) first, as "(config)", never cut
        # by MODELS_PER_HOST; a host that failed keeps only those, as
        # "(config, host down)" under its unreachable line.
        rows = host_rows.fetch(hname, [])
        if data[:error]
          lines << "#{host_label} — unreachable: #{data[:error]}"
          next if rows.empty?
        elsif rows.empty?
          lines << "#{host_label} — no models discovered"
          next
        end
        declared = []
        shown = []
        batch_variants = batch_variant_ids(rows, needle)
        rows.each do |row|
          identifier = row.id.to_s.empty? ? "unknown" : row.id
          seen << identifier.to_s.downcase
          # also track host-qualified seen for orphan logic
          seen << "#{hname}:#{identifier}".downcase
          next if !row.configured && batch_variants.include?(identifier)
          next unless needle.empty? || identifier.to_s.downcase.include?(needle)

          (row.configured ? declared : shown) << [row, identifier]
        end
        next if declared.empty? && shown.empty?

        lines << "#{host_label}:" unless data[:error]
        hidden = needle.empty? ? [shown.size - MODELS_PER_HOST, 0].max : 0
        (declared + shown.first(shown.size - hidden)).each do |row, identifier|
          raw = row.info&.raw || {}
          raw_status = raw["status"] || raw[:status]
          status = raw_status.is_a?(Hash) ? (raw_status["value"] || raw_status[:value] || raw_status["status"] || raw_status[:status]) : raw_status
          status = ["config", status].reject { |s| s.to_s.empty? }.join(", ") if row.configured
          status = "#{status}, host down" if row.unavailable
          base = status.to_s.empty? ? "  #{identifier}" : "  #{identifier} (#{status})"
          alias_list = (by_model[identifier.to_s.downcase] || []) + (by_model["#{hname}:#{identifier}".downcase] || [])
          alias_list.uniq!
          lines << (alias_list.empty? ? base : "#{base} (alias: #{alias_list.join(", ")})")
        end
        batch = batch_variants.count { |id| needle.empty? || id.downcase.include?(needle) }
        batch_note = "#{batch} :batch variant#{"s" unless batch == 1}"
        if hidden.positive?
          more = batch.positive? ? "#{hidden} more, plus #{batch_note}" : "#{hidden} more"
          lines << "  … and #{more}; /models <text> lists the ids containing <text>"
        elsif batch.positive?
          lines << "  … plus #{batch_note}; /models :batch lists them"
        end
      end
      # Warnings for unreachable hosts are already in lines; no failover
      orphans = aliases.reject { |_, model_id| seen.include?(model_id.downcase) || seen.include?(registry.parse_qualified_model(model_id).last.downcase) }
      unless orphans.empty? || !needle.empty?
        lines << ""
        lines << "orphan aliases (target not discovered):"
        orphans.sort.each { |alias_name, model_id| lines << "  #{alias_name} -> #{model_id}" }
      end
      lines = [needle.empty? ? "no models discovered" : "no model ids contain #{filter.inspect}"] if lines.empty?
      lines.join("\n")
    rescue StandardError => e
      "unable to list models: #{e.message}"
    end

    # OpenRouter lists a "<id>:batch" variant next to many ids (71 of 457 on
    # 2026-09-23), which only repeats the model. The ids of such variants
    # whose plain id is listed too, unless the filter asks for batch.
    def batch_variant_ids(models, needle)
      return Set.new if needle.include?("batch")

      # Any case: a declared id keeps its own spelling (HostModel.rows).
      ids = models.map { |entry| entry.id.to_s }
      plain = ids.to_set(&:downcase)
      ids.select { |id| id.downcase.end_with?(":batch") && plain.include?(id.downcase.delete_suffix(":batch")) }.to_set
    end
  end
end
