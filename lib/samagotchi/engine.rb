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
require_relative "peer_sources"
require_relative "session_commands"
require_relative "plugin/loader"
require_relative "plugin/card"
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

module Samagotchi
  # Engine owns the core agent logic: system prompt construction, tool
  # declarations, session lifecycle, and the model↔tool loop.
  #
  # It exposes an event-based API (`on_event`) so that any UI can run
  # turns without coupling to terminal rendering.
  class Engine
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
      @host_registry = host_registry || HostRegistry.new
      # A model given here (a worker's session model) is the one it runs,
      # so its host is checked; the config default is only checked once it
      # is used (the REPL checks the model it starts on, #switch_model!).
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
      Log.debug(:model, "backend", provider: backend.provider) if Log.level?(:debug)
      @resume_session = session_id ? Session.load(session_id) : nil
      @prompt_builder = build_system_prompt(memories, appended_prompt_files)
      # The session's participants (participants.json), read at each turn's
      # start: their names for the messages they wrote.
      @participants = SessionParticipants.new(state_dir: -> { session_state_dir })
      # Whether the system prompt carries the participants line.
      @participants_line = false
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
      # single seam every UI calls (run_turn itself, the REPL on keystrokes
      # and after a reminder turn), so the idle layer's clock is identical
      # across UIs.
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
      @extension_load = ExtensionLoad.new(hook_failures: @guardrail_failures)
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
      # The tools plugins publish without declaring (chi.tool_source), and
      # the search and call tools that reach them (Tools::ToolIndex).
      @tool_index = Tools::ToolIndex.new
      # The tools plugins load (ctx.load_tools), staged until a turn's
      # messages are built (#append_tool_loads).
      @tool_loads = ToolLoads.new
      # The context sources the peer bundles declare as a peer agent's
      # answers (chi.peer_source); the worker's ContextAbsorber asks it.
      @peer_sources = PeerSources.new
      load_plugins if load
      # Registered from what the sources published while they loaded, and
      # with no plugins too: a toolkit's left-out built-ins are reachable
      # either way (declared per toolkit, Tools::Registry).
      @tool_index.declare(@tools, failures: @plugin_failures)
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
      # (the REPL, -p/--non-interactive/--resume and SessionManager workers)
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

    # The kernel and what it holds of the Engine (stores, hooks, tools, the
    # mutes, the question flow, the gate, peers, warm-up, the hook runtime),
    # and the native backend over it. After the plugins load.
    def wire_kernel(kernel, muted_memories)
      # A given kernel (specs) gets the Engine's store, hooks and tools, as
      # the one built here does.
      @kernel = kernel || KernelLoop.new(client: @client, profile: @model_binding.given_profile, model_name: effective_model_name,
                                         hooks: @hooks, reminder_store: @reminder_store, tools: @tools)
      @kernel.reminder_store = @reminder_store
      @kernel.hooks = @hooks
      @kernel.tools = @tools
      sync_kernel_client!
      sync_model_key!
      # The mutes never change during a session, so no re-sync: the kernel's
      # memory_read guard reads the same list for every turn.
      @muted_memory_names = MutedMemories.normalize_list(muted_memories)
      @kernel.muted_memory_names = @muted_memory_names
      # ask_user_question blocks on the Engine's question flow (TUI/Web answer it).
      @kernel.question_handler = proc { |payload| request_question(payload) }
      # Every tool call asks this gate first. The kernel is never rebuilt, so
      # it holds across model switches.
      self.guardrail_state_dir = Session.default_state_dir
      # list_sessions and send_note speak for whichever session runs now.
      @kernel.peers = PeerView.new(self)
      # A plugin tool's row refs resolve against the session's folder, as
      # answer refs do (AnswerRefs), not the process's.
      @kernel.session_cwd = -> { @session&.working_directory }
      # forget_outputs refuses what the user pinned in the working set.
      @kernel.working_set_pins = -> { @session&.working_set_pins || [] }
      # A cut tool output is saved whole in the session's folder.
      @kernel.session_dir = -> { @session&.id && Session.session_dir(@session.id, state_dir: session_state_dir) }
      @kernel.guardrail_gate = @guardrail_wiring.gate
      # The turn-end warm-up; the kernel asks it for a slot pin per request.
      @prompt_warmup = PromptWarmup.new
      @kernel.warmup = @prompt_warmup
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
        hooks: -> { @hooks },
        tools: -> { @tools },
        session: -> { @session },
        model_key: -> { @model_binding.model_key },
        model_name: -> { guardrail_model_name },
        cancelled: -> { !!active_cancel_controller&.cancelled? },
        # An approval of the model's call: :question_asked first (QuestionAsked).
        ask: ->(fields) { open_question(question_asked(QuestionAsked::KIND_APPROVAL, fields)) },
        notify: ->(message) { guardrail_notify(message) }
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
        kernel: -> { @kernel },
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
                       participants: -> { @participants_line })
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

    # The backend for the next turn: the loop the effective model's host speaks.
    def backend(model = effective_model)
      backend_for(model)
    end

    # Record that activity happened (user input or a completed turn): the
    # idle jobs' seam (TurnState#record_activity). Each call advances both
    # the last-activity timestamp and the activity sequence.
    # @param now [Float, nil] injectable monotonic time (defaults to now)
    def record_activity(now = nil)
      @turn_state.record_activity(now)
    end

    # @return [Float] monotonic seconds of the last recorded activity
    def last_activity_at
      @turn_state.last_activity_at
    end

    # @return [Integer] monotonically-increasing activity counter (advanced by
    #   #record_activity; lets the idle detector summarize once per idle window)
    def activity_seq
      @turn_state.activity_seq
    end

    # @return [Boolean] true while a turn is in flight (the idle jobs never
    #   fire, nor render, while the model is generating)
    def turn_running?
      @turn_state.running?
    end

    # Put +text+ into the running turn, as a UI's steering does: it joins the
    # conversation at the loop's next iteration boundary as its own user
    # message (kind: "steer", source:). Callable from any thread; never
    # blocks. With no turn running it does nothing (it never starts one).
    # True means queued, not merged: at the after-answer boundary, and when
    # the turn ends first, it is dropped (logged).
    # @return [Boolean] whether it was queued
    def steer(text, source:)
      @turn_state.steer(text, source: source)
    end

    # A message for the running turn from +source+ cuts the generation
    # streaming only thinking (SteerCut#cut_for_steer). Call it after the
    # message is queued, with the #input_epoch read before queueing it.
    # @return [Boolean] whether a generation was cut now
    def cut_for_steer(source, epoch: nil) = @steer_cut.cut_for_steer(source, epoch: epoch)

    # The drains that took input so far: read it before queueing a message
    # for #cut_for_steer.
    def input_epoch = @steer_cut.input_epoch

    # The running generation's phase (SteerCut#generation_snapshot): what
    # Bridge#snapshot puts in current_turn.generation.
    def generation_snapshot = @steer_cut.generation_snapshot

    # Like #steer, for the turn that begins next (a continue turn answered
    # with a text): it joins that turn at its first boundary. Callable from
    # any thread; a turn that never begins keeps it for the next one, unless
    # #drop_carried_steers drops it.
    # @return [Boolean] whether it was queued (false: blank)
    def steer_next_turn(text, source:)
      @turn_state.steer_next_turn(text, source: source)
    end

    # Drop the #steer_next_turn steers no turn began with (the continue turn
    # failed before it began), logged; a no-op once a turn took them.
    def drop_carried_steers
      log_dropped_steers(@turn_state.drop_carried_steers, "not_begun")
    end

    # The drain a turn's loop gets: the caller's lines (a UI's steering; nil
    # in a --non-interactive run) and the plugin steers. At the after-answer
    # boundary the steers are dropped: the model answered, and a nudge would
    # only restart the turn. The steer part fails on its own, never taking
    # the user's lines with it. Items are a String (a user line), a
    # Steer::Line (a worker's input line with its sender) or a steer Hash.
    def turn_drain(pending_input)
      lambda do |at_answer: false|
        lines = pending_input ? Array(pending_input.call) : []
        # The input went to the model: a message that waited to cut is in.
        @steer_cut.delivered! unless lines.empty?
        lines + take_steers(at_answer)
      end
    end
    private :turn_drain

    def take_steers(drop)
      steers = @turn_state.take_steers
      return steers unless drop

      log_dropped_steers(steers, "answered")
      []
    rescue StandardError => e
      Log.warn(:turn, "take_steers_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      []
    end
    private :take_steers

    def log_dropped_steers(steers, why)
      steers.each { |steer| Log.info(:turn, "steer_dropped", source: steer[:source], why: why, chars: steer[:text].length) }
    end
    private :log_dropped_steers

    # @return [Array<String>] reminder names queued for a synthetic REPL turn
    def due_reminder_names
      @reminder_queue.pending_names
    end

    # Queue reminder names for a synthetic REPL turn (IdleReminders callback).
    def note_due_reminders(names)
      @reminder_queue.note_pending(names)
    end

    def clear_due_reminder_names!
      @reminder_queue.clear_pending!
    end

    # @return [CancellationController, nil] active turn's cancellation controller
    def active_cancel_controller
      @turn_state.controller
    end

    # Cancel the currently running turn, if any.
    # @param reason [Symbol] cancellation reason
    # @return [Boolean] whether a cancellation was triggered
    def cancel_current_turn!(reason = :manual)
      @turn_state.cancel!(reason)
    end

    # Snapshot the current session messages as a JSON string for the idle
    # recap. The array is never mutated in place (a turn or a note replaces
    # it), so the reference read here is a consistent snapshot; a dup'd
    # copy is serialized. Never mutates session.messages.
    # @return [String] JSON array of the messages
    def messages_json_for_recap
      snapshot = @session&.messages
      return "[]" if snapshot.nil?

      JSON.generate(AnswerDisplay.strip_all(snapshot).map(&:dup))
    end

    # Emit a :recap_ready event (additive slot) carrying the generated recap
    # and the generation id an observer uses to reject an invalidated recap.
    # +covered+ counts the session messages it summarizes; +created_at+ is
    # the saved recap's (UTC ISO; the UIs show its local time).
    def emit_recap(recap:, generation:, covered: nil, created_at: nil)
      event = { type: :recap_ready, recap: recap, generation: generation, covered: covered }
      event[:created_at] = created_at if created_at
      @session_observer.notify(event)
    end

    # Count one side request (a recap, a plugin's ctx.ask_model: IdleClient's
    # on_usage) in the session's side line, apart from its turns' totals.
    # Folded and announced as :side_usage under the event lock, so the side
    # blocks reach the UIs in fold order (the lock order event lock →
    # metrics mutex is the existing one); then, between turns, saved to
    # analytics.json (a running turn's end or checkpoint saves it), unless
    # the session is gone (no session file: a late recap thread must not
    # recreate a deleted session's folder; the folder itself may not exist
    # yet before a first turn). Safe from any thread: the recap's, a
    # plugin's, the turn's.
    # A side request counts against the participant who caused it
    # (#side_author), its usage's own author when it names one.
    # @param usage [SideUsage]
    # @return [void]
    def note_side_usage(usage)
      usage = usage.with(author: side_author(usage.kind)) if usage.author.nil?
      synchronize_events do
        block = @metrics.add_side(usage)
        @session_observer.notify(type: :side_usage, kind: usage.kind, side: block)
      end
      sid = @metrics.session_id
      return if sid.nil? || turn_running?
      return unless File.exist?(Session.session_file(sid, state_dir: session_state_dir))

      @metrics.persist(state_dir: session_state_dir)
    end

    # Who caused a side request of +kind+ now: the running turn's author (a
    # plugin's ctx.ask_model in it), the last turn's for the idle recap
    # (it recaps that turn); nil, the owner's, for anything else (an owner
    # command's ask_model between turns).
    # @return [String, nil]
    def side_author(kind)
      return nil unless turn_running? || kind.to_s == RECAP_SIDE_KIND

      @guardrail_wiring.turn_author
    end

    RECAP_SIDE_KIND = "recap"

    # The running turn's author when a participant wrote it, else nil
    # (ctx.turn_author, the hooks' author).
    # @return [String, nil]
    def turn_author = turn_running? ? @guardrail_wiring.turn_author : nil

    # @return [SessionMetrics] the per-session analytics collector
    attr_reader :metrics

    # The model as given (maybe an alias; HostRegistry#resolve applies it).
    def effective_model_name = @model_binding.choice.name

    # The model as typed at start or at the last /model.
    def typed_model_name = @model_binding.choice.typed

    # The resolved ref a session stores for the effective model (ModelRef#ref:
    # the alias applied, "host:id" when it names a host).
    def effective_model_ref
      model_ref_for(effective_model_name)
    end

    # The effective model as the system prompt names it (SystemPrompt::ModelIdentity):
    # the ref, its host, the overlay key and, for a local llama.cpp host
    # only, the model its /props names when that differs. Never a new
    # request: only the /props answer profile resolution already cached.
    def model_identity
      model = effective_model
      entry = model.entry
      host = entry && "host #{entry.name}, #{entry.url || "#{entry.host}:#{entry.port}"}"
      SystemPrompt::ModelIdentity.new(ref: model.ref, host: host, key: @model_binding.model_key,
                                      served: model.prompt_served, fallback_key: @model_binding.fallback_model_key)
    end

    # The model notes for the effective model (ModelNotes): matched on its
    # bare id and key, the session's mutes left out.
    # @return [Array<ModelNotes::Note>]
    def model_notes
      ModelNotes.for(name: guardrail_model_name, key: @model_binding.model_key, fallback_key: @model_binding.fallback_model_key,
                     muted: @muted_memory_names)
    end

    # The model notes the session's prompt carried at its last build
    # (Session#prompt_notes): a resumed session's or a woken worker's saved
    # ones until this process builds its prompt; a fresh session (no build
    # yet, no messages) has none saved, so the effective model's prompt
    # would load them: the notes #model_notes names, as without a session.
    # The three readers (/model, /stats, the web) share this.
    # @return [Array<PromptNote>]
    def prompt_notes
      return model_notes.map { |note| PromptNote.from_note(note) } unless @session

      saved = @session.prompt_notes
      return saved.dup if !@prompt_builder.prompt_notes.nil? || !saved.empty? || @session.messages.to_a.any?

      model_notes.map { |note| PromptNote.from_note(note) }
    rescue StandardError => e
      Log.warn(:model, "prompt_notes_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      []
    end

    # Records +notes+ (ModelNotes::Note) on the session as the ones its
    # prompt carries; saved with it.
    def record_prompt_notes(notes)
      @session.prompt_notes = Array(notes).map { |note| PromptNote.from_note(note) } if @session && notes
    end
    private :record_prompt_notes

    # A failed turn's one line (the error's #summary). A host's failure
    # under an alias says what the alias became (HostRegistry#alias_note):
    # "host main" alone doesn't tell --model splash's user it was splash.
    # @return [String]
    def failure_summary(error)
      summary = error.respond_to?(:summary) ? error.summary : error.message
      return summary unless error.is_a?(LLM::ProviderError) && error.host

      note = @host_registry.alias_note(effective_model_name)
      note && note.end_with?("on host #{error.host}") ? "#{summary} (#{note})" : summary
    rescue StandardError => e
      EffectiveModel::Unresolved.fallback(:alias_note_failed, effective_model_name, e, summary)
    end

    # +name+'s resolved ref (ModelRef#ref).
    def model_ref_for(name)
      @host_registry.model_ref(name).ref
    end

    # Writes the effective model to +session+: the resolved ref, and the
    # name as typed when that differs (model_typed: an alias, for the
    # models: lookup after a resume).
    def store_model!(session)
      ref = effective_model_ref
      session.model_name = ref
      typed = typed_model_name
      session.model_typed = typed.to_s == ref ? nil : typed
      session
    end

    # The effective model's key (ModelOverlay.key_for its bare name): memory
    # overlays, guardrail rules' models:.
    # @return [String, nil]
    def model_key = @model_binding.model_key

    # The prompt profile for the effective model (see #profile_resolution).
    # @return [ModelProfile]
    def profile = profile_resolution.profile

    # Which profile the effective model gets and where that came from,
    # kept with the model choice it was resolved for
    # (ModelBinding#profile_resolution).
    # @return [ModelProfile::Resolution]
    def profile_resolution = @model_binding.profile_resolution
    attr_reader :default_model_name, :host_registry, :client

    # @return [Commands::Registry] the commands this session runs: the
    #   built-ins, and the ones bundle plugins add
    attr_reader :command_registry

    # @return [PeerSources] the sources the peer bundles declared
    attr_reader :peer_sources

    # The model id sent for +full_ref+ (its alias applied, the host prefix off).
    def bare_model_name(full_ref)
      @host_registry.bare_name(full_ref)
    end

    # The memory overlay keys follow the model sent (ModelBinding#sync_model_key!).
    def sync_model_key! = @model_binding.sync_model_key!
    private :sync_model_key!

    # The effective model's bare name for the guardrails' models: rules;
    # nil without a model name.
    def guardrail_model_name
      model = effective_model_name
      name = model && bare_model_name(model)
      name.to_s.strip.empty? ? nil : name
    end

    # Point the kernel (and a chat backend) at the effective model's host
    # (after /model, --model, resume).
    def sync_kernel_client!(model = effective_model)
      @client = model.client
      @kernel.client = model.client if @kernel.client != model.client
      backend_for(model)
    end

    # Subscribe a persistent observer to engine events.
    #
    # Unlike the turn-scoped `on_event:` sink, a subscribed observer keeps
    # receiving events across every `run_turn` call on this Engine. Each
    # delivery carries a locally-monotonic `event_seq`. The returned handle can
    # be used to unsubscribe later.
    # @param observer [#call] receives event hashes (with `event_seq:` merged in)
    # @return [Samagotchi::SessionObserver::SubscribedObserver] handle to unsubscribe
    def subscribe(observer:)
      @session_observer.subscribe(observer: observer)
    end

    # Unsubscribe a previously-registered observer.
    # @param handle [Samagotchi::SessionObserver::SubscribedObserver]
    # @return [Boolean] whether the observer was removed (nil/unknown never raises)
    def unsubscribe(handle:)
      @session_observer.unsubscribe(handle: handle)
    end

    # @return [Integer] total engine events emitted so far (locally monotonic)
    def event_count
      @session_observer.event_count
    end

    # Event types #announce accepts: facts about the session's input queue,
    # a failed turn's prompt handed back and the continue offer, which live
    # UIs need in the event log, emitted outside any turn's stream.
    ANNOUNCEABLE_EVENTS = %i[turn_enqueued turn_dequeued input_merged prompt_restored continue_offered continue_resolved
                             command_queued command_ran context_added card hook_notice guardrail_warning
                             plugin_init_started plugin_init_finished working_set_updated participants_changed].freeze

    # Put a transport-level event into the ordered event log. Unlike turn
    # events it reaches only persistent observers (no turn sink, no memory
    # capture).
    # @param event [Hash] with :type in ANNOUNCEABLE_EVENTS
    # @raise [ArgumentError] for any other type
    def announce(event)
      unless ANNOUNCEABLE_EVENTS.include?(event[:type])
        raise ArgumentError, "cannot announce #{event[:type].inspect} (allowed: #{ANNOUNCEABLE_EVENTS.join(", ")})"
      end

      @session_observer.notify(event)
    end

    # Run the block with the event log held: no event is numbered or
    # delivered meanwhile, and events the block emits keep their order.
    def synchronize_events(&)
      @session_observer.synchronize(&)
    end

    # The working set's :working_set_updated, announced between turns
    # (after a command changed what the next request sends), when it
    # differs from the last one emitted (#emit_working_set). Under the
    # event lock, so it is ordered with the change's own events.
    def announce_working_set(session = @session)
      return unless session

      synchronize_events { emit_working_set(nil, session, session.messages) }
    end

    # The strategy the working set is built under now, as LLMContextView
    # takes it: the running turn's, else the next turn's (#emit_working_set).
    # /working-set's ops act under it.
    # @return [Symbol, Array<Symbol>]
    def working_set_strategy
      working_set_llm_context&.strategy || LLMContextView::NONE
    end

    # Replace the current session's conversation, between turns (a
    # /working-set op's copy: #clone_messages, then its edits).
    # @param messages [Array<Hash>]
    # @return [Array<Hash>] the session's messages
    def replace_messages(messages)
      raise ArgumentError, "no current session" unless @session

      replace_session_messages(@session, messages)
    end

    # Add a context note to the session's conversation, between turns: a
    # tail system message the next turn sees, announced as :context_added.
    # The array is replaced, not mutated, and the append and the event
    # happen under the event lock, so a joining UI sees both or neither.
    # The caller saves the session.
    # @param note [Hash] SessionInbox.read_note's shape
    # @return [Hash, nil] the message, or nil when the conversation already
    #   holds this note (a note file re-read after a crash)
    def add_context_note(session, note)
      synchronize_events do
        next nil if Array(session.messages).any? { |m| m[:note_id] == note[:note_id] }

        message = ContextNote.message(**note)
        replace_session_messages(session, Array(session.messages) + [message])
        announce({ type: :context_added, session_id: session.id, note_id: note[:note_id], source: note[:source],
                   label: ContextNote.label_of(message), from_session: note[:from_session],
                   from_cwd: note[:from_cwd], text: note[:text], context_source: note[:context_source],
                   created_at: note[:created_at] }.compact)
        message
      end
    end

    # ── Cards ───────────────────────────────────────────────────────────────

    # Show a card in every UI (docs/plugins.md, Cards): {type: :card, id:,
    # source:, title:, body:, level:, actions: [{label:, command:}], in_turn:}.
    # Where it goes (held while the plugins load, an anytime command's, an
    # init task's, a turn event, else announced) is EventRoutes#route's,
    # marked in_turn: (CARD_MARKS). A card with the id of an earlier one
    # replaces it (btw's "thinking…" → the answer).
    # @param source [String] who shows it (a bundle's name)
    # @param actions [Array<Hash>] {label:, command:}; a command is a line
    #   the session runs, as typed (D3)
    # @return [String] the card's id
    # @raise [ArgumentError] a card without a title, or a bad action
    def show_card(source:, title:, body: "", actions: [], level: :info, id: nil)
      card = Plugin::Card.build(source: source, title: title, body: body, actions: actions, level: level, id: id)
      @event_routes.route(card, **EventRoutes::CARD_MARKS)
      card[:id]
    end

    # Run an anytime command's block (D8): the cards and notices it shows on
    # this thread are announced at once, marked anytime: true, and are
    # never a running turn's events. They belong to the command, not the
    # turn, and a UI shows them after the command's own line (a web
    # command bubble drawn at its command_queued), even mid-turn.
    # @return the block's value
    def running_anytime
      key = :"samagotchi_anytime_#{object_id}"
      outer = Thread.current[key]
      Thread.current[key] = true
      yield
    ensure
      Thread.current[key] = outer
    end

    # Whether an anytime command (/btw) still runs on its thread.
    def anytime_running?
      @lifecycle_mutex.synchronize { @anytime_threads.any?(&:alive?) }
    end

    # Start an anytime command on its own thread (D8), one #shutdown waits
    # for, so its command_ran is announced before the process leaves.
    # @return [Thread]
    def spawn_anytime(&)
      thread = Thread.new(&)
      @lifecycle_mutex.synchronize do
        @anytime_threads.select!(&:alive?)
        @anytime_threads << thread
      end
      thread
    end

    # ── Plugin init tasks (chi.init) ──────────────────────────────────────

    # A plugin's slow setup (docs/plugins.md, Init tasks): PluginTasks.
    InitTask = PluginTasks::InitTask
    INIT_TASK_TIMEOUT = PluginTasks::INIT_TASK_TIMEOUT
    INIT_WAIT_POLL = PluginTasks::INIT_WAIT_POLL

    # Add a plugin's init task (Plugin::Api#init at commit); it starts with
    # #start_init_tasks!.
    def add_init_task(bundle:, label:, plugin_label:, provides_tools:, quiet:, timeout:, failed: nil, &)
      @plugin_tasks.add(bundle: bundle, label: label, plugin_label: plugin_label, provides_tools: provides_tools,
                        quiet: quiet, timeout: timeout, failed: failed, &)
    end

    # Start the init tasks not started yet, each on its own thread
    # (PluginTasks#start!).
    def start_init_tasks!
      @plugin_tasks.start!
    end

    # The running init tasks a UI shows (not the quiet ones), for a UI that
    # joins while they run (Bridge#snapshot, with the event log held).
    # @return [Array<Hash>] {bundle:, id:, label:}
    def init_tasks
      @plugin_tasks.running
    end

    # Wait for the running init tasks that provide tools (PluginTasks#await).
    # @return [Boolean] whether it waited
    def await_init_tasks(controller = nil, on_event = nil)
      @plugin_tasks.await(controller, on_event)
    end

    # The init task this thread runs, or nil.
    def current_init_task = @plugin_tasks.current
    private :current_init_task

    # ── Load events ───────────────────────────────────────────────────────

    # Announce what failed to load and what plugins showed while loading,
    # once, as soon as the owner can show it (the worker's Bridge is up, the
    # REPL renders events): the guardrail and plugin warnings, an orphaned
    # project memory folder (label: "memory", MemoryOrphans), then the
    # held notices (between_turns) and cards (in_turn: false, so late
    # joiners get them). Without this call the first turn announces them
    # (#announce_guardrail_failures).
    def announce_load_events!
      synchronize_events do
        next if @guardrail_failures_announced

        @guardrail_failures_announced = true
        message = @guardrail_failures.message
        announce({ type: :guardrail_warning, message: message }) if message
        plugins = @plugin_failures.message
        announce({ type: :guardrail_warning, message: plugins, label: "plugins" }) if plugins
        memory = MemoryOrphans.message
        announce({ type: :guardrail_warning, message: memory, label: "memory" }) if memory
        @extension_load.held_events.each do |event|
          announce(event[:type] == :card ? event.merge(in_turn: false) : event.merge(between_turns: true))
        end
      end
      nil
    end

    # How long #shutdown waits for the running anytime commands, in all.
    SHUTDOWN_JOIN_SECONDS = 3.0

    # The REPL or the session's worker is leaving (/exit, an idle exit, a
    # crash, TERM): stop the idle jobs, give the running anytime commands
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
      left = threads.count(&:alive?)
      Log.warn(:plugins, "anytime_commands_left", count: left) if left.positive?
      @plugin_tasks.kill_leftovers
      @services.stop_all
      self
    end

    def anytime_thread? = Thread.current[:"samagotchi_anytime_#{object_id}"] == true
    private :anytime_thread?

    def announce_anytime(event)
      event = event.merge(anytime: true)
      announce(event)
      event
    end
    private :announce_anytime

    # Run the block holding back the cards and between-turns notices it
    # announces on this thread, so the caller announces them after its own
    # event (a worker's command: its command_ran first, as the REPL prints
    # the command's output before its cards).
    # @return [Array(Object, Array<Hash>)] the block's value and the held events
    def holding_announcements
      key = :"samagotchi_held_#{object_id}"
      outer = Thread.current[key]
      Thread.current[key] = []
      value = yield
      [value, Thread.current[key]]
    ensure
      Thread.current[key] = outer
    end

    # Announce +event+ now, or keep it for #holding_announcements' caller.
    def announce_or_hold(event)
      held = Thread.current[:"samagotchi_held_#{object_id}"]
      held ? held << event : announce(event)
    end
    private :announce_or_hold

    # ── Model switching ────────────────────────────────────────────────────────

    # @param typed [String, nil] the name the model was typed as when
    #   +model_name+ is a stored ref (a resumed session's model_typed)
    # @return [String] the resolved ref the session stores (ModelRef#ref)
    def switch_model!(model_name, persist_default: false, typed: nil)
      # The alias is applied where the model is resolved (HostRegistry#resolve),
      # once; checked here: an unknown host, an alias naming another host.
      resolved = ModelProfile.check_host!(ModelProfile.required_model_name(model_name), hosts: @host_registry.entries)
      choice = ModelChoice.new(name: resolved, typed: typed.to_s.strip.empty? ? model_name : typed.to_s.strip)
      @model_binding.switch!(choice)
      sync_model_key!
      @prompt_builder.reset!
      # The notes the new model's prompt loads at its next build, so /model,
      # /stats and the web name them before the next turn does.
      record_prompt_notes(model_notes) if @session
      sync_kernel_client!
      @client.invalidate_context_window!
      @metrics.forget_model_reports!
      # The last turn's ctx % was the old model's window's
      # (#announce_switched_context! sends the new one's).
      @last_context_status = nil
      ref = effective_model_ref
      if persist_default
        ConfigFile.write_default_model!(ref)
        @default_model_name = ref
      end
      ref
    end

    # After /model: how full the context is on the new model's window,
    # before its first turn: the last turn's count (the old model's
    # tokenizer's, replaced at the next generation) against the new model's
    # window (EffectiveModel#context_window, ContextWindow.resolve: the
    # running server first, one /props GET that a remote chat host is
    # spared; else the host's cached model list; else the configured
    # window) and the
    # session's budget. Sent as a :context_status event (the web's ctx
    # meter, the attached TUI's status row) with context_window_tokens, and
    # kept for a client that joins later (#session_state_snapshot; the
    # window in the metrics' context too, which a page counts from). A window
    # that can't be resolved sends usage nil: the UIs clear the % until the
    # next generation. Nothing before the session's first counted turn.
    # +configured_only+: the configured window only, never asking a server
    # (EffectiveModel#configured_context_window): a loaded session's (#session=).
    # @return [Hash, nil] the event sent
    def announce_switched_context!(configured_only: false)
      used = @metrics.snapshot.dig(:context, :used_tokens)
      return nil unless used.is_a?(Integer)

      model = effective_model
      window = configured_only ? model.configured_context_window : current_context_window(model)
      display = window && saved_context_status({ used_tokens: used, window_tokens: window.tokens })
      @last_context_status = display&.dup
      @metrics.note_context_window(window.tokens, window.source) if window
      usage = display && { estimated_pct: display[:est_pct], estimated_used_tokens: used, window_tokens: window.tokens,
                           window_source: window.source.to_s, source: "switch" }
      event = { type: :context_status, usage: usage, bucket: display&.dig(:bucket),
                context_window_tokens: window&.tokens, context_window_source: window&.source&.to_s }
      @session_observer.notify(event)
      event
    rescue StandardError => e
      Log.warn(:model, "switched_context_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      nil
    end

    # ── Hooks API ──────────────────────────────────────────────────────────────

    # Register a hook callback for a named lifecycle event.
    #
    # Hooks are turn-scoped: they are automatically cleared after each
    # `run_turn` call so that a single turn's hooks do not leak into the next.
    #
    # @param name [Symbol] one of the hook names (see Hooks module)
    # @param block [Proc] receives an event hash (may mutate in place)
    # @return [void]
    def register_hook(name, &)
      @hooks.register(name, &)
    end

    # Unregister a previously registered hook.
    # @param name [Symbol]
    # @return [Boolean] true if it was removed, false if not found
    def unregister_hook(name)
      @hooks.unregister(name)
    end

    # Clear all registered hooks. Called automatically at the end of each
    # `run_turn` to keep hooks turn-scoped.
    # @return [void]
    def clear_hooks
      @hooks.clear_all
    end

    # ── Reminders API ────────────────────────────────────────────────────────────
    #
    # Each turn injects the reminders due then (#turn_messages,
    # ReminderQueue#inject!). Between turns the idle tick (IdleReminders)
    # finds them due and its callback queues their names
    # (#note_due_reminders); the worker and the REPL run a reminder turn
    # (a continue turn) for them.

    # @return [Boolean] whether any reminder is due now (the store's view,
    #   which a turn would inject), regardless of the queued names
    def reminders_due?
      @reminder_queue.due?
    end

    # @return [ReminderStore] the reminder store for inspection
    attr_reader :reminder_store

    # The metrics for /stats, which may make one short /props GET
    # (EngineSnapshots#stats_snapshot).
    # @return [Hash] @metrics.snapshot, filled in
    def stats_snapshot = @engine_snapshots.stats_snapshot

    # ── The session's model settings (SessionModelSettings) ──────────────────

    # The session's own thinking, reasoning_history and llm_context values
    # over the effective model's, the summaries /model and /stats show, and
    # the saved context's status: SessionModelSettings' (resolved on every
    # read); these forward.
    def saved_context_status(context, model: :current) = @model_settings.saved_context_status(context, model: model)
    def llm_context_explained = @model_settings.llm_context_explained
    def llm_context_summary = @model_settings.llm_context_summary
    def llm_context_override = @model_settings.llm_context_override
    def chat_model? = @model_settings.chat_model?
    def sampling_summary = @model_settings.sampling_summary
    def thinking_summary = @model_settings.thinking_summary
    def steer_cut_after_explained = @model_settings.steer_cut_after_explained
    def steer_cut_after = @model_settings.steer_cut_after
    def steer_cut_summary = @model_settings.steer_cut_summary
    def thinking_explained(own: thinking_override) = @model_settings.thinking_explained(own: own)
    def reasoning_history_summary = @model_settings.reasoning_history_summary
    def reasoning_history_cache_cost(from, to) = @model_settings.reasoning_history_cache_cost(from, to)
    def reasoning_history_override = @model_settings.reasoning_history_override
    def thinking_override = @model_settings.thinking_override
    def served_expected_by(served) = @model_settings.served_expected_by(served)
    def served_expected?(served) = @model_settings.served_expected?(served)

    def reasoning_history_explained(native: false, own: reasoning_history_override)
      @model_settings.reasoning_history_explained(native: native, own: own)
    end

    # Set the session's own reasoning_history or thinking level (nil unsets
    # it): SessionModelSettings'. The caller saves the session.
    # @raise [ArgumentError] with no session yet
    def reasoning_history_override=(level)
      @model_settings.reasoning_history_override = level
    end

    def thinking_override=(level)
      @model_settings.thinking_override = level
    end

    # Set the session's own llm_context values (an empty override unsets
    # them); the next turn's start resolves them, never a running one (its
    # TurnSettings are fixed). The caller saves the session.
    # @raise [ArgumentError] with no session yet
    def llm_context_override=(override)
      raise ArgumentError, "no session yet" unless @session

      SessionSetting::LLM_CONTEXT.set(@session, override)
      # The status a later client reads counts against the new budget.
      @last_context_status = saved_context_status(@metrics.snapshot[:context]) || @last_context_status if @last_context_status
    end

    # Whether the session has a model reply (a cache to restart at all).
    def history?
      Array(@session&.messages).any? { |entry| entry[:role].to_s == "model" }
    end

    # What a thinking level change costs the effective model's prompt
    # cache (Thinking.cache_cost): :full, :provider or :tail.
    # @return [Symbol]
    def thinking_cache_cost
      effective_model.thinking_cache_cost { profile }
    end

    # The model the server serves for the current model, and the name asked
    # for: what the last generation of that name reported, else llama.cpp's
    # model_alias (/props, one short cached probe; not with probe: false),
    # else [nil, nil].
    # @return [Array(String, String), Array(nil, nil)]
    def served_model(probe: true)
      @engine_snapshots.served_model_for(@metrics.served_report, model: probe ? effective_model : nil)
    end

    # Read-only snapshot of the engine's view of the current session plus the
    # live event sequence; cheap, never probes, never raises
    # (EngineSnapshots#session_state_snapshot has its keys).
    # @return [Hash]
    def session_state_snapshot = @engine_snapshots.session_state_snapshot

    # @return [Array<String>] deduped used memory names (thread-safe copy)
    def used_memory_names
      @used_memories.names
    end

    # @return [Array<String>] the memories hidden from this session (normalized names)
    def muted_memory_names
      @muted_memory_names.dup
    end

    # @return [Array<String>] the names the session preloads (config baseline
    #   + --memory, minus mutes), known before the prompt is built, unlike
    #   #activated_memory_names
    def preloaded_memory_names
      @prompt_builder.preloaded_memory_names
    end

    # ── Guardrails ─────────────────────────────────────────────────────────────

    # Who can answer an approval: :repl, :worker or :non_interactive (the
    # default, so a bare Engine denies instead of waiting for nobody). Set
    # by the host (TerminalUI, Worker).
    def interface
      @guardrail_wiring.interface
    end

    def interface=(value)
      @guardrail_wiring.interface = value
    end

    # Where the approval store lives: beside Session's state dir
    # ($XDG_STATE_HOME/samagotchi/guardrails/). A Worker with its own state
    # dir passes it.
    # Where sessions live (a session's images/ are under it); a worker sets
    # its own.
    attr_writer :session_state_dir

    # The metrics load the session's saved records from its state dir, once.
    def bind_metrics(session)
      return unless session&.id

      @metrics.state_dir = session_state_dir
      @metrics.session_id = session.id
    end

    def session_state_dir = @session_state_dir || Session.default_state_dir

    # The running turn's metrics so far, saved as a turn a worker died in
    # would leave them (SessionMetrics#persist's running_turn): a worker's
    # turn checkpoint (TurnCheckpoint) calls it when it writes.
    # @return [Boolean] whether they were saved
    def checkpoint_metrics = @metrics.persist(state_dir: session_state_dir, running_turn: true)

    # What a Bridge adds to a plugin's ctx.messages while a turn runs (the
    # turn so far, as messages); nil without a Bridge (the REPL).
    attr_writer :running_turn_messages

    def guardrail_state_dir=(state_dir)
      # Also where list_sessions and send_note look for other sessions.
      @state_dir = state_dir
      @guardrail_wiring.state_dir = state_dir
    end

    # The YAML rules, read again when a file changed (GuardrailWiring#rules).
    # @return [Guardrails::Rules]
    def guardrail_rules
      @guardrail_wiring.rules
    end

    # @return [Guardrails::LoadFailures]
    attr_reader :guardrail_failures

    # @return [Guardrails::Approvals]
    def guardrail_approvals
      @guardrail_wiring.approvals
    end

    # @return [Guardrails::LoadFailures] the plugins that failed to load
    attr_reader :plugin_failures

    # Once per Engine, on its first turn: what failed to load, so every UI
    # (REPL, attached TUI, web) shows it: the guardrails, then the plugins
    # (label: "plugins"; the UIs say guardrails without one), an orphaned
    # project memory folder (label: "memory"), then the notices and cards plugins showed as they loaded.
    def announce_guardrail_failures(on_event)
      return if @guardrail_failures_announced

      @guardrail_failures_announced = true
      message = @guardrail_failures.message
      emit_event(on_event, { type: :guardrail_warning, message: message }) if message
      plugins = @plugin_failures.message
      emit_event(on_event, { type: :guardrail_warning, message: plugins, label: "plugins" }) if plugins
      memory = MemoryOrphans.message
      emit_event(on_event, { type: :guardrail_warning, message: memory, label: "memory" }) if memory
      @extension_load.held_events.each { |event| emit_event(on_event, event) }
    end
    private :announce_guardrail_failures

    # The warning the first turn announced (nil before it, or with nothing
    # failed), for a UI that joins later (Bridge#snapshot).
    def guardrail_warning
      @guardrail_failures.message if @guardrail_failures_announced
    end

    # The plugins' load warning the first turn announced, likewise.
    def plugin_warning
      @plugin_failures.message if @guardrail_failures_announced
    end

    # Ask the user to approve a call the gate voted `ask` on
    # (GuardrailWiring#request_approval).
    # @param verdict [Guardrails::Verdict]
    # @return [Guardrails::Verdict]
    def request_approval(verdict)
      @guardrail_wiring.request_approval(verdict)
    end

    # The conversation as a hook may read it: a frozen array of copied
    # messages, so a hook cannot change what the turn sends or stores.
    def hook_messages(messages)
      AnswerDisplay.strip_all(messages).map(&:dup).freeze
    end
    private :hook_messages

    # How the turn ended, on the session (Session#last_turn): the caller's
    # save puts it in the file the session hub watches. Public for the
    # Worker's turn that failed before it began (no #end_turn ran).
    # @param limit [Integer, nil] the turn ran out of iterations at this
    #   limit: "exhausted" => true, "limit" => N, so a wait with nobody to
    #   answer the continue offer says so (ReplyWait, ParentReport "limit")
    # @param origin [TurnOrigin] the turn's (TurnOrigin::NONE for no sender)
    # @param event [Hash] the turn's end event (#stop_facts)
    def record_last_turn(session, outcome, seconds, origin, event, limit: nil)
      enqueued_id = origin.enqueued_id
      session.last_turn = LastTurn.new(outcome: outcome, ended_at: Time.now.iso8601(3), seconds: seconds.round(1),
                                       origin: origin.source, exhausted: limit ? true : nil, limit: limit,
                                       enqueued_id: enqueued_id.to_s.empty? ? nil : enqueued_id.to_s,
                                       author: origin.participant_author,
                                       **stop_facts(event))
    end

    # A participant joined (invited) or left (revoked, expired) since the
    # last look: :participants_changed to the observers (ParticipantsWatch;
    # the worker looks on its idle tick). The first look announces nobody.
    # @return [ParticipantsWatch::Change, nil]
    def announce_participants
      change = @participants_watch.changes or return nil

      announce(change.to_event)
      change
    end

    # Reads the session's participants at a turn's start; the first to join
    # and the last to leave rebuild the system prompt (its participants
    # line), once each: a turn in between sends the same prefix.
    def refresh_participants!(session)
      active = @participants.refresh!(session).active?
      return if active == @participants_line

      @participants_line = active
      @prompt_builder.reset!
    end
    private :refresh_participants!

    # The author fields a message +author+ wrote carries (Steer.author_fields:
    # author:, and author_name: from participants.json), {} for the owner.
    # The worker's drain names a participant's merged lines with it, and
    # its running save a participant's prompt.
    # @param author [String, nil] a turn's or a line's author (TurnOrigin#author)
    # @param session [Session, nil] the session it is for (the turn's)
    def author_fields(author, session: @session)
      return {} unless Steer.participant_author?(author)

      Steer.author_fields(author, @participants.name_for(author, session: session))
    end

    # Why a turn stopped (TurnEndings#stop_facts).
    def stop_facts(event) = @turn_endings.stop_facts(event)
    private :stop_facts

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
    # (its limit goes in last_turn).
    def end_turn(turn, outcome, save: false, exhausted: false)
      seconds = turn.elapsed
      synchronize_events do
        kept, event = yield(seconds)
        replace_session_messages(turn.session, kept) if kept
        emit_working_set(turn.on_event, turn.session, turn.session.messages)
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

    def save_quietly(session)
      session.save(state_dir: session_state_dir)
    rescue StandardError => e
      Log.warn(:turn, "turn_end_save_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      nil
    end
    private :save_quietly

    # Keep what the after_turn hooks presented as the answer's `display`
    # and the refs they attached as its `display_refs` (AnswerRefs, one
    # replace for both), and tell the observers (:answer_display, the
    # display or nil, and how many refs), after the turn_completed they
    # already had: the web re-reads the answer then. A turn_completed
    # with display_pending (after_turn hooks were about to run) always gets
    # one, `display: nil` when nothing was presented, so the web holds the
    # answer's pop until then and never swaps it after. Terminals are not
    # sinks of it; they printed the answer already. The session is saved by
    # the caller, as after every turn.
    def store_answer_display(session, display, refs, pending: false)
      synchronize_events do
        # A plugin that kept event[:refs] and calls it later gets nil: the
        # list is stored now (and the turn is over on every path).
        refs.close!
        messages = Array(session.messages)
        changed = display.changed? && messages.last.equal?(display.target)
        added = refs.added? && messages.last.equal?(refs.target)
        if changed || added
          merged = messages.last.dup
          merged[AnswerDisplay::KEY] = display.text if changed
          merged[AnswerRefs::KEY] = refs.to_a if added
          replace_session_messages(session, messages[0...-1] + [merged])
          event = { type: :answer_display, display: changed ? display.text : nil }
          event[:refs] = refs.count if added
          @session_observer.notify(event)
        elsif pending
          @session_observer.notify({ type: :answer_display, display: nil })
        end
      end
    end
    private :store_answer_display

    # ── The hook runtime (HookRoutes) ───────────────────────────────────────

    # What a hook (Hooks::Runtime) and a plugin (Plugin::Host) can do beyond
    # reading its event, routed to the UIs by HookRoutes; these forward.
    def hook_runtime = @hook_routes.runtime
    private :hook_runtime

    def hook_source(hook) = @hook_routes.source(hook)
    private :hook_source

    # What a notice may stand in for (hook_notify's fallback_for:).
    NOTICE_FALLBACKS = HookRoutes::NOTICE_FALLBACKS

    # One line to the user (:hook_notice), HookRoutes#notify.
    def hook_notify(text, level, hook, fallback_for: nil, extra: {})
      @hook_routes.notify(text, level, hook, fallback_for: fallback_for, extra: extra)
    end
    private :hook_notify

    def guardrail_notify(message) = @hook_routes.guardrail_notify(message)
    private :guardrail_notify

    # @param question [HookQuestion]
    # @return [Hash, nil] {selected:, freeform:, selected_indices:}
    def hook_ask_user(question) = @hook_routes.ask_user(question)
    private :hook_ask_user

    # @return [Boolean] true when a running turn was cancelled now
    def hook_stop_turn(reason, hook) = @hook_routes.stop_turn(reason, hook)
    private :hook_stop_turn

    # @return [Boolean] true when a streaming generation was cut now
    def hook_stop_generation(reason, hook) = @hook_routes.stop_generation(reason, hook)
    private :hook_stop_generation

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

    # ── Ask-user-question (structured qualification) ──────────────────────────

    # @return [PendingQuestion, nil] the question pending now
    def pending_question
      @question_desk.pending
    end

    # Ask the model's question (ask_user_question): the kernel's
    # question_handler, called on the turn thread with the payload
    # Tools::AskUserQuestion.validate made (QuestionDesk#request), after
    # the :question_asked hooks (QuestionAsked) gave the step its refs; a
    # --non-interactive run has no one to ask, so they don't fire there.
    # @param payload [Hash] {question:, options:, header:, multi_select:, allow_freeform:}
    # @return [String] normalized answer JSON
    def request_question(payload)
      payload = question_asked(QuestionAsked::KIND_QUESTION, payload) unless interface == :non_interactive
      @question_desk.request(payload)
    end

    # The :question_asked hooks for a question of the model's about to
    # open: the fields with the asking step's refs (QuestionAsked.fire).
    # @return [Hash]
    def question_asked(kind, fields)
      QuestionAsked.fire(hooks: @hooks, conversation: live_conversation, kind: kind, fields: fields,
                         cwd: @session&.working_directory, synchronize: ->(&block) { synchronize_events(&block) },
                         visible: ->(content) { question_step_text(content) })
    end
    private :question_asked

    # A step's text as the asking slot shows it: the native loop's raw
    # response without its thoughts and tool-call bodies (a chat step has
    # neither), then the markup's tokens (OutputFormatter.strip_markup).
    def question_step_text(content)
      parser = @kernel.parser
      OutputFormatter.strip_markup(parser.strip_tool_calls(parser.strip_thought(content)))
    end
    private :question_step_text

    # Open a question for the UIs and wait for its answer
    # (QuestionDesk#open_question: BLOCKS until answered or cancelled).
    # @param fields [Hash] question:, options:, header:, multi_select:, allow_freeform:, …
    #   (as a Hash or as keywords)
    # @param watch [#call, nil] closes the question with the reason it returns
    # @return [QuestionAnswer, Hash, String] the answer, or {error:, …}, or a
    #   sync handler's text
    def open_question(fields = nil, watch: nil, **more)
      @question_desk.open_question({ **fields.to_h, **more }, watch: watch)
    end

    # Publish a standing question that blocks nobody (QuestionDesk#post: a
    # worker's step-limit question).
    # @return [PendingQuestion, nil] the pending question, nil while another is open
    def post_question(fields, on_answer:, on_superseded_close: nil)
      @question_desk.post(fields, on_answer: on_answer, on_superseded_close: on_superseded_close)
    end

    # Withdraw the standing question (QuestionDesk#withdraw).
    # @return [Boolean]
    def withdraw_question(reason, id: nil)
      @question_desk.withdraw(reason, id: id)
    end

    # Answer the pending question (called from UI thread; QuestionDesk#answer).
    # @return [QuestionAnswer]
    def answer_question(id:, selected:, freeform: nil, client_id: nil, parent_agent: nil)
      @question_desk.answer(id: id, selected: selected, freeform: freeform, client_id: client_id,
                            parent_agent: parent_agent)
    end

    # Mark the pending question as relayed, or clear the mark
    # (QuestionDesk#annotate).
    # @return [Boolean]
    def annotate_question(id, relayed_to:, reason: nil)
      @question_desk.annotate(id, relayed_to: relayed_to, reason: reason)
    end

    def set_question_sync_handler(&block)
      @question_desk.sync_handler = block
    end

    # Cancel the pending question (QuestionDesk#cancel).
    # @return [Boolean] whether it was cancelled
    # @raise [QuestionDesk::NotDismissable] +id+ names a standing question
    def cancel_question(reason = "user", id: nil)
      @question_desk.cancel(reason, id: id)
    end

    # The system prompt for a target's loop (default: the effective model's):
    # the chat loop's leaves out the raw-prompt tool text, since its tools go
    # as schemas. Built once per loop (and again after a model switch) so the
    # prompt prefix, and the server's KV cache for it, stay stable.
    # @param model [EffectiveModel, nil]
    # @return [String]
    # The native prompt depends on the thinking level too (Gemma's token):
    # a level change builds it again. A build that
    # misses the cache names the model and the level through its own
    # lambdas (#model_identity, #turn_thinking), which resolve again.
    def system_prompt(model = nil)
      model ||= effective_model
      chat = model.chat?
      level = chat ? nil : @model_settings.thinking_level(model)
      prompt = @prompt_builder.build(chat: chat, thinking: level, layers: model.llm_context_layers(@model_settings.llm_context_session_args))
      # The memory indexes this prompt holds: /stats, the snapshot, analytics.json.
      @metrics.memory_index = @prompt_builder.memory_index
      # The model notes it carries: the session records them (/stats, /model, the web).
      record_prompt_notes(@prompt_builder.prompt_notes)
      prompt
    end

    # The base prompt (specs, plugins' declarations).
    def assist_system_prompt(chat: false)
      @prompt_builder.base(chat: chat)
    end

    # The --memory names activated while building the prompt; the TerminalUI
    # mirrors them into its status line.
    def activated_memory_names
      @prompt_builder.activated_memory_names
    end

    # @return [Session] current session (Engine owns create/resume)
    attr_reader :session

    # This worker's relays of its delegates' approvals (memory only).
    # @return [RelayDesk]
    attr_reader :relay_desk

    # The relay's view of this Engine, or nil when it can't host a relay: a
    # worker's Engine only (its Bridge is what a child verifies against;
    # --non-interactive has no one to ask), never with a REPL's sync
    # handler (no wait loop, no watch).
    # @return [RelayPeer, nil]
    def relay_peer
      return nil unless interface == :worker && !@question_desk.sync_handler?

      RelayPeer.new(self)
    end

    # @return [String] the state dir holding this Engine's sessions
    def peer_state_dir = @state_dir

    # Set the current session outside a turn (the REPL does, before its first
    # turn, so the messages API and recap see it)
    def session=(session)
      @session = session
      # One session per REPL/worker process: its records carry this sid.
      Log.session_id = session.id if session&.id
      # Its own recap values (chi --set recap.enabled=false) rebuild the job.
      rebuild_recap!
      # A woken worker's /stats and status line count the turns before it.
      bind_metrics(session)
      @used_memories.absorb(session)
      # Loaded on another model than its last turn ran on (a --resume'd
      # REPL's --model, a worker woken after a /model with no turn since):
      # the saved ctx % was that model's window's. Drop it and count it as
      # /model does, on a configured window only: this runs before a
      # worker's Bridge serves, so no /props GET or model list here (a slow
      # or hung host would hold up the worker's start). No configured
      # window: no % (ctx ?) until the first generation reports one.
      return unless model_switched_since_last_turn?

      @metrics.forget_model_reports!
      announce_switched_context!(configured_only: true)
    end

    # Whether the last turn that named its model ran on another one than
    # the effective model; false before any (or when the ref can't be told).
    def model_switched_since_last_turn?
      last = @metrics.last_model_ref
      !last.nil? && last != effective_model_ref
    rescue StandardError => e
      Log.warn(:model, "switch_check_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      false
    end
    private :model_switched_since_last_turn?

    # @return [IdleRecap, nil] the idle recap detector, or nil when disabled
    attr_reader :recap

    # Whether a continue offer waits (the Worker's or the REPL's TurnFlow),
    # for the recap job: this one and any rebuilt one (IdleRecap#awaiting_continue=).
    def recap_awaiting_continue=(callable)
      @recap_awaiting_continue = callable
      @recap&.awaiting_continue = callable
    end

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

    # The bound session's own recap.* values ({} for none).
    def session_recap_values
      (@session&.settings&.core || {}).select { |key, _| key.start_with?("recap.") }
    end
    private :session_recap_values

    # A new recap job when the bound session's own recap values differ from
    # the ones the current job was built under (none at start): the old one
    # is dropped (an attempt in flight goes stale) and the scheduler swaps
    # it, keeping its one thread. Binding the same session again changes
    # nothing (the REPL binds it twice).
    def rebuild_recap!
      return if session_recap_values == @recap_built_for

      old = @recap
      old&.invalidate!
      @recap = build_recap
      @idle_scheduler&.replace_job(old, @recap)
    end

    # /recap on|off|default: the bound session's own recap.enabled (true,
    # false; nil removes it, so config.yml's applies again), and the recap
    # job rebuilt under it at once. It doesn't save: the command says
    # changed: [:recap] and its host saves (Worker#run_command).
    # @param enabled [Boolean, nil]
    # @raise [ArgumentError] no session is bound
    def recap_override=(enabled)
      raise ArgumentError, "no session" unless @session

      core = @session.settings.core.dup
      enabled.nil? ? core.delete(RECAP_ENABLED_KEY) : core[RECAP_ENABLED_KEY] = enabled
      @session.settings = @session.settings.with(core: core)
      rebuild_recap!
    end

    # The bound session's own recap.enabled (/recap on|off, --set), or nil.
    # @return [Boolean, nil]
    def recap_override = @session&.settings&.core&.fetch(RECAP_ENABLED_KEY, nil)

    # Write the recap now, before the session is left (IdleRecap#write_now).
    # @return [String, nil] the recap written, nil when none was (recap off,
    #   nothing new, an error, the timeout)
    def write_recap_now(on_start: nil)
      @recap&.write_now(on_start: on_start)
    end

    # The longest #write_recap_now waits (recap.timeout), nil when no recap
    # is set up.
    # @return [Float, nil]
    def recap_timeout = @recap&.timeout

    # Ask for a recap now (/recap), without waiting for the idle window.
    # @return [Symbol] IdleRecap#request_now's answer, or :off
    def request_recap
      @recap ? @recap.request_now : :off
    end

    # The recap saved with the current session (recap.json), and how many
    # user turns came after it (0: it is current).
    # @return [Hash, nil] {text:, covered:, turns_since:, created_at:}
    def saved_recap
      state = @recap&.state
      return nil unless state

      messages = @session&.messages || []
      covered = state[:covered].to_i
      turns_since = Array(messages).drop(covered).count { |m| Steer.turn_prompt?(m) }
      { text: state[:text], covered: covered, turns_since: turns_since, created_at: state[:created_at] }
    end

    # Start the shared idle scheduler (reminders + optional recap). The recap
    # job is only registered when recap is configured; the reminders job is
    # always present. TerminalUI calls this before the REPL and SessionManager
    # workers call it so reminders can trigger turns; one-shot/worker paths
    # that never start it poll nothing.
    def start_idle
      @idle_scheduler&.start
      self
    end

    # Stop the shared idle scheduler (TerminalUI calls this when the REPL
    # exits). +join+: wait for a tick under way (IdleScheduler#stop); a
    # caller holding #synchronize_events passes false, since a recap's emit
    # in that tick waits for the same lock.
    def stop_idle(join: true)
      @idle_scheduler&.stop(join: join)
      self
    end

    # One turn's values, for #run_turn and its endings. Per turn and
    # single-threaded: the cross-thread turn state (the cancel slot, the
    # sink, steers) stays on the Engine.
    # +ended+: the end event is out (what follows is post-turn work).
    # +settings+: the kernel's LLM::TurnSettings, made in #prepare_turn and
    # set on the kernel in #generate.
    # +id+: names the turn on :turn_started (its metrics record's id) and on
    # its saved prompt, so a UI pairs the two whatever left the conversation.
    # +limit+: the iteration limit #generate ran it with.
    # +resumed+: a step-limit Continue (run_turn's resumed:).
    # +resume_from+: where its reasoning starts, the run it resumes
    # (run_turn's resume_from:); nil for every other turn, and for a
    # Continue that starts cold (after a model change).
    # +wall+: the wall time it started (MessageTime.now, once): the
    # :turn_started event's at and its user message's (and reminders') stamp.
    Turn = Struct.new(:session, :prompt, :continue, :on_event, :controller, :origin, :started_at, :messages, :ended,
                      :settings, :id, :limit, :resumed, :resume_from, :wall) do
      def resumed? = resumed ? true : false

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
                 origin: TurnOrigin::NONE, images: [], id: nil, resumed: false, resume_from: nil)
      turn = begin_turn(session, prompt, on_event: on_event, cancel_controller: cancel_controller, origin: origin,
                                         continue: continue, id: id)
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
        warm_up_next_turn(turn, result)
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
        # after a failed turn. The REPL still rolls back to its checkpoint.
        end_turn(turn, "failed", save: true) { |seconds| [failed_messages(turn, e), failed_event(e, seconds)] }
        raise
      ensure
        release_turn(probe_cancel_before)
      end
    end

    # The turn's state before anything can fail it: the session running,
    # the turn flag, its cancel controller and sink. The cross-thread state
    # is set here and cleared in #release_turn only.
    def begin_turn(session, prompt, on_event:, cancel_controller:, origin:, continue:, id: nil)
      origin = TurnOrigin.of(origin)
      # Track the active session for recap and status snapshot.
      @session = session
      # status is turn state: running now, idle again before the turn's end
      # is announced, so a UI reacting to that event reads the new state.
      session.status = Session::STATUS_RUNNING
      @used_memories.absorb(session)
      # Provide a cancellable controller for this turn (cross-process cancel via file flag)
      effective_controller = cancel_controller || CancellationController.new
      # The turn runs, with its controller and sink, in one step: a Stop
      # or a plugin's card from another thread never sees a running turn
      # without them. The idle recap detector does not fire (or render an
      # invalidated recap) while the model is working. A hook's notice goes
      # where the turn's events go (the REPL renders only its sink; a
      # worker's observers carry it to the bridge).
      @turn_state.begin!(controller: effective_controller, sink: on_event)
      # Drop a recap already in flight: the turn makes it stale.
      @recap&.invalidate!
      # The gate's context: who queued this turn, and git asked afresh.
      @guardrail_wiring.begin_turn(origin)

      Turn.new(session: session, prompt: continue ? nil : prompt, continue: continue, on_event: on_event,
               controller: effective_controller, origin: origin, started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC),
               id: id || SecureRandom.uuid, wall: MessageTime.now)
    end
    private :begin_turn

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
      turn_started.merge!(author_fields(turn.origin.author, session: session))
      emit_event(turn.on_event, turn.tag(turn_started))
      raise image_error if image_error

      # The window and the profile probes run after run_turn's probe-cancel
      # swap, so a Stop cuts them; a failure ends the turn as turn_failed.
      # The cache itself was dropped at the previous turn's end, so this
      # turn's first probe asks the server (a restart with another -c
      # between turns is noticed), and the answer the session's prompt build
      # read for its profile (a first turn) is what this turn starts from:
      # one GET /props per turn, not two.
      refresh_profile!

      # Before anything of the turn is kept or a reminder is used up.
      turn.settings = turn_settings(session)
      refuse_images!(turn.settings.vision) unless image_refs.empty?
      # A Stop during the probes: the turn ends before the load-failure
      # warnings, which show once, so the next turn still shows them.
      return false if turn.controller.cancelled?

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
      apply_toolkit!(session, turn.on_event)
      refresh_participants!(session)
      # A Stop during the wait above: the turn ends here,
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
    end
    private :prepare_turn

    # A turn stopped before the model was asked (#prepare_turn returned
    # false): canceled with nothing kept, like a Ctrl-C there; the result
    # has no conversation, so a UI's checkpoint stands.
    def stopped_before_model(turn)
      reason = turn.controller.reason
      end_turn(turn, "canceled") do |seconds|
        [nil, { type: :turn_canceled, cancellation_reason: reason, cancelled_by: cancelled_by(turn),
                duration_ms: (seconds * 1000).round }]
      end
      LLM::ModelResult.new(text: "", canceled: true, cancellation_reason: reason)
    end
    private :stopped_before_model

    # Who stopped a turn a hook stopped or cut (the controller's detail: the
    # bundle, or the hook's label), for the UIs' "stopped by loop-guard";
    # nil for any other cancel.
    def cancelled_by(turn) = turn.controller.stopped_by
    private :cancelled_by

    # The turn's settings for the kernel (LLM::TurnSettings): vision,
    # sampling and thinking, the thinking resolved before the hooks run.
    # The model name is added in #generate, after the hooks that may switch
    # the model.
    # One resolve for all of them: nothing runs between them that could
    # change what a resolve gives.
    def turn_settings(session)
      model = effective_model
      vision = turn_vision(session, model)
      sampling = model.sampling
      level = @model_settings.thinking_level(model)
      @thinking_notices.turn_started(level, model.target)
      LLM::TurnSettings.new(vision: vision, sampling: sampling, thinking: level,
                            reasoning_history: @model_settings.reasoning_history_level(model), model_name: nil,
                            window_setting: nil, llm_context: nil, price: nil)
    end
    private :turn_settings

    # @return [PromptWarmup] the turn-end warm-up (specs, measurements)
    attr_reader :prompt_warmup

    # A caller's check that the next turn starts at once (input queued for
    # it: a worker's inbox) or that none follows (a one-shot run): no
    # warm-up then. nil: neither.
    attr_accessor :next_turn_waiting

    # After a completed turn, prefill the next turn's prompt up to its user
    # message while the user reads (PromptWarmup, cache.warmup). Only on a
    # local llama.cpp host on the native loop, and not when the next turn's
    # start differs anyway or starts at once: a reminder due, a continue
    # offer (the turn ran out of steps), a carried steer or queued input.
    # Never fails the turn.
    def warm_up_next_turn(turn, result)
      return if result.canceled? || result.resumable?

      model = effective_model
      client = model.client
      return unless warmup_target?(model, client)
      return if reminders_due? || @turn_state.carried_steers? || @next_turn_waiting&.call

      messages = ContextNote.with_system_head(turn.session.messages.dup, { role: "system", content: system_prompt(model) })
      # Under the next turn's strategy (a /model switch may have changed it);
      # the last turn's when it can't be resolved.
      prompt, images = @kernel.warmup_prompt(messages, llm_context: @model_settings.turn_llm_context || @kernel.turn_settings&.llm_context)
      return unless prompt

      started = @prompt_warmup.start(client: client, prompt: prompt, model: @kernel.turn_settings.model_name,
                                     slot: @kernel.last_slot, images: images)
      @kernel.warmed_up! if started
    rescue StandardError => e
      Log.warn(:model, "warmup_skipped", error: e.class.name, msg: e.message.to_s[0, 200])
    end
    private :warm_up_next_turn

    # Never a paid or remote host (cache.warmup auto means local only), nor
    # the chat loop (Splash keeps its own cache; llama.cpp's chat path is
    # not measured), nor a client that can't warm up (a spec's stub).
    def warmup_target?(model, client)
      return false if model.chat? || model.entry.remote?
      return false unless client.respond_to?(:warm_up)

      PromptWarmup.enabled?
    end
    private :warmup_target?

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
                         MessageTime::KEY => turn.at }
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
      # The turn's settings, set once here. The chat loop dispatches tools
      # through the kernel without its #run: tag those dumps with this
      # turn's model, not the last native one.
      explained = model.llm_context_explained(@model_settings.llm_context_session_args)
      model_backend = backend(model)
      # A host that loads tools runs a direct call of one the session
      # reaches but doesn't declare (ToolRunner, KernelLoop#dispatch).
      loads_tools = model_backend.respond_to?(:loads_tools?) && model_backend.loads_tools?(bare_for_backend)
      @kernel.turn_settings = turn.settings.with(model_name: bare_for_backend, window_setting: model.window_setting,
                                                 llm_context: explained&.resolved, price: model.price,
                                                 loads_tools: loads_tools)
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
        reasoning_since: reasoning_since
      )
      result.run_start = run_start
      result
    end
    private :generate

    # The ref (host:model, as asked) a turn's generations ran on: the model
    # #generate resolved, after the before_turn hooks (which may switch it).
    # SessionMetrics keys its per-model segments on it. nil when it can't be
    # named (the turn's record then has none).
    def generation_model_ref(model)
      model.ref
    rescue StandardError => e
      Log.warn(:turn, "model_ref_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      nil
    end
    private :generation_model_ref

    # A step-limit Continue's resume_from, when it is inside the messages the
    # run gets (a wrong one only drops reasoning: it is ignored, logged).
    # Entries before it never move between the turns (#turn_messages adds
    # at the tail, and the system head is replaced in place).
    def resumed_run_start(turn, run_start)
      start = turn.resume_from
      return nil if start.nil?
      return start if start.is_a?(Integer) && start.between?(0, run_start)

      Log.warn(:turn, "resume_start_invalid", resume_from: start, length: run_start)
      nil
    end
    private :resumed_run_start

    # The turn's LLM context strategy and where it came from, in the turn
    # log: when it runs a layer, or the session set it (none too).
    def log_llm_context(explained)
      return unless explained
      return if explained.resolved.active_layers.empty? && explained.strategy.source != :session

      summary = explained.summary
      Log.info(:turn, "llm_context", **summary.slice(:strategy, :strategy_source, :apply, :apply_source, :budget_tokens,
                                                     :budget_source).compact)
    end
    private :log_llm_context

    def publish_used_memories(session, on_event)
      # Persist deduped used memories onto the session for Web + reload.
      begin
        session.used_memory_names = used_memory_names
      rescue StandardError => e
        Log.warn(:memory, "used_memories_store_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      end
      # Notify live observers of the updated memory list (so yellow bar refreshes
      # even without a tool_call event if the preload was the only addition).
      # Only emit when there is something to report to avoid noisy event_count drift.
      return unless used_memory_names.any?

      begin
        emit_event(on_event, { type: :used_memories_updated, used_memory_names: used_memory_names })
      rescue StandardError => e
        Log.warn(:memory, "used_memories_emit_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      end
    end
    private :publish_used_memories

    # The normal ending (an answer, an empty answer, a Stop, the iteration
    # limit), then the after-turn hooks.
    def complete_turn(turn, result)
      canceled = result.canceled?
      # after_turn hooks run below and may present the answer (the web
      # holds its pop until it knows).
      display_pending = !canceled && @hooks.any?(:after_turn)
      end_turn(turn, canceled ? "canceled" : "completed", exhausted: !canceled && result.exhausted?) do |seconds|
        kept = kept_messages(turn, result, seconds)
        if canceled
          [kept, { type: :turn_canceled, cancellation_reason: result.cancellation_reason, cancelled_by: cancelled_by(turn),
                   duration_ms: (seconds * 1000).round }]
        else
          # For a client that attaches later (session_state_snapshot).
          @last_context_status = result.context_status.dup if result.context_status
          [kept, { type: :turn_completed, result: result, turn_summary: turn_summary(result),
                   display_pending: display_pending }]
        end
      end

      # Fire :after_turn hook (an answer or a Stop; an Interrupt or a failure
      # ends the turn in #run_turn without it), with a read-only
      # copy of the conversation the turn stored, event[:present] for
      # a display version of the answer (AnswerDisplay) and event[:refs]
      # for refs on it (AnswerRefs).
      session = turn.session
      display = AnswerDisplay.new(session.messages)
      refs = AnswerRefs.new(session.messages, cwd: session.working_directory)
      after_turn = { type: :after_turn, status: canceled ? "canceled" : "completed",
                     messages: hook_messages(session.messages) }
      after_turn[:present] = display.presenter(after_turn)
      after_turn[:refs] = refs.adder(after_turn)
      @hooks.fire(:after_turn, after_turn)
      store_answer_display(session, display, refs, pending: display_pending)

      # Fire :session_end after the turn (turn-level lifecycle), as :after_turn
      @hooks.fire(:session_end, { type: :session_end, session_id: session.id })
    end
    private :complete_turn

    # What each turn ending keeps and announces is TurnEndings'
    # (#build_turn_endings); these forward to it.
    def kept_messages(turn, result, seconds) = @turn_endings.kept_messages(turn, result, seconds)
    private :kept_messages
    def ctrl_c_messages(turn, interrupt, seconds) = @turn_endings.ctrl_c_messages(turn, interrupt, seconds)
    private :ctrl_c_messages
    def loop_conversation(error) = @turn_endings.loop_conversation(error)
    private :loop_conversation
    def failed_messages(turn, error) = @turn_endings.failed_messages(turn, error)
    private :failed_messages
    def failed_event(error, seconds) = @turn_endings.failed_event(error, seconds)
    private :failed_event

    # However the turn ended (#run_turn's ensure): the turn flag off, the
    # probe cancel restored, the cancel controller, sink and steers cleared
    # (a steer left is logged as dropped), activity recorded, the
    # turn-scoped hooks cleared.
    def release_turn(probe_cancel_before)
      # A completed turn is activity: release the turn flag and advance the
      # shared inactivity clock so the idle recap detector (shared with the REPL)
      # treats the just-finished turn as activity and re-arms its window.
      left = @turn_state.finish!
      @steer_cut.finished!
      Client.swap_probe_cancel(probe_cancel_before)
      # The next turn's window and served model are asked again: the cache
      # (this host's, process-wide) is dropped here, at the turn's end,
      # rather than at its start, so what this turn read (the profile's own
      # probe included) is not asked for a second time within the turn. A
      # restart with another -c between turns is still noticed: the next
      # turn's first probe goes to the server.
      @client.invalidate_context_window!
      log_dropped_steers(left, "turn_ended")
      record_activity
      # Clear hooks so they remain turn-scoped and never leak into the next turn.
      clear_hooks
    end
    private :release_turn

    # [refs, nil] for a turn's images, or [[], error] when one can't be used
    # (the turn then fails right after :turn_started).
    def turn_image_refs(session, images)
      return [[], nil] if Array(images).empty?

      [ImageStore.resolve_all(Session.session_dir(session.id, state_dir: session_state_dir), images), nil]
    rescue ImageStore::Error => e
      [[], e]
    end

    # The turn's VisionContext: the session's images folder, and whether the
    # effective model can see images, asked only when a request carries one.
    def turn_vision(session, model = effective_model)
      VisionContext.new(session_dir: Session.session_dir(session.id, state_dir: session_state_dir),
                        capability: -> { model.vision_support(profile) })
    end

    # The effective model's sampling and thinking level as the next turn
    # reads them (SessionModelSettings).
    def turn_sampling = @model_settings.turn_sampling
    def turn_thinking = @model_settings.turn_thinking

    # A model known not to see images fails a turn with images up front.
    def refuse_images!(vision)
      return if vision.sendable?

      host = effective_model.host_name
      raise LLM::VisionUnsupported.new("#{host}: #{vision.refusal_reason}", host: host)
    end

    # JSON-safe digest of a finished turn for renderers (TurnEndings#turn_summary).
    # @param result [LLM::ModelResult]
    # @return [Hash]
    def turn_summary(result) = @turn_endings.turn_summary(result)

    # ── Session messages API ───────────────────────────────────────────────
    #
    # Out-of-turn edits to the current session's conversation (`!cmd` output,
    # rollback after Ctrl-C). Each replaces the array rather than mutating it,
    # so the recap's lock-free snapshot never sees a half-applied edit.

    # The answer a UI shows last (AnswerTail), a copy of that one message
    # only: walked back from the end, never a #messages_checkpoint of the
    # whole conversation (the Bridge's GET tail). +turn_id+: that turn's
    # answer (AnswerTail.find); unknown or nil: the newest.
    # @return [Hash, nil]
    def last_answer_message(turn_id: nil)
      AnswerTail.find(@session&.messages, turn_id: turn_id)&.dup
    end

    # @return [Array<Hash>] a copy of the current session's messages to hand
    #   back to #rollback_to later
    def messages_checkpoint
      clone_messages(@session&.messages)
    end

    # The running turn's conversation as its loop builds it (both loops
    # register it on the kernel's llm_context_turn): the same array the loop
    # appends to, not a copy, so read it on the turn's thread (the pending
    # input drain, at an iteration boundary: TurnCheckpoint). nil when no
    # turn runs (llm_context_turn is never cleared, and still holds the
    # last turn's then).
    # @return [Array<Hash>, nil]
    def live_conversation
      return nil unless turn_running? && @kernel.respond_to?(:llm_context_turn)

      @kernel.llm_context_turn&.conversation
    end

    # Append messages to the current session's conversation.
    # @param messages [Array<Hash>]
    # @return [Array<Hash>] the session's messages
    def append_messages(messages)
      raise ArgumentError, "no current session" unless @session

      replace_session_messages(@session, Array(@session.messages) + clone_messages(messages))
    end

    # Restore the current session's conversation to a #messages_checkpoint.
    # Between turns the working set is announced when that changed it (a
    # !rollback or a canceled continue dropping the turn's tool calls, the
    # set emptied too), so the page doesn't keep the dropped items until
    # the next request.
    # @param checkpoint [Array<Hash>]
    # @return [Array<Hash>] the session's messages
    def rollback_to(checkpoint)
      raise ArgumentError, "no current session" unless @session

      messages = replace_session_messages(@session, clone_messages(checkpoint))
      announce_working_set unless turn_running?
      messages
    end

    # Clone a messages array (shallow dup of each element).
    # @param messages [Array<Hash>]
    # @return [Array<Hash>]
    def clone_messages(messages)
      Array(messages).map(&:dup)
    end

    private

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

    # Pick the loop for +model+ (EffectiveModel); the chat loop is pointed
    # at its host's adapter (one per host, kept for its cached model list).
    def backend_for(model)
      return @native_backend unless model.chat?

      @chat_backend_mutex.synchronize do
        @chat_backend ||= LLM::ChatLoop.new(kernel: @kernel, stable_length: ->(text) { @prompt_builder.stable_length(text) })
        @chat_backend.adapter = @host_registry.adapter_for(model.entry)
        @chat_backend.session_id = session&.id
        @chat_backend
      end
    end

    def load_plugins
      host = plugin_host
      registries = Plugin::Registries.new(
        commands: @command_registry, tools: @tools, hooks: @hooks,
        context_for: lambda { |bundle, settings, label|
          Plugin::Context.new(bundle: bundle, label: label, settings: settings, host: host)
        },
        tools_changed: -> { tools_changed! },
        services: @services,
        stage_tools: ->(bundle, specs, context) { stage_tools(bundle, specs, context) },
        init: lambda { |bundle, label, plugin_label, provides_tools:, quiet:, timeout:, failed: nil, &block|
          add_init_task(bundle: bundle, label: label, plugin_label: plugin_label, provides_tools: provides_tools,
                        quiet: quiet, timeout: timeout, failed: failed, &block)
        },
        toolkits: @toolkit_binding.plugin_kits,
        tool_index: @tool_index,
        peer_sources: @peer_sources
      )
      # What plugins show while they load (an MCP server that didn't
      # start) waits for the first turn, beside the load warnings: no UI
      # is there yet, and the Engine isn't built.
      @extension_load.load_plugins(registries, failures: @plugin_failures)
    end

    # Keep a plugin's new tool set (chi.replace_tools, from any thread)
    # for the turn thread (PluginTasks#stage_tools).
    def stage_tools(bundle, specs, context)
      @plugin_tasks.stage_tools(bundle, specs, context)
    end
    private :stage_tools

    # Apply the staged tool sets, on the turn thread, before the turn's
    # system prompt is built (PluginTasks#apply_staged_tools!).
    # @return [Boolean] whether the tools changed
    def apply_staged_tools!
      @plugin_tasks.apply_staged_tools!
    end
    public :apply_staged_tools!

    # The session's toolkit (ToolkitBinding): the kits, what its next turn
    # declares, ctx.use_toolkit and the turn-start apply.
    def toolkit_kits(errors = []) = @toolkit_binding.kits(errors)
    def resolved_toolkit(session, errors = []) = @toolkit_binding.resolved(session, errors)
    def toolkit_explained(toolkit = nil) = @toolkit_binding.explained(toolkit)
    def toolkit_summary = @toolkit_binding.summary

    # The tools this session registered (Tools::Registry), declared or not.
    attr_reader :tools

    public :tools, :toolkit_kits, :resolved_toolkit, :toolkit_explained, :toolkit_summary

    # A plugin's ctx.load_tools: stage the reachable tools +names+ names
    # (Tools::ToolIndex#deferred_name) that the session neither declares
    # nor loaded with an earlier tool change, for bundle +bundle+. A name
    # that names no tool at all is logged; a declared or removed one is
    # skipped quietly.
    # @return [Array<String>] the wire names staged
    def load_tools(names, bundle)
      added = ToolLoads.added(@session&.messages)
      wanted = names.filter_map do |name|
        wire = @tool_index.deferred_name(name)
        Log.info(:plugins, "load_tools_skipped", bundle: bundle, tool: name) unless wire || @tools.key?(name)
        wire
      end
      @tool_loads.stage(wanted - added, by: bundle)
    end
    public :load_tools

    # The staged tool loads, appended to +turn+'s messages (after its user
    # message, or the trailing results and notes of a turn with none) as
    # one ToolLoads entry per bundle, when the turn's host takes tool
    # changes (ChatLoop#tool_changes?). Elsewhere they are dropped, logged.
    # A conversation that ends with a reply keeps them staged (a system
    # change must follow a user turn).
    def append_tool_loads(turn)
      return unless @tool_loads.any?
      return if turn.messages.last&.dig(:role).to_s == "model"

      model = effective_model
      host = backend(model)
      staged = @tool_loads.take
      added = ToolLoads.added(turn.messages)
      unless host.respond_to?(:tool_changes?) && host.tool_changes?(bare_model_name(model.name))
        Log.info(:plugins, "tool_loads_not_sent", tools: staged.values.flatten.join(","), model: model.name.to_s)
        return
      end

      staged.each do |bundle, names|
        names -= added
        next if names.empty?

        turn.messages << ToolLoads.entry(names, by: bundle)
        hook_notify("tools loaded: #{names.join(", ")}", :info, bundle)
      end
    end
    private :append_tool_loads

    # A plugin's ctx.use_toolkit (ToolkitBinding#use).
    # @return [Boolean] whether it was staged
    # @raise [ArgumentError] an unknown toolkit
    def use_toolkit(name) = @toolkit_binding.use(name)
    public :use_toolkit

    # At a turn's start (ToolkitBinding#apply!).
    # @return [Boolean] whether the declared tools changed
    def apply_toolkit!(session, on_event = nil) = @toolkit_binding.apply!(session, on_event)
    private :apply_toolkit!

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

    # The tools changed (a plugin's chi.tools_changed!): the system prompts,
    # which declare them, are built again on the next turn.
    def tools_changed!
      @prompt_builder&.reset!
    end

    # What a Plugin::Context reads and calls: the session now, and the
    # hook runtime's notify and ask_user.
    def plugin_host
      Plugin::Host.new(
        session_id: -> { @session&.id },
        cwd: -> { @session&.working_directory },
        messages: -> { plugin_messages },
        messages_partial: -> { turn_running? && @running_turn_messages.nil? },
        notify: ->(text, level, label, fallback_for: nil) { hook_notify(text, level, label, fallback_for: fallback_for) },
        ask_user: ->(question) { hook_ask_user(question) },
        # An init task's is its own (a Ctrl-C ends a turn, not the task).
        cancelled: lambda {
          (task = current_init_task) ? task.cancelled? : active_cancel_controller&.cancelled?
        },
        card: ->(**card) { show_card(**card) },
        steer: ->(text, label) { steer(text, source: hook_source(label)) },
        stop_turn: ->(reason, label) { hook_stop_turn(reason, label) },
        stop_generation: ->(reason, label) { hook_stop_generation(reason, label) },
        toolkit: -> { @toolkit_binding.name },
        declared_tools: -> { toolkit_explained.declared.map(&:name) },
        use_toolkit: ->(name) { use_toolkit(name) },
        load_tools: ->(names, bundle) { load_tools(names, bundle) },
        cancel_controller: ->(handler: false) { plugin_cancel_controller(handler: handler) },
        ask_model: lambda { |request, timeout:, max_tokens:, cancel_controller:, model: nil, source: nil|
          ask_side_model(request, timeout: timeout, max_tokens: max_tokens, cancel_controller: cancel_controller,
                                  model: model, source: source)
        },
        model_name: -> { effective_model_ref },
        model_key: -> { @model_binding.model_key },
        state_dir: -> { session_state_dir },
        scratch: -> { @scratch },
        setup: -> { SessionSetup.of(@session) },
        # The files whose text the built system prompt holds; [] until a
        # build and after a rebuild that drops them (SystemPrompt#prompt_files
        # returns [] itself: the || keeps a nil builder safe).
        prompt_files: -> { @prompt_builder&.prompt_files || [] },
        frontend: -> { interface },
        cost: -> { @metrics.cost },
        usage: -> { @metrics.usage },
        turn_author: -> { turn_author }
      )
    end

    # The controller a plugin's ctx.http call without cancel: stops with
    # (docs/plugins.md): an init task's own, else the running turn's for the
    # turn's own work until the turn has ended (TurnState#own_controller); nil
    # for an anytime command, a service or a thread of the plugin's.
    def plugin_cancel_controller(handler:)
      (task = current_init_task) ? task.cancel : @turn_state.own_controller(handler: handler)
    end
    private :plugin_cancel_controller

    # A plugin's ctx.messages: the conversation without the system prompt
    # (the REPL's starts with it, a worker's new session doesn't), and,
    # while a turn runs, the turn so far from the Bridge (plan O1). Read
    # with the event log held, so a turn is in exactly one of the two.
    def plugin_messages
      synchronize_events do
        messages = AnswerDisplay.strip_all(messages_checkpoint)
        first = messages.first
        messages = messages.drop(1) if first && first[:role].to_s == "system" && first[:kind].to_s.empty?
        running = turn_running? && @running_turn_messages ? Array(@running_turn_messages.call) : []
        messages + running
      end
    end
    private :plugin_messages

    # ctx.ask_model's request: the session's current model on its host, as
    # a turn resolves them (a /model switch counts), or a configured +model+
    # (a host:id ref, an alias, a bare id one of a host's models), through its own
    # IdleClient, so it shares nothing with the turn's backend. The client
    # is kept while the target and timeout stay (what it learned, e.g. a
    # refused thinking-off, holds for the next request); the session's id
    # goes with the request. Its usage counts in the session's side line
    # (#note_side_usage) under +source+, the asking bundle's name.
    # @return [String] the answer
    def ask_side_model(request, timeout:, max_tokens:, cancel_controller:, model: nil, source: nil)
      target = model.nil? ? session_model_recap_target : configured_side_target(model)
      client = side_model_client(target, timeout)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      answer = client.ask(request, max_tokens: max_tokens, cancel_controller: cancel_controller, session_id: @session&.id,
                                   kind: source.to_s.empty? ? "ask" : source.to_s, on_usage: method(:note_side_usage))
      Log.info(:plugins, "ask_model", model: target.label, answer_model: answer.model, chars: answer.text.length,
                                      ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      answer.text
    end
    private :ask_side_model

    # The target of ctx.ask_model(model:): +model+ as a turn resolves it,
    # once it is known to name something configured. IdleTarget.of_model
    # never raises (an unknown host falls to the default host, an unknown id
    # to the default entry), so a typo would silently ask another model.
    # @raise [ArgumentError] +model+ names no configured host and is no
    #   host's model (cached, declared or saved lists; nothing is asked)
    def configured_side_target(model)
      ref = @host_registry.model_ref(model)
      unless ref.host_name || ref.alias_name || @host_registry.hosts_with_model(ref.id).any?
        raise ArgumentError, "ask_model: unknown model #{model.to_s.inspect} (use a configured host:id, an alias, " \
                             "or a model id one of your hosts lists)"
      end

      IdleTarget.of_model(@host_registry, model)
    end
    private :configured_side_target

    # The IdleClient for +target+ at +timeout+: the last one when both are
    # the same, else a new one.
    def side_model_client(target, timeout)
      @side_client_mutex.synchronize do
        key = [target, timeout]
        unless @side_client && @side_client_key == key
          @side_client = IdleClient.for(target, timeout: timeout)
          @side_client_key = key
        end
        @side_client
      end
    end
    private :side_model_client

    # The session's current model as a recap target: its host's OpenAI API
    # (native llama.cpp hosts serve /v1/chat/completions too), key variable
    # and bare model name, as a turn resolves them.
    # @return [IdleTarget]
    def session_model_recap_target
      IdleTarget.of_model(@host_registry, effective_model_name)
    end

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

    # ── Event helpers ──────────────────────────────────────────────────────────

    # The stream handler, the working set and the event fan-out are
    # EventFanout's (#build_event_fanout); these forward to it.
    def build_stream_event_handler(...) = @event_fanout.build_stream_event_handler(...)
    def emit_working_set(...) = @event_fanout.emit_working_set(...)
    private :emit_working_set
    def working_set_llm_context = @event_fanout.working_set_llm_context
    private :working_set_llm_context
    def with_generation_report(event) = @event_fanout.with_generation_report(event)
    private :with_generation_report
    def stream_watch(cancel_controller) = @event_fanout.stream_watch(cancel_controller)
    private :stream_watch
    def emit_event(on_event, event) = @event_fanout.emit_event(on_event, event)

    # The effective model's window_tokens and price, read per turn
    # (SessionModelSettings).
    def turn_window_setting = @model_settings.turn_window_setting
    def turn_price = @model_settings.turn_price

    # The snapshots' helpers are EngineSnapshots' (#build_engine_snapshots);
    # these forward to it.
    def served_model_for(...) = @engine_snapshots.served_model_for(...)
    def kit_prompt_stats = @engine_snapshots.kit_prompt_stats

    # The window as +model+'s loop would see it (EffectiveModel#context_window).
    def current_context_window(model) = model.context_window

    # +settings+' chips (EngineSnapshots#setting_chips).
    def setting_chips(settings, model) = @engine_snapshots.setting_chips(settings, model)

    # The effective model now, resolved on each call, never kept
    # (SessionModelSettings#effective_model). Raises as HostRegistry#resolve does.
    # @return [EffectiveModel]
    def effective_model(choice = @model_binding.choice) = @model_settings.effective_model(choice)

    # ── Prompt profile ─────────────────────────────────────────────────────────

    # The profile's resolve, keep, apply and retry are ModelBinding's
    # (#build_model_binding); these forward to it.
    def resolve_profile(choice) = @model_binding.resolve_profile(choice)
    def store_profile(choice, resolution) = @model_binding.store_profile(choice, resolution)
    def apply_profile(resolution) = @model_binding.apply_profile(resolution)
    def refresh_profile! = @model_binding.refresh_profile!
  end
end
