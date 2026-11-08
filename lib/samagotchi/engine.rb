# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"
require "yaml"

require_relative "client_id"
require_relative "iteration_limit"
require_relative "config"
require_relative "context_note"
require_relative "context_status"
require_relative "steer"
require_relative "turn_note"
require_relative "turn_endings"
require_relative "turn_origin"
require_relative "revise_anchor"
require_relative "verify_anchor"
require_relative "redact"
require_relative "verdict"
require_relative "model_profile"
require_relative "effective_model"
require_relative "session_setting"
require_relative "session_model_settings"
require_relative "thinking_notices"
require_relative "cancellation_controller"
require_relative "context_window"
require_relative "kernel_loop"
require_relative "tools/builtins"
require_relative "tools/task_runtime"
require_relative "tools/tool_index"
require_relative "tools/tool_surface"
require_relative "peer_sources"
require_relative "session_commands"
require_relative "plugin/loader"
require_relative "plugin/card"
require_relative "bundle_settings_check"
require_relative "extension_load"
require_relative "log"
require_relative "log_subscriber"
require_relative "thinking_tails"
require_relative "client"
require_relative "host_registry"
require_relative "llm/backend"
require_relative "llm/openai_chat"
require_relative "llm/turn_settings"
require_relative "session"
require_relative "toolkit_binding"
require_relative "participant_mode"
require_relative "context_candidates"
require_relative "context_candidates_log"
require_relative "context_candidate_choice"
require_relative "context_judge"
require_relative "objectives_audit"
require_relative "owner_prompt"
require_relative "side_judgments"
require_relative "system_one/recorder"
require_relative "toolkit_suggest"
require_relative "turn_stages/context_judge"
require_relative "turn_stages/objectives"
require_relative "turn_stages/toolkit_suggestion"
require_relative "turn_stages/verify_anchors"
require_relative "turn_stages/warmup"
require_relative "tool_loads"
require_relative "answer_tail"
require_relative "archive_store"
require_relative "session_observer"
require_relative "tool_declarations"
require_relative "system_prompt"
require_relative "session_metrics"
require_relative "token_usage"
require_relative "idle_recap"
require_relative "recap_setup"
require_relative "idle_reminders"
require_relative "idle_scheduler"
require_relative "hooks"
require_relative "event_fanout"
require_relative "event_routes"
require_relative "hook_routes"
require_relative "guardrails"
require_relative "reminder_store"
require_relative "reminder_queue"
require_relative "memory_orphans"
require_relative "tools/memory"
require_relative "muted_memories"
require_relative "used_memories"
require_relative "turn_state"
require_relative "turn_context"
require_relative "steer_cut"
require_relative "engine_peers"
require_relative "engine_snapshots"
require_relative "bundle_needs"
require_relative "model_binding"
require_relative "model_overlay"
require_relative "model_notes"
require_relative "prompt_note"
require_relative "served_model"
require_relative "image_store"
require_relative "vision_context"
require_relative "vision_support"
require_relative "sampling_settings"
require_relative "thinking"
require_relative "reasoning_history"
require_relative "answer_display"
require_relative "answer_refs"
require_relative "message_time"
require_relative "edit_preview"
require_relative "question_desk"
require_relative "question_asked"
require_relative "child_reports"
require_relative "relay_desk"
require_relative "guardrail_wiring"
require_relative "plugin_tasks"
require_relative "prompt_warmup"
require_relative "working_set"
require_relative "participants_watch"
require_relative "session_participants"
require_relative "engine/steering"
require_relative "engine/side_requests"
require_relative "engine/recap"
require_relative "engine/models"
require_relative "engine/model_settings"
require_relative "engine/events"
require_relative "engine/cards"
require_relative "engine/objectives"
require_relative "engine/messages"
require_relative "engine/plugins"
require_relative "engine/hooks"
require_relative "engine/guardrails"
require_relative "engine/participants"
require_relative "engine/session"
require_relative "engine/verify"
require_relative "engine/questions"
require_relative "engine/toolkit"
require_relative "engine/context_judge"
require_relative "engine/turn_helpers"
require_relative "engine/turn_end"

module Samagotchi
  # Engine owns the core agent logic: system prompt construction, tool
  # declarations, session lifecycle, and the model↔tool loop.
  #
  # It exposes an event-based API (`on_event`) so that any UI can run
  # turns without coupling to terminal rendering.
  #
  # This file keeps the wiring (initialize, the build_* methods, the
  # kernel) and the turn skeleton (run_turn, begin_turn, prepare_turn's
  # ordered steps, generate, end_turn) and shutdown. The rest is in parts
  # by concern: lib/samagotchi/engine/<concern>.rb holds module
  # Engine::<Concern>Part (the Part suffix keeps a part's name off the
  # Samagotchi constants Engine's code names bare: Toolkit, Objectives…),
  # included here; they share Engine's ivars.
  class Engine
    include SteeringPart
    include SideRequestsPart
    include RecapPart
    include ModelsPart
    include ModelSettingsPart
    include EventsPart
    include CardsPart
    include ObjectivesPart
    include MessagesPart
    include PluginsPart
    include HooksPart
    include GuardrailsPart
    include ParticipantsPart
    include SessionPart
    include VerifyPart
    include QuestionsPart
    include ToolkitPart
    include ContextJudgePart
    include TurnHelpersPart
    include TurnEndPart

    # Raised by #answer_question when the question it targets is no longer
    # open (never asked, superseded, already answered or cancelled). A subclass
    # of ArgumentError for existing callers; transports map it to 409 Conflict.
    QuestionNotPending = QuestionDesk::NotPending

    # Build a system prompt string for the given profile.
    # Used by specs and inspection.
    def self.system_prompt_for(profile)
      profile = ModelProfile.normalize(profile) unless profile.is_a?(ModelProfile)
      new(profile: profile, plugins: false).assist_system_prompt
    end

    # What memory_write answers in a scratch session.
    SCRATCH_MEMORY_WRITE = "Error: scratch session: nothing is saved"
    # The session setting /recap on|off|default writes (#recap_override=).
    RECAP_ENABLED_KEY = "recap.enabled"

    # @param client             [Client, nil] defaults to Client.new
    # @param profile            [ModelProfile, Symbol, String, nil]
    # @param session_id         [String, nil] resume an existing session
    # @param no_interrupt       [Boolean] --no-interrupt: every turn runs with
    #   IterationLimit.for(no_interrupt: true), whichever loop runs it
    # @param model_name         [String, nil] defaults from SAMAGOTCHI_DEFAULT_MODEL
    # @param model_typed        [String, nil] the name the model was given as (a session's
    #   model_typed: an alias), for the models: lookup; model_name by default
    # @param memories           [Array<String>] explicit --memory preload list (merged with the config.yml `memories:` baseline)
    # @param muted_memories     [Array<String>] --mute list: memories hidden from this session (not in the
    #   prompt's index, dropped from the preloads, refused by memory_read); a mute wins over a preload
    # @param appended_prompt_files [Array<String>] --append-system-prompt's files (absolute paths; a session's
    #   appended_prompt_files): their text goes into the system prompt after config.yml's append_system_prompt:
    # @param plugins            [Boolean] false: load no bundle plugins (a throwaway Engine for a prompt)
    # @param scratch            [Boolean] a `chi scratch` session: memory writes are refused, and there is no
    #   delegate (a child would outlive it) nor plugin fork
    # @param task_finish_notes  [Boolean] a worker's Engine whose finish wake reports a task the model leaves
    #   running (Worker, TaskWatch): execute's and task_create's descriptions say so
    def initialize(client: nil, host_registry: nil, profile: nil, session_id: nil, no_interrupt: false, model_name: nil, memories: [], muted_memories: [], kernel: nil, recap: nil, reminders: nil,
                   plugins: true, scratch: false, model_typed: nil, appended_prompt_files: [], task_finish_notes: false)
      # The turn as other threads see it (flag, cancel controller, sink,
      # steers) and the idle layer's activity clock. Built first: a plugin
      # may steer or ask whether a turn runs while it loads.
      @turn_state = TurnState.new(clock: -> { monotonic_now })
      # A message for the running turn cutting its generation.
      @steer_cut = SteerCut.new(clock: -> { monotonic_now }, controller: -> { active_cancel_controller },
                                cut_after: -> { steer_cut_after })
      # How an event reaches the turn's sink and the observers, and the
      # stream handler. Built early: the question desk's and the init tasks'
      # emit go through it.
      @event_fanout = build_event_fanout
      # What each turn ending keeps and announces (one lookup).
      @turn_endings = build_turn_endings
      @scratch = scratch
      @no_interrupt = no_interrupt
      @chat_backend = nil
      @chat_backend_mutex = Mutex.new
      @side_judgments = SideJudgments.new
      @judgments = build_judgments
      @host_registry = host_registry || HostRegistry.new
      # The turn stages over the objectives (its audit, view and proposals)
      # and the Verify/Revise anchors (TurnStages).
      @objectives_stage = build_objectives_stage
      @verify_anchors = build_verify_anchors
      # A model given here (a worker's session model) is the one it runs,
      # so its host is checked; the config default is only checked once it
      # is used (the one-shot checks the model it starts on, #switch_model!).
      @default_model_name = ModelProfile.required_model_name(model_name)
      ModelProfile.check_host!(model_name, hosts: @host_registry.entries) unless model_name.to_s.strip.empty?
      # The model choice and the profile resolved for it, under one mutex.
      # A caller's profile pins it (until a model switch); otherwise
      # #profile_resolution decides on first need (see there), so building an
      # Engine makes no network call.
      typed = model_typed.to_s.strip
      @model_binding = build_model_binding(
        ModelChoice.new(name: @default_model_name, typed: typed.empty? ? @default_model_name : typed),
        profile ? ModelProfile.normalize(profile) : nil
      )
      # The session's settings on its effective model (SessionModelSettings),
      # read at use: /model moves the choice, #session= the session.
      @model_settings = SessionModelSettings.new(registry: @host_registry, choice: -> { @model_binding.choice },
                                                 session: -> { @session })
      # An injected client (specs) stands in for every host's client.
      @host_registry.client_override = client if client
      @client = effective_model.client
      # Ensure the built-in system bundle is installed (lazy, warn-only).
      # This is the single seam for both TUI and non-TUI (web/worker) paths.
      begin
        require_relative "memory_bundle/system_bundle"
        MemoryBundle::SystemBundle.ensure!
      rescue StandardError => e
        Log.warn(:memory, "system_bundle_ensure_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      end
      # What hooks and plugins do beyond reading their event (a notice, a
      # question, a stop, a steer), routed to the UIs. Built before anything
      # that may notify. Where a card or a notice goes (EventRoutes) first:
      # the hook routes use it.
      @event_routes = build_event_routes
      @hook_routes = build_hook_routes
      # Load hooks from config (plugins) and create the registry; what fails
      # to load is announced, and a required guardrail's failure denies
      # every tool call. Rules load now too, so their errors are announced.
      @guardrail_wiring = build_guardrail_wiring
      @guardrail_failures = @guardrail_wiring.failures
      # Plugins that failed to load: announced apart, as plugins (not
      # guardrails: no tool call is denied for them).
      @plugin_failures = Guardrails::LoadFailures.new
      # The question flow (ask_user_question, hooks' and plugins' ask_user,
      # approvals). Built before the hooks and plugins load: a plugin can ask
      # during its load (answered nil then: the interface is still
      # :non_interactive).
      @question_desk = build_question_desk
      # Built here, not on first use: the turn thread and the Bridge's read it.
      @relay_desk = RelayDesk.new
      # The notices a turn's thinking level leads to (once per session and host).
      @thinking_notices = ThinkingNotices.new(session: -> { @session }, profile: -> { self.profile },
                                              notify: ->(text, level, source) { hook_notify(text, level, source) })
      @lifecycle_mutex = Mutex.new
      @shut_down = false
      # The built-ins, the commands, and the plugins that add to them.
      build_tools_and_plugins(load: plugins, task_finish_notes: task_finish_notes)
      guardrail_rules
      # The Engine owns the reminder store; its kernel (built here, or a
      # spec's) gets it, so tool calls via KernelLoop and reminder injection
      # via Engine read/write the same store.
      @reminder_store = ReminderStore.new
      # The due reminders on their way into a turn, and the names the idle
      # tick queued for a reminder turn.
      @reminder_queue = ReminderQueue.new(store: @reminder_store)
      # Build the idle reminders detector (wired to reminder_store)
      callback = reminders.is_a?(Hash) && reminders[:callback] ? reminders[:callback] : nil
      @reminders = build_reminders(auto_turn_callback: callback)
      # Track whether this is the first turn in the session (for session_start event)
      @first_turn = true
      # The kernel (built here, or a spec's) and what it reads of the Engine;
      # then the native backend over it.
      wire_kernel(kernel, muted_memories)
      # The turn-end warm-up's stage, over that kernel.
      @turn_warmup = build_turn_warmup
      Log.debug(:model, "backend", provider: backend.provider) if Log.level?(:debug)
      @resume_session = session_id ? Session.load(session_id) : nil
      @prompt_builder = build_system_prompt(memories, appended_prompt_files)
      # The session's participants (participants.json), read at each turn's
      # start: their names for the messages they wrote.
      @participants = SessionParticipants.new(state_dir: -> { session_state_dir })
      # Whether the system prompt carries the participants line.
      @participants_line = nil
      # Who is in the review now, and who came or went (#announce_participants).
      @participants_watch = ParticipantsWatch.new(session_id: -> { @session&.id }, state_dir: -> { session_state_dir })
      @session = nil
      @session_observer = SessionObserver.new
      @metrics = SessionMetrics.new
      @used_memories = UsedMemories.new
      # Hydrate from resumed session if present
      if @resume_session
        @used_memories.absorb(@resume_session)
        @session = @resume_session
      end
      # The idle subsystems' (session recap + reminders) inactivity clock
      # starts now, after the plugins loaded. `record_activity` is the
      # single seam every host calls (run_turn itself, the worker after a
      # reminder turn), so the idle layer's clock is identical across hosts.
      @turn_state.restart_clock!
      @side_client_mutex = Mutex.new
      # Kept for a rebuild under a bound session's own recap values.
      @recap_kwarg = recap
      @recap = build_recap
      # One shared poller for the whole idle layer (reminders + optional
      # recap). Both jobs read the activity seam above; the scheduler owns
      # the single background thread and isolates per-job failures.
      @idle_scheduler = build_idle_scheduler
      subscribe_session_observers
      # The UIs' read model (/state, /stats). Built last: nothing calls a
      # snapshot while the Engine is built.
      @engine_snapshots = build_engine_snapshots
    end

    # ── initialize's collaborators ──────────────────────────────────────────

    # The Engine as the plugins' host: the tools and slash commands this
    # session offers, what plugins add to them (services, init tasks, the
    # toolkit, the tool index, peer sources), then the plugins themselves
    # unless +load+ is false (see #initialize for when).
    def build_tools_and_plugins(load:, task_finish_notes:)
      # The routes are built already (#initialize), so a bundle's hook file
      # that raises at fire time is told the same way a chi.on handler is:
      # once per hook in this worker. The guard covers a hook that raises
      # before the routes are there (nothing in the Engine's path does).
      @extension_load = ExtensionLoad.new(hook_failures: @guardrail_failures,
                                          hook_failed: ->(hook, failed, effect: nil) { @hook_routes&.plugin_hook_failed(hook, failed, effect: effect) })
      @hooks = @extension_load.hooks
      # The tools this session offers (the prompts' declarations and the
      # kernel's dispatch): the built-ins, per Engine. execute.description
      # off: execute offers no description parameter. +task_finish_notes+:
      # a worker's, whose finish wake reports a task left running (the
      # Worker's TaskWatch): execute and task_create say so.
      @tools = Tools::Builtins.registry(command_description: Config.get("execute.description") != false,
                                        policy: Config.get(LLMContextStrategy::POLICY_SETTING),
                                        task_finish_notes: task_finish_notes)
      restrict_scratch_tools! if @scratch
      # Likewise the slash commands its SessionCommands run.
      @command_registry = SessionCommands.register_builtins(Commands::Registry.new)
      # Installed bundles' plugins add commands, tools and hooks to these
      # (docs/plugins.md); one that fails is announced with the load
      # failures, and the rest still load.
      # Their services (chi.service), which #shutdown stops, and the anytime
      # commands running now (#spawn_anytime), which it waits for.
      @services = Plugin::Services.new
      @anytime_threads = []
      # chi.init tasks (#add_init_task), started by #start_init_tasks!, and
      # plugins' tool sets from chi.replace_tools until the turn thread
      # applies them (#apply_staged_tools!). Built before the plugins load.
      @plugin_tasks = build_plugin_tasks
      # The session's toolkit: the kits (the plugins' too, chi.toolkit),
      # what its next turn declares, the turn-start apply.
      @toolkit_binding = build_toolkit_binding
      # The turn stages over it and the side asks (TurnStages): System 1's
      # toolkit suggestion and the attached-context candidate judge, which a
      # plugin may reach as it loads.
      @toolkit_suggestion = build_toolkit_suggestion
      @context_judge = build_context_judge
      # The tools plugins publish without declaring (chi.tool_source), and
      # the search and call tools that reach them (Tools::ToolIndex).
      @tool_index = Tools::ToolIndex.new
      # The tools plugins load (ctx.load_tools), staged until a turn's
      # messages are built (#append_tool_loads).
      @tool_loads = ToolLoads.new
      # The context sources the peer bundles declare as a peer agent's
      # answers (chi.peer_source); the worker's ContextAbsorber asks it.
      @peer_sources = PeerSources.new
      # The system-prompt text plugins add (chi.prompt_section), run when
      # the prompt is built (#build_system_prompt's sections:).
      @prompt_sections = Plugin::PromptSections.new
      load_plugins if load
      # Registered from what the sources published while they loaded, and
      # with no plugins too: a toolkit's left-out tools are reachable
      # either way (declared per toolkit, Tools::Registry).
      @tool_index.declare(@tools, failures: @plugin_failures)
      # What readers off the turn thread see until the first turn's start.
      publish_tools!
    end
    private :build_tools_and_plugins

    # The tools a scratch session doesn't offer, and its memory_write.
    def restrict_scratch_tools!
      # A scratch session's children would outlive it, and so would a
      # note it left in a peer; its memories would too (write and edit
      # into the memories: ScratchWrites).
      [Tools::Delegate::NAME, Tools::DelegateResult::NAME, Tools::SendNote::NAME].each { |name| @tools.unregister(name) }
      @tools[Tools::MemoryWrite::NAME].handler = ->(_call, _kctx) { SCRATCH_MEMORY_WRITE }
    end
    private :restrict_scratch_tools!

    # The persistent observers of every turn's events.
    def subscribe_session_observers
      # The metrics collector is a persistent observer so every run_turn event
      # (a -p --non-interactive one-shot and SessionManager workers)
      # feeds it automatically.
      @session_observer.subscribe(observer: @metrics)
      # And the event trail in the debug log (`turn` records).
      @session_observer.subscribe(observer: LogSubscriber.new(session_id: -> { @session&.id }))
      # The thinking of cut and capped generations, kept in the session dir.
      @session_observer.subscribe(observer: ThinkingTails.new(session_dir: lambda {
        @session&.id && Session.session_dir(@session.id, state_dir: session_state_dir)
      }))
    end
    private :subscribe_session_observers

    # The kernel and what it holds of the Engine for its life, one
    # KernelLoop::Services (stores, hooks, tools, the mutes, the question
    # flow, peers, the gate, warm-up, the generation guard), and the native
    # backend over it. After the plugins load. Nothing per turn: a turn's
    # TurnContext goes down the backend's complete (#generate).
    def wire_kernel(kernel, muted_memories)
      # The mutes never change during a session: the kernel's memory_read
      # guard reads the same list for every turn.
      @muted_memory_names = MutedMemories.normalize_list(muted_memories)
      # Where the approvals live; also where list_sessions and send_note
      # look for other sessions (a worker moves it, Worker).
      self.guardrail_state_dir = Session.default_state_dir
      # The turn-end warm-up; the kernel asks it for a slot pin per request.
      @prompt_warmup = PromptWarmup.new
      services = KernelLoop::Services.new(
        hooks: @hooks, tools: @tools, reminder_store: @reminder_store, muted_memory_names: @muted_memory_names,
        # ask_user_question blocks on the Engine's question flow (TUI/Web answer it).
        question_handler: proc { |payload| request_question(payload) },
        # list_sessions and send_note speak for whichever session runs now.
        peers: PeerView.new(self),
        # Every tool call asks this gate first. The kernel is never rebuilt,
        # so it holds across model switches.
        gate: @guardrail_wiring.gate(hooks: @hooks, tools: @tools),
        warmup: @prompt_warmup,
        # A pair turn stops once its participant passed their cap.
        generation_guard: ->(context) { guard_participant_spend(context) }
      )
      # A given kernel (specs) gets the same services as the one built here.
      @kernel = kernel || KernelLoop.new(client: @client, profile: @model_binding.given_profile,
                                         model_name: effective_model_name, services: services)
      @kernel.attach(services) if kernel
      sync_kernel_client!
      sync_model_key!
      # What a hook can do beyond reading its event (event[:notify],
      # event[:ask_user], event[:stop_turn]): the Engine's routes to the UIs.
      @hooks.runtime = hook_runtime
      # The loop follows the effective model's host (its api:): the raw-prompt
      # NativeBackend, or the chat backend for chat hosts (openai, anthropic).
      @native_backend = LLM::NativeBackend.new(kernel: @kernel)
    end
    private :wire_kernel

    # The tool guardrails (see #initialize for when).
    def build_guardrail_wiring
      GuardrailWiring.new(
        scratch: @scratch,
        # Built before the tools (the hooks load into its failures).
        tools: -> { @tools },
        session: -> { @session },
        cancelled: -> { !!active_cancel_controller&.cancelled? },
        # An approval of the model's call: :question_asked first (QuestionAsked).
        ask: ->(fields) { open_question(question_asked(QuestionAsked::KIND_APPROVAL, fields)) },
        notify: ->(message) { guardrail_notify(message) },
        # System 1 (experimental, audit phase): the judgment client is read
        # from config on every ask, and the running turn's cancel controller
        # closes a judgment that is no longer wanted.
        system_one: lambda {
          system_one_recording(SystemOne::Client.from_config(host_registry: @host_registry, mode: Config.get("guardrails.system_one.mode")),
                               SystemOne::ApprovalQuestion::JUDGMENT, @session)
        },
        system_one_runs: -> { system_one_runs },
        cancel_controller: -> { active_cancel_controller },
        # A participant's turn: their name on the owner's card, their
        # grant's mode for the turn's (GuardrailWiring#begin_turn).
        participant: ->(author) { @participants.entry_for(author, session: @session) }
      )
    end
    private :build_guardrail_wiring

    # The event fan-out and the stream handler (see #initialize for when).
    def build_event_fanout
      EventFanout.new(
        observer: -> { @session_observer },
        used_memories: -> { @used_memories },
        muted: -> { @muted_memory_names },
        steer_cut: -> { @steer_cut },
        thinking_notices: -> { @thinking_notices },
        metrics: -> { @metrics },
        hooks: -> { @hooks },
        turn_context: -> { turn_context },
        last_turn_context: -> { last_turn_context },
        model_settings: -> { @model_settings },
        session: -> { @session },
        live_conversation: -> { live_conversation },
        used_memory_names: -> { used_memory_names },
        served_expected_by: ->(served) { served_expected_by(served) },
        working_set_strategy: -> { working_set_strategy },
        turn_running: -> { turn_running? },
        announce_or_hold: ->(event) { announce_or_hold(event) }
      )
    end
    private :build_event_fanout

    # The snapshots the UIs read (see #initialize for when).
    def build_engine_snapshots
      EngineSnapshots.new(
        session: -> { @session },
        metrics: -> { @metrics },
        observer: -> { @session_observer },
        question_desk: -> { @question_desk },
        used_memories: -> { @used_memories },
        muted: -> { @muted_memory_names },
        prompt_builder: -> { @prompt_builder },
        participants: -> { @participants },
        participants_watch: -> { @participants_watch },
        recap: -> { @recap },
        last_context_status: -> { @last_context_status },
        model_settings: -> { @model_settings },
        effective_model: -> { effective_model },
        effective_model_name: -> { effective_model_name },
        effective_model_ref: -> { effective_model_ref },
        bare_model_name: ->(ref) { bare_model_name(ref) },
        served_model: ->(probe:) { served_model(probe: probe) },
        prompt_notes: -> { prompt_notes },
        preloaded: -> { preloaded_memory_names },
        saved_context_status: ->(context, **opts) { saved_context_status(context, **opts) },
        context_window: ->(model) { current_context_window(model) },
        profile_resolution: -> { profile_resolution },
        toolkit_summary: -> { toolkit_summary },
        toolkit_explained: -> { toolkit_explained }
      )
    end
    private :build_engine_snapshots

    # The model choice and its prompt profile (see #initialize for when).
    def build_model_binding(choice, given_profile)
      ModelBinding.new(choice: choice, given_profile: given_profile, registry: @host_registry,
                       kernel: -> { @kernel }, prompt_builder: -> { @prompt_builder },
                       bare_name: ->(name) { bare_model_name(name) })
    end
    private :build_model_binding

    # The turn endings' builders (see #initialize for when).
    def build_turn_endings
      TurnEndings.new(failure_summary: ->(error) { failure_summary(error) })
    end
    private :build_turn_endings

    # The question flow (see #initialize for when).
    def build_question_desk
      QuestionDesk.new(
        session: -> { @session },
        state_dir: -> { session_state_dir },
        emit: ->(event) { emit_event(nil, event) },
        cancel_controller: -> { active_cancel_controller },
        interface: -> { interface },
        user_input: ->(sid) { ArchiveStore.user_input(sid, state_dir: session_state_dir) }
      )
    end
    private :build_question_desk

    # The plugins' init tasks and staged tool sets (see #initialize for when).
    def build_plugin_tasks
      PluginTasks.new(
        clock: -> { monotonic_now },
        synchronize_events: ->(&block) { synchronize_events(&block) },
        announce: ->(event) { announce(event) },
        emit: ->(sink, event) { emit_event(sink, event) },
        show_card: ->(**card) { show_card(**card) },
        tools: -> { @tools },
        notify: ->(text, level, source, fallback_for: nil) { hook_notify(text, level, source, fallback_for: fallback_for) },
        tools_changed: -> { tools_changed! }
      )
    end
    private :build_plugin_tasks

    # The system prompt's live sources and this session's fixed inputs.
    def build_system_prompt(memories, appended_prompt_files)
      SystemPrompt.new(profile: -> { profile }, tools: -> { @tools }, session: -> { @session },
                       thinking: -> { turn_thinking }, model: -> { model_identity },
                       model_notes: -> { model_notes }, memories: memories,
                       muted_memory_names: @muted_memory_names, appended_files: appended_prompt_files,
                       participants: -> { @participants_line },
                       sections: -> { @prompt_sections ? @prompt_sections.render(@session&.id) : [] })
    end
    private :build_system_prompt

    # The idle layer's shared scheduler (see #initialize for when).
    def build_idle_scheduler
      IdleScheduler.new(engine: self, jobs: [@reminders, @recap].compact)
    end
    private :build_idle_scheduler

    # A monotonically-increasing clock (wall clock can jump backwards; the idle
    # detector must never treat a jump as "activity"). Injectable for specs.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    RECAP_SIDE_KIND = "recap"

    # @return [SessionMetrics] the per-session analytics collector
    attr_reader :metrics

    attr_reader :default_model_name, :host_registry, :client

    # @return [Commands::Registry] the commands this session runs: the
    #   built-ins, and the ones bundle plugins add
    attr_reader :command_registry

    # @return [PeerSources] the sources the peer bundles declared
    attr_reader :peer_sources

    # Event types #announce accepts: facts about the session's input queue,
    # a failed turn's prompt handed back and the continue offer, which live
    # UIs need in the event log, emitted outside any turn's stream; a
    # Verify fresh child's verdict landing on its card (:verdict_recorded).
    ANNOUNCEABLE_EVENTS = %i[turn_enqueued turn_dequeued input_merged prompt_restored continue_offered continue_resolved
                             command_queued command_ran context_added card hook_notice guardrail_warning
                             plugin_init_started plugin_init_finished working_set_updated participants_changed
                             verdict_recorded objectives_updated].freeze

    # ── Plugin init tasks (chi.init) ──────────────────────────────────────

    # A plugin's slow setup (docs/plugins.md, Init tasks): PluginTasks.
    InitTask = PluginTasks::InitTask
    INIT_TASK_TIMEOUT = PluginTasks::INIT_TASK_TIMEOUT
    INIT_WAIT_POLL = PluginTasks::INIT_WAIT_POLL

    # How long #shutdown waits for the running anytime commands, in all.
    SHUTDOWN_JOIN_SECONDS = 3.0
    # How long #shutdown waits for the running side judgments (System 1
    # asks: SideJudgments; a one-shot -p --non-interactive exits right
    # after its turn), in all; a slower ask goes unlogged.
    SIDE_JUDGMENTS_JOIN_SECONDS = 1.0

    # The session's worker (or a one-shot run) is leaving (/exit, an idle
    # exit, a crash, TERM): stop the idle jobs, give the running anytime commands
    # up to +join_timeout+ seconds to finish (their command_ran is
    # announced), then stop the plugins' services, newest first. Once;
    # later calls do nothing.
    # @return [self]
    def shutdown(join_timeout: SHUTDOWN_JOIN_SECONDS)
      threads = @lifecycle_mutex.synchronize do
        return self if @shut_down

        @shut_down = true
        # An init task's requests end (a server's boot), so it finishes.
        @anytime_threads.dup + @plugin_tasks.shut_down!
      end
      # #stop_idle's work (the scheduler's stop is idempotent), where the
      # callers haven't stopped it already.
      @idle_scheduler&.stop
      @prompt_warmup.stop
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + join_timeout
      threads.each do |thread|
        next if thread == Thread.current

        thread.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
      end
      @side_judgments.join(SIDE_JUDGMENTS_JOIN_SECONDS)
      # The warm-up's answer is dropped anyway.
      @toolkit_suggestion.stop_warmup
      left = threads.count(&:alive?)
      Log.warn(:plugins, "anytime_commands_left", count: left) if left.positive?
      @plugin_tasks.kill_leftovers
      @services.stop_all
      self
    end

    # What a participant turn's stop is attributed to (HookRoutes#stop_turn).
    PARTICIPANTS_HOOK = "participants"

    # How every turn ends (completed, canceled, failed): the session gets
    # what the turn kept, goes idle and records the ending, and the end
    # event is announced, as one step of the event log (a snapshot taken
    # meanwhile, the Bridge's, shows the turn either in progress or in the
    # messages, never both or neither). Then the metrics are persisted.
    # The block runs in that step with the turn's seconds, once, and
    # returns [the messages to keep (nil: leave the session's), the end
    # event]. +save:+ also saves the session (a failed turn: a worker exits
    # after it). The disk writes come after the step: every emitter waits
    # for the event lock. +exhausted:+ the turn ran out of iterations
    # (its limit goes in last_turn). The end event names its turn
    # (`turn_id:`, as :turn_started does) and, for a Verify turn,
    # `verify: true` (its opening's stamp: a page watching it live offers
    # no Revise on its answer, verdict or not, as a reload does).
    def end_turn(turn, outcome, save: false, exhausted: false)
      seconds = turn.elapsed
      turn.outcome = outcome
      synchronize_events do
        kept, event = yield(seconds)
        event[:turn_id] = turn.id
        event[:verify] = true if turn.verify
        revises = @verify_anchors.stamp_opening(kept, turn, outcome)
        replace_session_messages(turn.session, kept) if kept
        verdict = @verify_anchors.record_verdict(turn, outcome)
        event[:verdict] = verdict if verdict
        event[:revises] = revises.to_h if revises
        emit_working_set(turn.on_event, turn.session, turn.session.messages)
        @objectives_stage.announce(turn.session)
        turn.session.status = Session::STATUS_IDLE
        record_last_turn(turn.session, outcome, seconds, turn.origin, event, limit: exhausted ? turn.limit : nil)
        emit_event(turn.on_event, turn.tag(event))
      end
      turn.ended = true
      @turn_state.ended!
      save_quietly(turn.session) if save
      @metrics.persist(state_dir: session_state_dir)
    end
    private :end_turn

    # What a notice may stand in for (hook_notify's fallback_for:).
    NOTICE_FALLBACKS = HookRoutes::NOTICE_FALLBACKS

    # Where cards and notices go (see #initialize for when). Each lookup
    # calls the Engine method the routes used before EventRoutes, at use.
    def build_event_routes
      EventRoutes.new(
        extension_load: -> { @extension_load },
        in_turn_sink: -> { @turn_state.in_turn_sink },
        anytime_thread: -> { anytime_thread? },
        init_task: -> { current_init_task },
        announce: ->(event) { announce(event) },
        announce_anytime: ->(event) { announce_anytime(event) },
        announce_or_hold: ->(event) { announce_or_hold(event) },
        emit: ->(sink, event) { emit_event(sink, event) }
      )
    end
    private :build_event_routes

    # The hook routes (see #initialize for when).
    def build_hook_routes
      HookRoutes.new(
        event_routes: @event_routes,
        question_desk: -> { @question_desk },
        cancel_controller: -> { active_cancel_controller },
        steer: ->(text, source) { steer(text, source: source) },
        turn_author: -> { turn_author }
      )
    end
    private :build_hook_routes

    # The idle recap job (RecapSetup.build) under the current session's own
    # recap values, which it records.
    # @return [IdleRecap, nil]
    def build_recap
      @recap_built_for = session_recap_values
      recap = RecapSetup.build(@recap_kwarg, engine: self, host_registry: @host_registry,
                                             session_target: -> { session_model_recap_target },
                                             session_id: -> { @session&.id }, state_dir: -> { session_state_dir },
                                             session_config: -> { @session&.settings&.core })
      recap.awaiting_continue = @recap_awaiting_continue if recap && @recap_awaiting_continue
      recap
    end
    private :build_recap

    # One turn's lifecycle state, for #run_turn and its endings. Per turn
    # and single-threaded: the cross-thread turn state (the published
    # TurnContext, the cancel slot, the sink, steers) stays in TurnState.
    # +context+: the turn's TurnContext, the one source of truth for its
    # id, session, origin and controller (read through #id, #session,
    # #origin, #controller); #generate replaces it with the settings in.
    # +ended+: the end event is out (what follows is post-turn work).
    # +prepared_settings+: the LLM::TurnSettings #prepare_turn makes (before
    # the hooks); #generate completes them into the context's.
    # +limit+: the iteration limit #generate ran it with.
    # +resumed+: a step-limit Continue (run_turn's resumed:).
    # +resume_from+: where its reasoning starts, the run it resumes
    # (run_turn's resume_from:); nil for every other turn, and for a
    # Continue that starts cold (after a model change).
    # +wall+: the wall time it started (MessageTime.now, once): the
    # :turn_started event's at and its user message's (and reminders') stamp.
    # +verify+, +revises+: a Verify turn's claim, a Revise turn's draft.
    Turn = Struct.new(:context, :prompt, :continue, :on_event, :started_at, :messages, :ended, :prepared_settings,
                      :limit, :resumed, :resume_from, :wall, :verify, :revises, :outcome) do
      # The turn's id (:turn_started's turn_id, its metrics record's id and
      # its saved prompt's), session, origin and controller: its context's.
      def id = context.id
      def session = context.session
      def origin = context.origin
      def controller = context.controller

      def resumed? = resumed ? true : false

      # The turn ended as a completed one (not canceled, not failed): the
      # test the between-turns cards of it (an objectives proposal) use.
      def completed? = outcome == "completed"

      # The turn's boundary events carry the origin only when it names a
      # sender (not TurnOrigin::NONE), so payloads stay unchanged for callers
      # that don't pass one; as its wire Hash (TurnOrigin#to_h), which the
      # Bridge and the UIs read.
      def tag(event) = origin.empty? ? event : event.merge(origin: origin.to_h)

      # Seconds since the turn started (the cancel note says how long it ran).
      def elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      # The wall time's stamp text (MessageTime::KEY).
      def at = MessageTime.iso(wall)
    end
    private_constant :Turn

    # Run a single turn with event emission.
    #
    # Builds the system prompt + user messages, runs the kernel loop with
    # event forwarding, and returns its LLM::ModelResult.
    #
    # @param session  [Session] the session to operate on
    # @param prompt   [String] user input
    # @param on_event [Proc, nil] receives event hashes
    # @param max_iterations [Integer, nil] max kernel iterations (nil: IterationLimit.for)
    # @param cancel_controller [CancellationController, nil]
    # @param max_tool_output_chars [Integer, nil] per-output char cap on what
    #   the model gets back and the :tool_call_completed event's `output:`
    #   (nil → max_tool_output_chars)
    # @return [LLM::ModelResult]
    # @param pending_input [#call, nil] optional drain proc returning
    #   Array<String> of steering messages queued while the turn runs; drained
    #   by the agentic loop at iteration boundaries (see KernelLoop#run).
    # @param input_waiting [#call, nil] optional probe: true while a message
    #   a person sent waits for the next boundary (it peeks, never drains);
    #   a running task_wait or delegate wait returns on it, a running execute
    #   hands its command over (#input_waiting?). nil: never.
    # @param continue [Boolean] resume the conversation without appending a
    #   user prompt (continue after the iteration limit, reminder turns);
    #   +prompt+ is ignored and :turn_started carries `continue: true`
    # @param resumed [Boolean] a step-limit Continue (with continue:):
    #   :turn_started carries `resumed: true`, so do the before_turn payload
    #   and the turn's analytics record. false for every other continue (a
    #   reminder, a wake).
    # @param resume_from [Integer, nil] a step-limit Continue's: where the
    #   run it resumes started (ModelResult#run_start, kept in the offer by
    #   TurnFlow), so it keeps that run's reasoning; nil starts cold (a
    #   model change while the offer stood, every other turn).
    # @param origin [TurnOrigin, Hash, nil] who queued the turn (client_id,
    #   enqueued_id, and author when someone other than the session's owner
    #   wrote it, from its input file; none for the owner; a Hash is read as
    #   one, TurnOrigin.of; TurnOrigin::NONE, the default, names no sender
    #   and so does nil or {}); when it names one, the turn's boundary events
    #   (:turn_started, :turn_completed, :turn_canceled, :turn_failed) carry
    #   it as `origin:` (its wire Hash), and GuardrailWiring#begin_turn gets it
    # @param images [Array<Hash>] the prompt's images: {path:} (a file on this
    #   machine; in-process and attached-TUI callers only) or {file:, name:}
    #   (already in the session's images/, e.g. a web upload). They are
    #   stored/validated before :turn_started (which carries their refs), and
    #   a model known not to see images fails the turn before anything of it
    #   is kept (VisionUnsupported).
    # @param id [String, nil] the turn's id (a new uuid when nil): a caller
    #   that put the turn's first message in the session already (a context
    #   wake's note) names it with this id
    # @param verify [VerifyAnchor, nil] a Verify turn's claim (its verdict)
    # @param revises [ReviseAnchor, nil] a Revise turn's draft: stamped on
    #   the prompt at the turn's end, metadata only (TurnStages::VerifyAnchors#stamp_opening)
    #
    # An Interrupt (SIGINT) cancels the turn: what it got to is kept in the
    # session as after a Stop (the prompt, the loop's finished tool
    # iterations, a cancel note) and :turn_canceled is emitted, then the
    # Interrupt is re-raised so the caller still decides whether to exit. One
    # after the turn's end event (in its after_turn/session_end hooks) is
    # only re-raised: the turn already ended; so is any error there. Any
    # other error (e.g. an LLM::ProviderError) emits :turn_failed and
    # re-raises; a provider error adds error_kind:, retryable:, host: and a
    # one-line summary:.
    def run_turn(session, prompt, on_event: nil, max_iterations: nil, cancel_controller: nil, max_tool_output_chars: nil, pending_input: nil, continue: false,
                 origin: TurnOrigin::NONE, images: [], id: nil, resumed: false, resume_from: nil, verify: nil, revises: nil,
                 input_waiting: nil)
      turn = begin_turn(session, prompt, on_event: on_event, cancel_controller: cancel_controller, origin: origin,
                                         continue: continue, id: id, verify: verify, revises: revises,
                                         input_waiting: input_waiting)
      if continue
        turn.resumed = resumed
        turn.resume_from = resume_from
      end
      begin
        # A Stop cuts the /props probes this thread makes for the turn
        # (window, served model, vision) instead of waiting their timeout.
        probe_cancel_before = Client.swap_probe_cancel(turn.controller)
        return stopped_before_model(turn) unless prepare_turn(turn, continue ? [] : images)

        result = generate(turn, max_iterations: max_iterations, max_tool_output_chars: max_tool_output_chars,
                                pending_input: pending_input)
        publish_used_memories(session, on_event)
        complete_turn(turn, result)
        @turn_warmup.after(turn, result)
        result
      rescue Interrupt => e
        # After the end event (in the after_turn/session_end hooks) the
        # turn is over: no second ending, the answer stays.
        raise if turn.ended

        turn.controller.cancel!(:ctrl_c)
        end_turn(turn, "canceled") do |seconds|
          [ctrl_c_messages(turn, e, seconds), { type: :turn_canceled, cancellation_reason: :ctrl_c, duration_ms: (seconds * 1000).round }]
        end
        raise
      rescue StandardError => e
        # After the end event (post-turn work) likewise: logged and
        # re-raised, no turn_failed over the turn that ended.
        if turn.ended
          Log.warn(:turn, "post_turn_error", error: "#{e.class}: #{e.message}")
          raise
        end

        # Keep what the turn got to (the prompt plus the loop's completed
        # tool iterations) like a cancel does, and save it: a worker exits
        # after a failed turn.
        end_turn(turn, "failed", save: true) { |seconds| [failed_messages(turn, e), failed_event(e, seconds)] }
        raise
      ensure
        release_turn(probe_cancel_before)
        @context_judge.show_cards_after_turn
        # Only a completed turn shows its proposal cards; any other's are
        # dropped, so the next turn does not show them either.
        @objectives_stage.finally(turn)
      end
    end

    # The turn's state before anything can fail it: the session running,
    # its TurnContext, the turn flag, its cancel controller and sink. The
    # cross-thread state is set here and cleared in #release_turn only.
    def begin_turn(session, prompt, on_event:, cancel_controller:, origin:, continue:, id: nil, verify: nil, revises: nil,
                   input_waiting: nil)
      origin = TurnOrigin.of(origin)
      # A participant's Verify fresh child: every turn is theirs (their
      # author, boundary and cap), whoever started it.
      origin = session.verify_fresh.origin_for(origin) if session.respond_to?(:verify_fresh) && session.verify_fresh
      verify = @verify_anchors.verified(session, VerifyAnchor.from(verify), state_dir: session_state_dir)
      # Track the active session for recap and status snapshot.
      @session = session
      # status is turn state: running now, idle again before the turn's end
      # is announced, so a UI reacting to that event reads the new state.
      session.status = Session::STATUS_RUNNING
      @used_memories.absorb(session)
      # Provide a cancellable controller for this turn (cross-process cancel via file flag)
      effective_controller = cancel_controller || CancellationController.new
      # The turn's context, whole before the turn is published: who queued
      # it, a participant's mode (participants.json), git asked afresh.
      context = new_turn_context(session, origin, effective_controller, id || SecureRandom.uuid)
      # The turn runs, with its context, controller and sink, in one step:
      # a Stop, a plugin's card or its ctx.turn_author from another thread
      # never sees a running turn without them (or with the last turn's).
      # The idle recap detector does not fire (or render an invalidated
      # recap) while the model is working. A hook's notice goes where the
      # turn's events go (a one-shot prints only its sink; a worker's
      # observers carry it to the bridge).
      @turn_state.begin!(context: context, controller: effective_controller, sink: on_event, input_waiting: input_waiting)
      # Drop a recap already in flight: the turn makes it stale.
      @recap&.invalidate!

      Turn.new(context: context, prompt: continue ? nil : prompt, continue: continue, on_event: on_event,
               started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC), wall: MessageTime.now,
               verify: VerifyAnchor.from(verify), revises: ReviseAnchor.from(revises))
    end
    private :begin_turn

    # A new turn's TurnContext (#begin_turn): the gate's turn facts
    # (GuardrailWiring#begin_turn), the session's folders. Its settings and
    # model come in #generate.
    def new_turn_context(session, origin, controller, id)
      start = @guardrail_wiring.begin_turn(origin, session: session)
      TurnContext.new(id: id, session: session, origin: origin, author: origin.participant_author,
                      participant_mode: start.mode, participant: start.participant, controller: controller,
                      cwd: (session.working_directory if session.respond_to?(:working_directory)), session_dir: turn_session_dir(session),
                      state_dir: session_state_dir, git: start.git, settings: nil, model_key: nil,
                      fallback_model_key: nil, model_name: nil, surface: nil)
    end
    private :new_turn_context

    # The session's folder, nil when it can't be named (an id that isn't
    # one, a lookup that raised): a cut tool output then says it wasn't saved.
    def turn_session_dir(session)
      Session.session_dir(session.id, state_dir: session_state_dir)
    rescue StandardError => e
      Log.warn(:turn, "tool_output_save_failed", error: e.class.name)
      nil
    end
    private :turn_session_dir

    # The running turn's TurnContext as other threads see it (TurnState),
    # nil between turns; its settings are nil until #generate.
    # @return [TurnContext, nil]
    def turn_context = @turn_state.context
    private :turn_context

    # The last finished turn's TurnContext (TurnState#last_context), nil
    # before any: its author (the recap's), its settings (the working set's
    # between turns).
    # @return [TurnContext, nil]
    def last_turn_context = @turn_state.last_context
    private :last_turn_context

    # Everything before the model is asked: :turn_started, the kernel's
    # per-turn settings, the plugins' setup, the session_start/before_turn
    # hooks, then the messages to send (#turn_messages). False when a Stop
    # came before the hooks (the turn ends canceled there; before the
    # load-failure warnings when it came during the probes), else true.
    def prepare_turn(turn, images)
      session = turn.session
      image_refs, image_error = turn_image_refs(session, images)
      # Emit turn_started event
      bind_metrics(session)
      turn_started = { type: :turn_started, session_id: session.id, prompt: turn.prompt, turn_id: turn.id, at: turn.at }
      turn_started[:continue] = true if turn.continue
      turn_started[:resumed] = true if turn.resumed?
      turn_started[:images] = image_refs unless image_refs.empty?
      turn_started[:cut_after] = steer_cut_after
      # A participant's turn names them (author, author_name) for the UIs'
      # badge; the owner's turn_started stays as it was.
      turn_started.merge!(author_fields(turn.origin.author, session: session),
                          participant_mode_fields(turn.context))
      emit_event(turn.on_event, turn.tag(turn_started))
      raise image_error if image_error

      # On mode's ask starts here too; the turn joins it before
      # apply_toolkit! below, so its latency hides behind the probes and
      # the init wait.
      @toolkit_suggestion.start(turn, recorder: system_one_recorder)

      # The window and the profile probes run after run_turn's probe-cancel
      # swap, so a Stop cuts them; a failure ends the turn as turn_failed.
      # The cache itself was dropped at the previous turn's end, so this
      # turn's first probe asks the server (a restart with another -c
      # between turns is noticed), and the answer the session's prompt build
      # read for its profile (a first turn) is what this turn starts from:
      # one GET /props per turn, not two.
      refresh_profile!

      # Before anything of the turn is kept or a reminder is used up.
      turn.prepared_settings = turn_settings(session)
      refuse_images!(turn.prepared_settings.vision) unless image_refs.empty?
      # A Stop during the probes: the turn ends before the load-failure
      # warnings, which show once, so the next turn still shows them.
      if turn.controller.cancelled?
        @toolkit_suggestion.abandon(turn, :canceled)
        return false
      end

      announce_guardrail_failures(turn.on_event)
      # Plugins' slow setup that brings tools (an MCP server's first
      # start): the turn waits for it here, before the system prompt
      # declares the tools; a Ctrl-C ends the wait (the turn is cancelled
      # at its first request).
      start_init_tasks!
      await_init_tasks(turn.controller, turn.on_event)
      # Plugins' tool sets that changed since the last turn, then the
      # session's toolkit (a /toolkit change since the last turn): what the
      # prompt built next declares, unchanged until the next turn's start.
      apply_staged_tools!
      # On mode: the suggested kit, before anything is declared (a Stop
      # during the wait is caught by the check below).
      @toolkit_suggestion.settle(turn)
      # The candidate judge: its asks run beside the turn; on mode's
      # attaches reach the model at the next between-turn delivery.
      @context_judge.start(turn)
      @objectives_stage.incoming(turn)
      apply_toolkit!(session, turn.on_event)
      refresh_participants!(session)
      # A Stop during the waits above: the turn ends here,
      # before the hooks run or a reminder is used up.
      return false if turn.controller.cancelled?

      # Fire :session_start on the very first turn
      if @first_turn
        @hooks.fire(:session_start, { type: :session_start, session_id: session.id })
        @first_turn = false
      end

      # Fire :before_turn hook, with a read-only copy of the history so far
      # and the prompt (nil on a continue); resumed: a step-limit Continue.
      @hooks.fire(:before_turn, { type: :before_turn, session_id: session.id, prompt: turn.prompt,
                                  resumed: turn.resumed?, messages: hook_messages(session.messages) })

      turn_messages(turn, image_refs)
      true
    ensure
      # A turn that ended (a failure, an Interrupt) before it settled the
      # ask: its line says so. Nothing once it was settled.
      @toolkit_suggestion.abandon(turn, :failed)
      @toolkit_suggestion.finish(turn)
    end
    private :prepare_turn

    # The messages the turn sends: the history under the system head, due
    # reminders, the prompt. turn.messages is set first and grown in place,
    # so a Ctrl-C or a failure meanwhile keeps what is there.
    def turn_messages(turn, image_refs)
      session = turn.session
      turn.messages = session.messages.dup
      # Built once per Engine (and again after a model switch) so the prompt
      # prefix, and the model server's KV cache for it, stay stable.
      turn.messages = ContextNote.with_system_head(turn.messages, { role: "system", content: system_prompt })
      # Explicit --memory preloads are now known after system prompt build.
      @used_memories.add(activated_memory_names).absorb(session)

      # Inject due reminders as a tail system message (after history, before
      # the new user prompt) to preserve prefix KV cache. Mutating the head
      # system prompt invalidates cache for the entire prefix.
      # Not into a participant's turn: the owner's reminders are the owner's,
      # and would be used up there under the review boundary.
      due_reminders = turn.origin.participant? ? [] : @reminder_queue.inject!(turn.messages, now: turn.wall)
      if due_reminders.any?
        emit_event(turn.on_event, {
          type: :reminder_injected,
          reminders: due_reminders,
          at: turn.at
        })
      end

      unless turn.continue
        user_message = { role: "user", content: turn.prompt, turn_id: turn.id, **author_fields(turn.origin.author),
                         **participant_mode_fields(turn.context), MessageTime::KEY => turn.at }
        user_message[:verify] = turn.verify.to_h if turn.verify
        user_message[:images] = image_refs unless image_refs.empty?
        turn.messages << user_message
        session.last_prompt = turn.prompt
      end
      append_tool_loads(turn)
    end
    private :turn_messages

    # Ask the effective model's backend.
    def generate(turn, max_iterations:, max_tool_output_chars:, pending_input:)
      # One resolve for the request: nothing runs between these reads that
      # could change what a resolve gives (the hooks ran before).
      model = effective_model
      sync_kernel_client!(model)
      # Route model name as bare (without host prefix) to the server;
      # host selection already done via active client.
      bare_for_backend = bare_model_name(model.name)
      # The turn's settings, set once here into its context (with the model
      # key and name the gate and memory_read use: frozen now, after the
      # hooks that may switch the model), which goes down the backend's
      # complete to every tool call, and is published (TurnState).
      explained = model.llm_context_explained(@model_settings.llm_context_session_args)
      model_backend = backend(model)
      # A host that loads tools runs a direct call of one the session
      # reaches but doesn't declare (ToolRunner, KernelLoop#dispatch).
      loads_tools = model_backend.respond_to?(:loads_tools?) && model_backend.loads_tools?(bare_for_backend)
      settings = turn.prepared_settings.with(model_name: bare_for_backend, window_setting: model.window_setting,
                                             llm_context: explained&.resolved, price: model.price,
                                             loads_tools: loads_tools)
      # The turn's tools (Tools::ToolSurface), built once from the Registry
      # under those settings' layers and loads_tools: what the loops declare,
      # defer and dispatch until the turn ends; a change meanwhile (a
      # /toolkit change, a staged chi.replace_tools) is the next turn's.
      surface = Tools::ToolSurface.for(@tools, layers: settings.llm_context&.active_layers || [],
                                               loads_tools: loads_tools)
      turn.context = turn.context.with(settings: settings, model_key: @model_binding.model_key,
                                       fallback_model_key: @model_binding.fallback_model_key,
                                       model_name: guardrail_model_name, surface: surface)
      @turn_state.replace_context(turn.context)
      log_llm_context(explained)

      turn.limit = @no_interrupt ? IterationLimit.for(no_interrupt: true) : max_iterations || IterationLimit.for
      # Where this run starts (ChatLoop::Run's start): an offer made at its
      # end keeps it, so a Continue resumes this run.
      run_start = turn.messages.length
      reasoning_since = resumed_run_start(turn, run_start)
      result = model_backend.complete(
        messages: turn.messages,
        max_iterations: turn.limit,
        on_stream_event: build_stream_event_handler(turn.on_event, cancel_controller: turn.controller,
                                                    model_ref: generation_model_ref(model)),
        cancel_controller: turn.controller,
        model_name: bare_for_backend,
        max_tool_output_chars: max_tool_output_chars,
        pending_input: turn_drain(pending_input),
        reasoning_since: reasoning_since,
        context: turn.context
      )
      result.run_start = run_start
      result
    end
    private :generate

    private

    def running_command_key = :"samagotchi_command_#{object_id}"

    # The one named seam for replacing a session's conversation (the
    # array is replaced, never mutated in place). No lock: a reader gets
    # the old array or the new one, and both are whole.
    # The turn as other threads see it (TurnState).
    attr_reader :turn_state
    # The due reminders on their way into a turn (ReminderQueue).
    attr_reader :reminder_queue

    def replace_session_messages(session, messages)
      session.messages = messages
    end

    # Bundles' judgments (chi.judgment), on this Engine's Runs and side asks.
    # A judgment's own host and model are for bundles only: core's clients
    # (#system_one_recording's, engine/side_requests.rb) never pass them (D2,
    # JudgmentSettings).
    def build_judgments
      SystemOne::Judgments.new(
        client_for: lambda { |_name, settings|
          SystemOne::Client.from_config(host_registry: @host_registry, mode: settings.mode, host: settings.host,
                                        model: settings.client_model, tag: :plugins)
        },
        runs: -> { @session&.scratch ? SystemOne::Runs.new : system_one_runs },
        where: -> { @session && SystemOne::Recording::Context.of(@session, session_model: effective_model_name) },
        side: @side_judgments,
        participant: -> { !turn_author.nil? }
      )
    end
    private :build_judgments

    # The session's toolkit (see #initialize for when).
    def build_toolkit_binding
      ToolkitBinding.new(
        tools: -> { @tools },
        session: -> { @session },
        state_dir: -> { session_state_dir },
        can_stage: -> { !turn_running? && !history? },
        reset_prompt: -> { @prompt_builder&.reset! },
        refresh_index: -> { @tool_index.refresh! },
        emit: ->(sink, event) { emit_event(sink, event) },
        notify: ->(text, level, source, extra:) { hook_notify(text, level, source, extra: extra) }
      )
    end
    private :build_toolkit_binding

    # Build the idle reminders job. Always created (reminders are opt-in
    # via the agent calling register_reminder). The shared IdleScheduler
    # polls it and triggers synthetic turns when reminders are due.
    #
    # @param auto_turn_callback [Proc, nil] called when a reminder is due;
    #   receives the due reminder names; responsible for triggering a synthetic
    #   turn (e.g. SessionManager writes a file, TerminalUI queues input).
    def build_reminders(auto_turn_callback: nil)
      @auto_turn_callback = auto_turn_callback
      IdleReminders.new(
        engine: self,
        queue: @reminder_queue,
        callback: @auto_turn_callback
      )
    end
  end
end
