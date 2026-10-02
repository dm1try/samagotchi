# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"
require "yaml"

require_relative "config"
require_relative "context_note"
require_relative "context_status"
require_relative "steer"
require_relative "turn_note"
require_relative "model_profile"
require_relative "cancellation_controller"
require_relative "context_window"
require_relative "kernel_loop"
require_relative "tools/builtins"
require_relative "tools/task_runtime"
require_relative "session_commands"
require_relative "plugin/loader"
require_relative "log"
require_relative "log_subscriber"
require_relative "client"
require_relative "host_registry"
require_relative "llm/backend"
require_relative "llm/openai_chat"
require_relative "llm/turn_settings"
require_relative "session"
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
require_relative "guardrails"
require_relative "reminder_store"
require_relative "reminder_queue"
require_relative "tools/memory"
require_relative "muted_memories"
require_relative "used_memories"
require_relative "turn_state"
require_relative "bundle_needs"
require_relative "model_overlay"
require_relative "served_model"
require_relative "image_store"
require_relative "vision_context"
require_relative "vision_support"
require_relative "sampling_settings"
require_relative "thinking"
require_relative "answer_display"
require_relative "edit_preview"
require_relative "question_desk"
require_relative "guardrail_wiring"
require_relative "plugin_tasks"

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

    # @param client             [Client, nil] defaults to Client.new
    # @param profile            [ModelProfile, Symbol, String, nil]
    # @param session_id         [String, nil] resume an existing session
    # @param no_interrupt       [Boolean] --no-interrupt: every turn runs with
    #   NO_INTERRUPT_MAX_ITERATIONS, whichever loop runs it
    # @param model_name         [String, nil] defaults from SAMAGOTCHI_DEFAULT_MODEL
    # @param model_typed        [String, nil] the name the model was given as (a session's
    #   model_typed: an alias), for the models: lookup; model_name by default
    # @param memories           [Array<String>] explicit --memory preload list (merged with the config.yml `memories:` baseline)
    # @param muted_memories     [Array<String>] --mute list: memories hidden from this session (not in the
    #   prompt's index, dropped from the preloads, refused by memory_read); a mute wins over a preload
    # What memory_write answers in a scratch session.
    SCRATCH_MEMORY_WRITE = "Error: scratch session: nothing is saved"
    # A turn's iteration limit with no_interrupt (the worker's own
    # --no-interrupt turns pass the same).
    NO_INTERRUPT_MAX_ITERATIONS = 1000

    # @param plugins            [Boolean] false: load no bundle plugins (a throwaway Engine for a prompt)
    # @param scratch            [Boolean] a `chi scratch` session: memory writes are refused, and there is no
    #   delegate (a child would outlive it) nor plugin fork
    def initialize(client: nil, host_registry: nil, profile: nil, session_id: nil, no_interrupt: false, model_name: nil, memories: [], muted_memories: [], kernel: nil, recap: nil, reminders: nil,
                   plugins: true, scratch: false, model_typed: nil)
      # The turn as other threads see it (flag, cancel controller, sink,
      # steers) and the idle layer's activity clock. Built first: a plugin
      # may steer or ask whether a turn runs while it loads.
      @turn_state = TurnState.new(clock: -> { monotonic_now })
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
      @effective_model_name = @default_model_name
      # An injected client (specs) stands in for every host's client.
      @host_registry.client_override = client if client
      @client = @host_registry.resolve(@effective_model_name).client
      # A caller's profile pins it (until a model switch); otherwise
      # #profile_resolution decides on first need (see there), so building an
      # Engine makes no network call.
      @given_profile = profile ? ModelProfile.normalize(profile) : nil
      @typed_model_name = model_typed.to_s.strip.empty? ? @default_model_name : model_typed.to_s.strip
      @profile_resolution = nil
      # Ensure the built-in system bundle is installed (lazy, warn-only).
      # This is the single seam for both TUI and non-TUI (web/worker) paths.
      begin
        require_relative "memory_bundle/system_bundle"
        MemoryBundle::SystemBundle.ensure!
      rescue StandardError
        nil
      end
      # Load hooks from config (plugins) and create the registry; what fails
      # to load is announced, and a required guardrail's failure denies
      # every tool call. Rules load now too, so their errors are announced.
      @guardrail_wiring = GuardrailWiring.new(
        scratch: @scratch,
        hooks: -> { @hooks },
        tools: -> { @tools },
        session: -> { @session },
        model_key: -> { @model_key },
        model_name: -> { guardrail_model_name },
        cancelled: -> { !!active_cancel_controller&.cancelled? },
        ask: ->(fields) { open_question(fields) }
      )
      @guardrail_failures = @guardrail_wiring.failures
      # Plugins that failed to load: announced apart, as plugins (not
      # guardrails: no tool call is denied for them).
      @plugin_failures = Guardrails::LoadFailures.new
      # The question flow (ask_user_question, hooks' and plugins' ask_user,
      # approvals). Built before the hooks and plugins load: a plugin can ask
      # during its load (answered nil then: the interface is still
      # :non_interactive).
      @question_desk = QuestionDesk.new(
        session: -> { @session },
        state_dir: -> { session_state_dir },
        emit: ->(event) { emit_event(nil, event) },
        cancel_controller: -> { active_cancel_controller },
        interface: -> { interface },
        user_input: ->(sid) { ArchiveStore.user_input(sid, state_dir: session_state_dir) }
      )
      @hooks = load_hooks_from_config
      load_hooks_from_bundles
      # The tools this session offers (the prompts' declarations and the
      # kernel's dispatch): the built-ins, per Engine.
      @tools = Tools::Builtins.registry
      if @scratch
        # A scratch session's children would outlive it; its memories
        # would too (write and edit into the memories: ScratchWrites).
        [Tools::Delegate::NAME, Tools::DelegateResult::NAME].each { |name| @tools.unregister(name) }
        @tools[Tools::MemoryWrite::NAME].handler = ->(_call, _kctx) { SCRATCH_MEMORY_WRITE }
      end
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
      @plugin_tasks = PluginTasks.new(
        clock: -> { monotonic_now },
        synchronize_events: ->(&block) { synchronize_events(&block) },
        announce: ->(event) { announce(event) },
        emit: ->(sink, event) { emit_event(sink, event) },
        show_card: ->(**card) { show_card(**card) },
        tools: -> { @tools },
        notify: ->(text, level, source) { hook_notify(text, level, source) },
        tools_changed: -> { tools_changed! }
      )
      @lifecycle_mutex = Mutex.new
      @shut_down = false
      load_plugins if plugins
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
      # A given kernel (specs) gets the Engine's store, hooks and tools, as
      # the one built here does.
      @kernel = kernel || KernelLoop.new(client: @client, profile: @given_profile, hooks: @hooks, reminder_store: @reminder_store,
                                         tools: @tools)
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
      @kernel.guardrail_gate = @guardrail_wiring.gate
      # What a hook can do beyond reading its event (event[:notify],
      # event[:ask_user], event[:stop_turn]): the Engine's routes to the UIs.
      @hooks.runtime = hook_runtime
      # The loop follows the effective model's host (its api:): the raw-prompt
      # NativeBackend, or the chat backend for openai hosts.
      @native_backend = LLM::NativeBackend.new(kernel: @kernel)
      Log.debug(:model, "backend", provider: backend.provider) if Log.level?(:debug)
      @resume_session = session_id ? Session.load(session_id) : nil
      @prompt_builder = SystemPrompt.new(profile: -> { self.profile }, tools: -> { @tools }, session: -> { @session },
                                         thinking: -> { turn_thinking }, memories: memories,
                                         muted_memory_names: @muted_memory_names)
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
      @recap = RecapSetup.build(recap, engine: self, host_registry: @host_registry,
                                session_target: -> { session_model_recap_target },
                                session_id: -> { @session&.id }, state_dir: -> { session_state_dir })
      # One shared poller for the whole idle layer (reminders + optional
      # recap). Both jobs read the activity seam above; the scheduler owns
      # the single background thread and isolates per-job failures.
      @idle_scheduler = IdleScheduler.new(
        engine: self,
        jobs: [@reminders, @recap].compact
      )
      # The metrics collector is a persistent observer so every run_turn event
      # (the REPL, -p/--non-interactive/--resume and SessionManager workers)
      # feeds it automatically.
      @session_observer.subscribe(observer: @metrics)
      # And the event trail in the debug log (`turn` records).
      @session_observer.subscribe(observer: LogSubscriber.new(session_id: -> { @session&.id }))
    end

    # A monotonically-increasing clock (wall clock can jump backwards; the idle
    # detector must never treat a jump as "activity"). Injectable for specs.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # The backend for the next turn: the loop the effective model's host speaks.
    def backend
      backend_for(@host_registry.resolve(@effective_model_name))
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

    # The drain a turn's loop gets: the caller's lines (a UI's steering; nil
    # in a --non-interactive run) and the plugin steers. At the after-answer
    # boundary the steers are dropped: the model answered, and a nudge would
    # only restart the turn. The steer part fails on its own, never taking
    # the user's lines with it.
    def turn_drain(pending_input)
      lambda do |at_answer: false|
        lines = pending_input ? Array(pending_input.call) : []
        lines + take_steers(at_answer)
      end
    end
    private :turn_drain

    def take_steers(drop)
      steers = @turn_state.take_steers
      return steers unless drop

      log_dropped_steers(steers, "answered")
      []
    rescue StandardError
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
    # +covered+ counts the session messages it summarizes.
    def emit_recap(recap:, generation:, covered: nil)
      @session_observer.notify(type: :recap_ready, recap: recap, generation: generation, covered: covered)
    end

    # @return [SessionMetrics] the per-session analytics collector
    attr_reader :metrics
    # effective_model_name: the model as given (maybe an alias; HostRegistry#resolve
    # applies it); typed_model_name: as typed at start or at the last /model.
    attr_reader :default_model_name, :effective_model_name, :typed_model_name

    # The resolved ref a session stores for the effective model (ModelRef#ref:
    # the alias applied, "host:id" when it names a host).
    def effective_model_ref
      model_ref_for(@effective_model_name)
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
      session.model_typed = @typed_model_name.to_s == ref ? nil : @typed_model_name
      session
    end

    # The effective model's key (ModelOverlay.key_for its bare name): memory
    # overlays, guardrail rules' models:.
    # @return [String, nil]
    attr_reader :model_key

    # The prompt profile for the effective model (see #profile_resolution).
    # @return [ModelProfile]
    def profile = profile_resolution.profile

    # Which profile the effective model gets and where that came from
    # (ModelProfile.resolve: --profile/env, models:, hosts.<name>.profile,
    # the server's chat template, the name, qwen36). Resolved on first need
    # and kept, so the system prompt and the server's KV prefix stay stable;
    # #switch_model! starts over, and a failed server probe is retried before
    # the next turn (#refresh_profile!). The kernel follows each resolution.
    # @return [ModelProfile::Resolution]
    def profile_resolution
      @profile_resolution ||= apply_profile(resolve_profile)
    end
    attr_reader :host_registry, :client

    # @return [Commands::Registry] the commands this session runs: the
    #   built-ins, and the ones bundle plugins add
    attr_reader :command_registry

    # The model id sent for +full_ref+ (its alias applied, the host prefix off).
    def bare_model_name(full_ref)
      @host_registry.bare_name(full_ref)
    end

    # The memory overlay key follows the model sent (ModelOverlay.key_for
    # its id). A model typed as an alias used to key overlays by the alias
    # (before aliases were applied there): that key is read when the
    # target's overlay is missing (KernelLoop#sync_model_key!).
    def sync_model_key!
      @model_key = ModelOverlay.key_for(bare_model_name(@effective_model_name))
      typed_key = ModelOverlay.key_for(@host_registry.parse_qualified_model(@typed_model_name).last)
      fallback = typed_key == @model_key ? nil : typed_key
      @kernel.sync_model_key!(@model_key, fallback: fallback)
    end
    private :sync_model_key!

    # The effective model's bare name for the guardrails' models: rules;
    # nil without a model name.
    def guardrail_model_name
      name = @effective_model_name && bare_model_name(@effective_model_name)
      name.to_s.strip.empty? ? nil : name
    end

    # Point the kernel (and a chat backend) at the effective model's host
    # (after /model, --model, resume).
    def sync_kernel_client!
      target = @host_registry.resolve(@effective_model_name)
      @client = target.client
      @kernel.client = target.client if @kernel.client != target.client
      backend_for(target)
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
    ANNOUNCEABLE_EVENTS = %i[turn_enqueued input_merged prompt_restored continue_offered continue_resolved
                             command_queued command_ran context_added card hook_notice guardrail_warning
                             plugin_init_started plugin_init_finished].freeze

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
    def synchronize_events(&block)
      @session_observer.synchronize(&block)
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
                   from_cwd: note[:from_cwd], text: note[:text],
                   created_at: note[:created_at] }.compact)
        message
      end
    end

    # ── Cards ───────────────────────────────────────────────────────────────

    CARD_LEVELS = %i[info warn].freeze
    MAX_CARD_ACTIONS = 6

    # Show a card in every UI (docs/plugins.md, Cards): {type: :card, id:,
    # source:, title:, body:, level:, actions: [{label:, command:}], in_turn:}.
    # During a turn it is a turn event (the turn's sink and the observers),
    # else it is announced. A card with the id of an earlier one replaces it
    # (btw's "thinking…" → the answer).
    # @param source [String] who shows it (a bundle's name)
    # @param actions [Array<Hash>] {label:, command:}; a command is a line
    #   the session runs, as typed (D3)
    # @return [String] the card's id
    # @raise [ArgumentError] a card without a title, or a bad action
    def show_card(source:, title:, body: "", actions: [], level: :info, id: nil)
      card = build_card(source: source, title: title, body: body, actions: actions, level: level, id: id)
      return hold_load_event(card.merge(in_turn: true))[:id] if @loading_plugins
      return announce_anytime(card.merge(in_turn: false))[:id] if anytime_thread?
      # A plugin's init task (chi.init): never a running turn's event.
      return announce(card.merge(in_turn: false)) && card[:id] if current_init_task

      in_turn, sink = @turn_state.in_turn_sink
      card[:in_turn] = in_turn ? true : false
      if in_turn
        emit_event(sink, card)
      else
        announce_or_hold(card)
      end
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

    # Start an anytime command on its own thread (D8), one #shutdown waits
    # for, so its command_ran is announced before the process leaves.
    # @return [Thread]
    def spawn_anytime(&block)
      thread = Thread.new(&block)
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
    def add_init_task(bundle:, label:, plugin_label:, provides_tools:, quiet:, timeout:, failed: nil, &block)
      @plugin_tasks.add(bundle: bundle, label: label, plugin_label: plugin_label, provides_tools: provides_tools,
                        quiet: quiet, timeout: timeout, failed: failed, &block)
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
    # REPL renders events): the guardrail and plugin warnings, then the
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
        Array(@plugin_load_events).each do |event|
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

    def build_card(source:, title:, body:, actions:, level:, id:)
      title = title.to_s.strip
      raise ArgumentError, "a card needs a title" if title.empty?

      level = level.to_s.to_sym
      raise ArgumentError, "card level must be one of #{CARD_LEVELS.join(", ")}" unless CARD_LEVELS.include?(level)

      actions = Array(actions)
      raise ArgumentError, "a card has at most #{MAX_CARD_ACTIONS} actions" if actions.size > MAX_CARD_ACTIONS

      actions = actions.map do |action|
        raise ArgumentError, "a card action is a Hash {label:, command:}" unless action.is_a?(Hash)

        action = action.transform_keys(&:to_sym)
        command = action[:command].to_s.strip
        raise ArgumentError, "a card action needs a command" if command.empty? || command.include?("\n")

        label = action[:label].to_s.strip
        { label: label.empty? ? command : label, command: command }
      end
      id = id.to_s.strip
      { type: :card, id: id.empty? ? SecureRandom.hex(4) : id, source: source.to_s, title: title, body: body.to_s,
        level: level, actions: actions }
    end
    private :build_card

    # ── Model switching ────────────────────────────────────────────────────────

    # @param typed [String, nil] the name the model was typed as when
    #   +model_name+ is a stored ref (a resumed session's model_typed)
    # @return [String] the resolved ref the session stores (ModelRef#ref)
    def switch_model!(model_name, persist_default: false, typed: nil)
      # The alias is applied where the model is resolved (HostRegistry#resolve),
      # once; checked here: an unknown host, an alias naming another host.
      resolved = ModelProfile.check_host!(ModelProfile.required_model_name(model_name), hosts: @host_registry.entries)
      @effective_model_name = resolved
      @typed_model_name = typed.to_s.strip.empty? ? model_name : typed.to_s.strip
      # A profile given to .new was for the starting model.
      @given_profile = nil
      @profile_resolution = nil
      sync_model_key!
      @prompt_builder.reset!
      sync_kernel_client!
      @client.invalidate_context_window!
      @metrics.forget_model_reports!
      ref = effective_model_ref
      if persist_default
        ConfigFile.write_default_model!(ref)
        @default_model_name = ref
      end
      ref
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
    def register_hook(name, &block)
      @hooks.register(name, &block)
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

    # The metrics for /stats. Before the first generation reports them, the
    # context window, the served model and (on a native host) the prompt
    # profile come from the effective model's server, so this may make one
    # short /props GET; the cheap #session_state_snapshot never does.
    # @return [Hash] @metrics.snapshot, filled in
    def stats_snapshot
      snapshot = @metrics.snapshot
      target = @host_registry.resolve(@effective_model_name)
      served, served_for = served_model_for(snapshot, target: target)
      snapshot = snapshot.merge(served_model: served, served_model_for: served_for)
      unless snapshot.dig(:context, :window_tokens)
        window = current_context_window(target)
        if window
          snapshot = snapshot.merge(context: snapshot[:context].merge(window_tokens: window.tokens,
                                                                      window_source: window.source.to_s))
        end
      end
      # The chat loop uses no prompt profile: drop one a native turn reported.
      return snapshot.except(:profile, :profile_source) if target.entry.chat?

      unless snapshot[:profile]
        resolution = profile_resolution
        snapshot = snapshot.merge(profile: resolution.profile.name, profile_source: resolution.label)
      end
      snapshot
    end

    # The status line's ctx from the saved context, for a worker that has run
    # no turn yet (it woke after an idle exit): nil when either count is
    # unknown or context.status is off.
    def saved_context_status(context)
      return nil unless context

      ContextStatus.new.display_for(used_tokens: context[:used_tokens], window_tokens: context[:window_tokens])
    end

    # The effective model is on a chat host (api: openai), whose loop uses
    # no prompt profile.
    def chat_model? = @host_registry.resolve(@effective_model_name).entry.chat?

    # "temperature=0.6 (hosts.work)" for /model: the effective model's
    # configured sampling, nil when none.
    def sampling_summary
      target = @host_registry.resolve(@effective_model_name)
      SamplingSettings.summary(target, names: model_lookup_names(target))
    rescue StandardError
      nil
    end

    # "off (models: qwen)" for /model: the effective model's thinking level
    # and where it came from, nil when none is set.
    def thinking_summary
      target = @host_registry.resolve(@effective_model_name)
      level, source = Thinking.resolve(target, names: model_lookup_names(target))
      source ? "#{level} (#{source})" : nil
    rescue StandardError
      nil
    end

    # The model the server serves for the current model, and the name asked
    # for: what the last generation of that name reported, else llama.cpp's
    # model_alias (/props, one short cached probe; not with probe: false),
    # else [nil, nil].
    # @return [Array(String, String), Array(nil, nil)]
    def served_model(probe: true)
      served_model_for(@metrics.snapshot, target: probe ? @host_registry.resolve(@effective_model_name) : nil)
    end

    # Read-only snapshot of the engine's view of the current session plus the
    # live event sequence. Cheap primitive used by the bridge's reconnect-too-
    # old reset marker and the GET /session/:id/state read surface. Orthogonal
    # to the transport — safe to call before the first turn (nil session).
    #
    # @return [Hash] with keys:
    #   :status        [String, nil] current session status
    #   :message_count [Integer]   number of messages in the session
    #   :last_prompt   [String, nil] the last user prompt (empty string if none)
    #   :event_seq     [Integer]   @session_observer.event_count
    #   :metrics       [Hash]      @metrics.snapshot (per-session analytics)
    #   :pending_question [Hash, nil] current pending structured question
    #   :used_memory_names [Array<String>] deduped memory names active this session
    #   :parent_id     [String, nil] the session that delegated this one
    #   :model_name    [String]    the model turns run on now (after /model)
    #   :served_model, :served_model_for [String, nil] what a generation of
    #     that model reported serving, and the name asked (#served_model
    #     without the probe)
    #   :recap_enabled [Boolean]   whether an idle recap is configured, with
    #     :recap_min_user_turns and :recap_inactivity_seconds (nil when not)
    def session_state_snapshot
      served_pair = served_model(probe: false)
      metrics = @metrics.snapshot
      {
        status: @session&.status,
        message_count: (@session&.messages || []).size,
        last_prompt: @session&.last_prompt,
        event_seq: @session_observer&.event_count,
        metrics: metrics,
        pending_question: @question_desk.pending,
        used_memory_names: @used_memories.names,
        preloaded_memory_names: preloaded_memory_names,
        muted_memory_names: @muted_memory_names.dup,
        parent_id: @session&.parent_id,
        model_name: effective_model_ref,
        served_model: served_pair[0],
        served_model_for: served_pair[1],
        context_status: @last_context_status&.dup || saved_context_status(metrics[:context]),
        recap_enabled: !@recap.nil?,
        recap_min_user_turns: @recap&.min_user_turns,
        recap_inactivity_seconds: @recap&.inactivity&.to_i
      }
    end

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
    # (label: "plugins"; the UIs say guardrails without one), then the
    # notices and cards plugins showed as they loaded.
    def announce_guardrail_failures(on_event)
      return if @guardrail_failures_announced

      @guardrail_failures_announced = true
      message = @guardrail_failures.message
      emit_event(on_event, { type: :guardrail_warning, message: message }) if message
      plugins = @plugin_failures.message
      emit_event(on_event, { type: :guardrail_warning, message: plugins, label: "plugins" }) if plugins
      Array(@plugin_load_events).each { |event| emit_event(on_event, event) }
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
    # save puts it in the file the session hub watches.
    def record_last_turn(session, outcome, seconds, origin)
      client_id = origin.is_a?(Hash) ? origin[:client_id].to_s : ""
      source = if client_id.start_with?("#{Tools::Delegate::CLIENT_PREFIX}:") then "delegate"
               elsif client_id == SessionManager::REMINDER_CLIENT_ID then "reminder"
               else "client"
               end
      session.last_turn = { "outcome" => outcome, "ended_at" => Time.now.iso8601(3),
                            "seconds" => seconds.round(1), "origin" => source }
    end
    private :record_last_turn

    # How every turn ends (completed, canceled, failed): the session gets
    # what the turn kept, goes idle and records the ending, and the end
    # event is announced, as one step of the event log (a snapshot taken
    # meanwhile, the Bridge's, shows the turn either in progress or in the
    # messages, never both or neither). Then the metrics are persisted.
    # The block runs in that step with the turn's seconds, once, and
    # returns [the messages to keep (nil: leave the session's), the end
    # event]. +save:+ also saves the session (a failed turn: a worker exits
    # after it). The disk writes come after the step: every emitter waits
    # for the event lock.
    def end_turn(turn, outcome, save: false)
      seconds = turn.elapsed
      synchronize_events do
        kept, event = yield(seconds)
        replace_session_messages(turn.session, kept) if kept
        turn.session.status = Session::STATUS_IDLE
        record_last_turn(turn.session, outcome, seconds, turn.origin)
        emit_event(turn.on_event, turn.tag(event))
      end
      turn.ended = true
      save_quietly(turn.session) if save
      @metrics.persist(state_dir: session_state_dir)
    end
    private :end_turn

    def save_quietly(session)
      session.save(state_dir: session_state_dir)
    rescue StandardError
      nil
    end
    private :save_quietly

    # Keep what the after_turn hooks presented as the answer's `display`
    # and tell the observers (:answer_display), after the turn_completed
    # they already had: the web re-reads the answer then. A turn_completed
    # with display_pending (after_turn hooks were about to run) always gets
    # one, `display: nil` when nothing was presented, so the web holds the
    # answer's pop until then and never swaps it after. Terminals are not
    # sinks of it; they printed the answer already. The session is saved by
    # the caller, as after every turn.
    def store_answer_display(session, display, pending: false)
      synchronize_events do
        messages = Array(session.messages)
        if display.changed? && messages.last.equal?(display.target)
          replace_session_messages(session, messages[0...-1] + [display.target.merge(AnswerDisplay::KEY => display.text)])
          @session_observer.notify({ type: :answer_display, display: display.text })
        elsif pending
          @session_observer.notify({ type: :answer_display, display: nil })
        end
      end
    end
    private :store_answer_display

    # ── The hook runtime (Hooks::Runtime) ─────────────────────────────────────

    # The three things a hook can do beyond reading its event. Each gets the
    # hook's label (event[:hook]) from the registry.
    def hook_runtime
      Hooks::Runtime.new(
        notify: ->(text:, level:, hook:) { hook_notify(text, level, hook) },
        ask_user: ->(question:, options:, header:, allow_freeform:, hook:) { hook_ask_user(question, options, header, allow_freeform, hook) },
        stop_turn: ->(reason:, hook:) { hook_stop_turn(reason, hook) },
        steer: ->(text:, hook:) { steer(text, source: hook_source(hook)) },
        stop_generation: ->(reason:, hook:) { hook_stop_generation(reason, hook) }
      )
    end
    private :hook_runtime

    # What a steer is attributed to: the bundle of a bundle hook's label
    # ("<file> (bundle <name>)"), the label of any other.
    def hook_source(hook)
      hook.to_s[/\(bundle (.+)\)\z/, 1] || hook.to_s
    end
    private :hook_source

    # One line to the user (:hook_notice). During a turn it is a turn
    # event: the turn's sink (the REPL) and the observers (bridge, log).
    # Outside one (a plugin's command at the prompt) it is announced with
    # between_turns: true, which every UI shows as cards are shown.
    def hook_notify(text, level, hook)
      level = (level || :info).to_sym
      level = :info unless %i[info warn].include?(level)
      notice = { type: :hook_notice, hook: hook.to_s, text: text.to_s, level: level }
      return hold_load_event(notice) && nil if @loading_plugins

      in_turn, sink = @turn_state.in_turn_sink
      if anytime_thread?
        announce_anytime(notice.merge(between_turns: true))
      elsif current_init_task
        announce(notice.merge(between_turns: true))
      elsif in_turn
        emit_event(sink, notice)
      else
        announce_or_hold(notice.merge(between_turns: true))
      end
      nil
    end
    private :hook_notify

    # A question through the question flow (REPL sync handler, attached TUI,
    # web), single-select, kind "hook". A --non-interactive run has no one
    # to ask: nil at once. Anything but an answer (a sync handler's text, no
    # answer, cancelled) is nil too.
    # @return [Hash, nil] {selected:, freeform:, selected_indices:}
    def hook_ask_user(question, options, header, allow_freeform, hook)
      @question_desk.ask_for_hook(question, options, header, allow_freeform, hook)
    end
    private :hook_ask_user

    # Cancel the running turn (reason :hook), after a notice that says why.
    # The gate denies the rest of a tool batch once the controller is
    # cancelled; the next request ends the turn as :turn_canceled.
    # @return [Boolean] true when a running turn was cancelled now
    def hook_stop_turn(reason, hook)
      ctrl = active_cancel_controller
      return false unless ctrl && !ctrl.cancelled?

      hook_notify("stopped the turn: #{reason}", :warn, hook)
      ctrl.cancel!(:hook, { by: hook_source(hook), reason: reason.to_s })
    end
    private :hook_stop_turn

    # Cut the streaming generation (reason :hook); the turn goes on and asks
    # the model again (the loops' cut path). No notice: the plugin posts its
    # own. The bundle and +reason+ go to the log and the retry's nudge.
    # @return [Boolean] true when a streaming generation was cut now
    def hook_stop_generation(reason, hook)
      ctrl = active_cancel_controller
      return false unless ctrl

      ctrl.cancel_generation!(:hook, { by: hook_source(hook), reason: reason.to_s })
    end
    private :hook_stop_generation

    # ── Ask-user-question (structured qualification) ──────────────────────────

    # @return [Hash, nil] current pending question (thread-safe copy)
    def pending_question
      @question_desk.pending
    end

    # Ask the model's question (ask_user_question): the kernel's
    # question_handler, called on the turn thread with the payload
    # Tools::AskUserQuestion.validate made (QuestionDesk#request).
    # @param payload [Hash] {question:, options:, header:, multi_select:, allow_freeform:}
    # @return [String] normalized answer JSON
    def request_question(payload)
      @question_desk.request(payload)
    end

    QUESTION_DISMISSED_NOTE = QuestionDesk::DISMISSED_NOTE

    # Open a question for the UIs and wait for its answer
    # (QuestionDesk#open_question: BLOCKS until answered or cancelled).
    # @param fields [Hash] question:, options:, header:, multi_select:, allow_freeform:, …
    # @return [Hash, String] the answer, or {error:, …}
    def open_question(fields)
      @question_desk.open_question(fields)
    end

    # Answer the pending question (called from UI thread; QuestionDesk#answer).
    # @return [Hash] normalized answer
    def answer_question(id:, selected:, freeform: nil)
      @question_desk.answer(id: id, selected: selected, freeform: freeform)
    end

    def set_question_sync_handler(&block)
      @question_desk.sync_handler = block
    end

    # Cancel the pending question (QuestionDesk#cancel).
    # @return [Boolean] whether it was cancelled
    def cancel_question(reason = "user", id: nil)
      @question_desk.cancel(reason, id: id)
    end

    # The system prompt for a target's loop (default: the effective model's):
    # the chat loop's leaves out the raw-prompt tool text, since its tools go
    # as schemas. Built once per loop (and again after a model switch) so the
    # prompt prefix, and the server's KV cache for it, stay stable.
    # @param target [HostRegistry::ModelTarget, nil]
    # @return [String]
    # The native prompt depends on the thinking level too (Gemma's token,
    # Qwen's turn preamble): a level change builds it again.
    def system_prompt(target = nil)
      target ||= @host_registry.resolve(@effective_model_name)
      chat = target.entry.chat?
      level = chat ? nil : thinking_level(target)
      @prompt_builder.build(chat: chat, thinking: level)
    end

    # The base prompt (specs, plugins' declarations).
    def assist_system_prompt(chat: false, thinking: nil)
      @prompt_builder.base(chat: chat, thinking: thinking)
    end

    # The --memory names activated while building the prompt; the TerminalUI
    # mirrors them into its status line.
    def activated_memory_names
      @prompt_builder.activated_memory_names
    end

    # @return [Session] current session (Engine owns create/resume)
    def session
      @session
    end

    # The kernel's Tools::Peers, following the current session. cancelled?
    # is the running turn's cancel, for a tool that waits (delegate_result):
    # the controller is set from another thread and a tool gets no other
    # way to see it.
    PeerView = Struct.new(:engine) do
      def session_id = engine.session&.id
      def cwd = engine.session&.working_directory
      def state_dir = engine.peer_state_dir
      def cancelled? = !!engine.active_cancel_controller&.cancelled?
    end

    # @return [String] the state dir holding this Engine's sessions
    def peer_state_dir = @state_dir

    # Set the current session outside a turn (the REPL does, before its first
    # turn, so the messages API and recap see it)
    def session=(session)
      @session = session
      # One session per REPL/worker process: its records carry this sid.
      Log.session_id = session.id if session&.id
      # A woken worker's /stats and status line count the turns before it.
      bind_metrics(session)
      @used_memories.absorb(session)
    end

    # @return [IdleRecap, nil] the idle recap detector, or nil when disabled
    def recap
      @recap
    end

    # Write the recap now, before the session is left (IdleRecap#write_now).
    # @return [String, nil] the recap written, nil when none was (recap off,
    #   nothing new, an error, the timeout)
    def write_recap_now(on_start: nil)
      @recap&.write_now(on_start: on_start)
    end

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

    # Stop the shared idle scheduler (TerminalUI calls this when the REPL exits).
    def stop_idle
      @idle_scheduler&.stop
      self
    end

    # One turn's values, for #run_turn and its endings. Per turn and
    # single-threaded: the cross-thread turn state (the cancel slot, the
    # sink, steers) stays on the Engine.
    # +ended+: the end event is out (what follows is post-turn work).
    # +settings+: the kernel's LLM::TurnSettings, made in #prepare_turn and
    # set on the kernel in #generate.
    Turn = Struct.new(:session, :prompt, :continue, :on_event, :controller, :origin, :started_at, :messages, :ended,
                      :settings) do
      # The turn's boundary events carry the origin only when there is one,
      # so payloads stay unchanged for callers that don't pass it.
      def tag(event) = origin ? event.merge(origin: origin) : event

      # Seconds since the turn started (the cancel note says how long it ran).
      def elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
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
    # @param max_iterations [Integer] max kernel iterations
    # @param cancel_controller [CancellationController, nil]
    # @param max_tool_output_chars [Integer, nil] per-output char cap for the
    #   :tool_call_completed event's `output:` (nil → max_tool_output_chars)
    # @return [LLM::ModelResult]
    # @param pending_input [#call, nil] optional drain proc returning
    #   Array<String> of steering messages queued while the turn runs; drained
    #   by the agentic loop at iteration boundaries (see KernelLoop#run).
    # @param continue [Boolean] resume the conversation without appending a
    #   user prompt (continue after the iteration limit, reminder turns);
    #   +prompt+ is ignored and :turn_started carries `continue: true`
    # @param origin [Hash, nil] who queued the turn ({client_id:, enqueued_id:});
    #   when given, the turn's boundary events (:turn_started, :turn_completed,
    #   :turn_canceled, :turn_failed) carry it as `origin:`
    # @param images [Array<Hash>] the prompt's images: {path:} (a file on this
    #   machine; in-process and attached-TUI callers only) or {file:, name:}
    #   (already in the session's images/, e.g. a web upload). They are
    #   stored/validated before :turn_started (which carries their refs), and
    #   a model known not to see images fails the turn before anything of it
    #   is kept (VisionUnsupported).
    #
    # An Interrupt (SIGINT) cancels the turn: the pre-turn conversation plus
    # the prompt is kept in the session and :turn_canceled is emitted, then the
    # Interrupt is re-raised so the caller still decides whether to exit. One
    # after the turn's end event (in its after_turn/session_end hooks) is
    # only re-raised: the turn already ended; so is any error there. Any
    # other error (e.g. an LLM::ProviderError) emits :turn_failed and
    # re-raises; a provider error adds error_kind:, retryable:, host: and a
    # one-line summary:.
    def run_turn(session, prompt, on_event: nil, max_iterations: 100, cancel_controller: nil, max_tool_output_chars: nil, pending_input: nil, continue: false, origin: nil,
                 images: [])
      turn = begin_turn(session, prompt, on_event: on_event, cancel_controller: cancel_controller, origin: origin,
                                         continue: continue)
      begin
        # A Stop cuts the /props probes this thread makes for the turn
        # (window, served model, vision) instead of waiting their timeout.
        probe_cancel_before = Client.swap_probe_cancel(turn.controller)
        return stopped_before_model(turn) unless prepare_turn(turn, continue ? [] : images)

        result = generate(turn, max_iterations: max_iterations, max_tool_output_chars: max_tool_output_chars,
                                pending_input: pending_input)
        publish_used_memories(session, on_event)
        complete_turn(turn, result)
        result
      rescue Interrupt
        # After the end event (in the after_turn/session_end hooks) the
        # turn is over: no second ending, the answer stays.
        raise if turn.ended

        turn.controller.cancel!(:ctrl_c)
        end_turn(turn, "canceled") do |seconds|
          [ctrl_c_messages(turn, seconds), { type: :turn_canceled, cancellation_reason: :ctrl_c, duration_ms: (seconds * 1000).round }]
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
    def begin_turn(session, prompt, on_event:, cancel_controller:, origin:, continue:)
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
               controller: effective_controller, origin: origin, started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    end
    private :begin_turn

    # Everything before the model is asked: :turn_started, the kernel's
    # per-turn settings, the plugins' setup, the session_start/before_turn
    # hooks, then the messages to send (#turn_messages). False when a Stop
    # came before the hooks (the turn ends canceled there), else true.
    def prepare_turn(turn, images)
      session = turn.session
      image_refs, image_error = turn_image_refs(session, images)
      # Emit turn_started event
      bind_metrics(session)
      turn_started = { type: :turn_started, session_id: session.id, prompt: turn.prompt }
      turn_started[:continue] = true if turn.continue
      turn_started[:images] = image_refs unless image_refs.empty?
      emit_event(turn.on_event, turn.tag(turn_started))
      raise image_error if image_error

      # Ask the server for its window again each turn (one short /props GET,
      # cached across the turn's generations): a restart with another -c
      # between turns raises no error that would drop the cache. The
      # profile may probe too (a first turn, a retry). Both run after
      # run_turn's probe-cancel swap, so a Stop cuts them, and a failure
      # ends the turn as turn_failed.
      @client.invalidate_context_window!
      refresh_profile!

      # Before anything of the turn is kept or a reminder is used up.
      turn.settings = turn_settings(session)
      refuse_images!(turn.settings.vision) unless image_refs.empty?
      announce_guardrail_failures(turn.on_event)
      # Plugins' slow setup that brings tools (an MCP server's first
      # start): the turn waits for it here, before the system prompt
      # declares the tools; a Ctrl-C ends the wait (the turn is cancelled
      # at its first request).
      start_init_tasks!
      await_init_tasks(turn.controller, turn.on_event)
      # Plugins' tool sets that changed since the last turn.
      apply_staged_tools!
      # A Stop during the probes or the wait above: the turn ends here,
      # before the hooks run or a reminder is used up.
      return false if turn.controller.cancelled?

      # Fire :session_start on the very first turn
      if @first_turn
        @hooks.fire(:session_start, { type: :session_start, session_id: session.id })
        @first_turn = false
      end

      # Fire :before_turn hook, with a read-only copy of the history so far
      # and the prompt (nil on a continue).
      @hooks.fire(:before_turn, { type: :before_turn, session_id: session.id, prompt: turn.prompt,
                                  messages: hook_messages(session.messages) })

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
        [nil, { type: :turn_canceled, cancellation_reason: reason, duration_ms: (seconds * 1000).round }]
      end
      LLM::ModelResult.new(text: "", canceled: true, cancellation_reason: reason)
    end
    private :stopped_before_model

    # The turn's settings for the kernel (LLM::TurnSettings): vision,
    # sampling and thinking, the thinking resolved before the hooks run.
    # The model name is added in #generate, after the hooks that may switch
    # the model.
    def turn_settings(session)
      vision = turn_vision(session)
      sampling = turn_sampling
      thinking_target = @host_registry.resolve(@effective_model_name)
      @turn_thinking = [thinking_level(thinking_target), thinking_target]
      announce_thinking_level(*@turn_thinking)
      LLM::TurnSettings.new(vision: vision, sampling: sampling, thinking: @turn_thinking.first, model_name: nil)
    end
    private :turn_settings

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
      due_reminders = @reminder_queue.inject!(turn.messages)
      if due_reminders.any?
        emit_event(turn.on_event, {
          type: :reminder_injected,
          reminders: due_reminders
        })
      end

      return if turn.continue

      user_message = { role: "user", content: turn.prompt }
      user_message[:images] = image_refs unless image_refs.empty?
      turn.messages << user_message
      session.last_prompt = turn.prompt
    end
    private :turn_messages

    # Ask the effective model's backend.
    def generate(turn, max_iterations:, max_tool_output_chars:, pending_input:)
      sync_kernel_client!
      # Route model name as bare (without host prefix) to the transport;
      # host selection already done via active client.
      bare_for_backend = bare_model_name(@effective_model_name)
      # The turn's settings, set once here. The chat loop dispatches tools
      # through the kernel without its #run: tag those dumps with this
      # turn's model, not the last native one.
      @kernel.turn_settings = turn.settings.with(model_name: bare_for_backend)

      backend.complete(
        messages: turn.messages,
        max_iterations: @no_interrupt ? NO_INTERRUPT_MAX_ITERATIONS : max_iterations,
        on_stream_event: build_stream_event_handler(turn.on_event, cancel_controller: turn.controller),
        cancel_controller: turn.controller,
        model_name: bare_for_backend,
        max_tool_output_chars: max_tool_output_chars,
        pending_input: turn_drain(pending_input)
      )
    end
    private :generate

    def publish_used_memories(session, on_event)
      # Persist deduped used memories onto the session for Web + reload.
      begin
        session.used_memory_names = used_memory_names
      rescue StandardError
        nil
      end
      # Notify live observers of the updated memory list (so yellow bar refreshes
      # even without a tool_call event if the preload was the only addition).
      # Only emit when there is something to report to avoid noisy event_count drift.
      return unless used_memory_names.any?

      begin
        emit_event(on_event, { type: :used_memories_updated, used_memory_names: used_memory_names })
      rescue StandardError
        nil
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
      end_turn(turn, canceled ? "canceled" : "completed") do |seconds|
        kept = kept_messages(turn, result, seconds)
        if canceled
          [kept, { type: :turn_canceled, cancellation_reason: result.cancellation_reason,
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
      # copy of the conversation the turn stored, and event[:present] for
      # a display version of the answer (AnswerDisplay).
      session = turn.session
      display = AnswerDisplay.new(session.messages)
      after_turn = { type: :after_turn, status: canceled ? "canceled" : "completed",
                     messages: hook_messages(session.messages) }
      after_turn[:present] = display.presenter(after_turn)
      @hooks.fire(:after_turn, after_turn)
      store_answer_display(session, display, pending: display_pending)

      # Fire :session_end after the turn (turn-level lifecycle), as :after_turn
      @hooks.fire(:session_end, { type: :session_end, session_id: session.id })
    end
    private :complete_turn

    # What the session keeps of a turn that ended normally (nil: nothing to
    # replace). Runs under the event lock: it also adds the turn's note to
    # result.conversation, which the REPL keeps as-is.
    # A turn that ran out of iterations ends at its tool results, so a
    # continue resumes from them rather than after a made-up reply.
    def kept_messages(turn, result, seconds)
      conversation = result.conversation if result.conversation.is_a?(Array)
      # Nothing visible (the native loop: no text; the chat loop: its
      # placeholder text) is a turn the model should know ended that way.
      if result.empty_answer?
        # The placeholder is for the UIs (a new array: it must not leak
        # into the result); the note is for the model, so it goes on the
        # result's conversation too.
        # A retry's nudge at the tail goes: this note says it all.
        note = TurnNote.empty
        conversation&.replace(TurnNote.without_trailing(conversation))
        saved = TurnNote.without_trailing(conversation || turn.session.messages)
        saved << { role: "model", content: "[No response]" } if result.output.to_s.strip.empty?
        conversation << note if conversation
        saved + [note]
      elsif result.canceled? && conversation
        conversation << TurnNote.cancelled(result.cancellation_reason, seconds: seconds,
                                                                      stopped_by: turn.controller.detail,
                                                                      shown: TurnNote.interrupted_tail?(conversation),
                                                                      running_tasks: Tools::TaskRuntime.running_created_in(conversation))
      else
        conversation
      end
    end
    private :kept_messages

    # A Ctrl-C keeps the turn's messages so far with a cancel note (nil
    # before there are any). Only the pre-turn messages survive here, so
    # tasks this turn started are missed (plan wait-stop §6).
    def ctrl_c_messages(turn, seconds)
      return nil unless turn.messages

      note = TurnNote.cancelled(:ctrl_c, seconds: seconds, running_tasks: Tools::TaskRuntime.running_created_in(turn.messages))
      TurnNote.replace_trailing(turn.messages, note)
    end
    private :ctrl_c_messages

    # A failure keeps the loop's partial conversation (else the turn's
    # messages so far) with a failed note; nil when the turn never reached
    # the model. The model reads why on its next turn (a UI that rolls the
    # turn back leaves its own note, TurnFlow#prompt_turn_failed).
    def failed_messages(turn, error)
      kept = error.respond_to?(:partial_conversation) && error.partial_conversation.is_a?(Array) ? error.partial_conversation : turn.messages
      return nil unless kept

      summary = error.respond_to?(:summary) ? error.summary : error.message
      TurnNote.replace_trailing(kept, TurnNote.failed(summary, continued: turn.continue))
    end
    private :failed_messages

    def failed_event(error, seconds)
      failed = { type: :turn_failed, error_class: error.class.name, message: error.message,
                 duration_ms: (seconds * 1000).round }
      # A provider error says what kind it is, for one line per kind in the UIs.
      if error.is_a?(LLM::ProviderError)
        failed.merge!(error_kind: error.kind, retryable: error.retryable?, host: error.host, summary: error.summary)
      end
      failed
    end
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
      Client.swap_probe_cancel(probe_cancel_before)
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
    def turn_vision(session)
      target = @host_registry.resolve(@effective_model_name)
      VisionContext.new(session_dir: Session.session_dir(session.id, state_dir: session_state_dir),
                        capability: lambda {
                          VisionSupport.for(target, profile: profile, adapter: vision_adapter(target), names: model_lookup_names(target))
                        })
    end

    # The effective model's request parameters (hosts: and models:
    # sampling), read per turn: /model can change the model between turns.
    def turn_sampling
      target = @host_registry.resolve(@effective_model_name)
      SamplingSettings.for(target, names: model_lookup_names(target))
    rescue StandardError
      SamplingSettings::EMPTY
    end

    # The effective model's thinking level (Thinking.resolve), read each turn.
    def turn_thinking
      thinking_level(@host_registry.resolve(@effective_model_name))
    rescue StandardError
      Thinking::DEFAULT
    end

    # An effort on a native host, which has no knob for it: said once per
    # session and host.
    def announce_thinking_level(level, target)
      return if target.entry.chat? || Thinking.native(level, profile).honoured

      thinking_notice_once(:unsupported, target, :info,
                           "#{level} isn't supported by native #{profile.name} on #{target.entry.name}; " \
                           "thinking stays as the model has it")
    rescue StandardError
      nil
    end

    # An effort on a llama.cpp chat host whose chat template takes none
    # (its /props says so): said once per session and host, as for a native
    # host. Read from the /props answer the turn's window probe left in the
    # cache, so it asks the server nothing.
    def announce_effort_ignored
      level, target = @turn_thinking
      return unless target&.entry&.chat? && Thinking::EFFORTS.include?(level)

      client = target.client
      props = client.cached_server_props(model: target.bare_model)
      return unless Thinking.effort_ignored?(level, props)

      thinking_notice_once(:unsupported, target, :info,
                           "#{level} isn't supported by #{target.bare_model}'s chat template on #{target.entry.name} " \
                           "(/props: supports_reasoning_effort false); thinking stays as the model has it")
    rescue StandardError
      nil
    end

    # Thinking off, and the model thought anyway: logged each time, said
    # once per session and host.
    def check_thinking_honoured(event)
      level, target = @turn_thinking
      chars = event[:thinking_chars].to_i
      return unless level == :off && chars.positive? && target

      Log.warn(:model, "thinking_not_honoured", level: level, host: target.entry.name, model: target.bare_model, chars: chars)
      thinking_notice_once(:not_honoured, target, :warn,
                           "off wasn't honoured by #{target.bare_model} on #{target.entry.name} " \
                           "(#{chars} chars of thinking); a sampling: override on the host or model may turn it off " \
                           "(see Thinking in docs/configuration.md)")
    rescue StandardError
      nil
    end

    # The host refused the level's request fields (gpt-oss can't turn
    # thinking off) and the chat loop sent the request without them: said
    # once per session and host, standing in for the not-honoured notice.
    def thinking_refused(event)
      _level, target = @turn_thinking
      return unless target

      Log.warn(:model, "thinking_refused", level: event[:level], host: target.entry.name, model: event[:model],
                                           detail: event[:detail])
      (@thinking_notices ||= Set.new) << [@session&.id, target.entry.name, :not_honoured]
      thinking_notice_once(:refused, target, :warn,
                           "#{target.entry.name} refused thinking: #{event[:level]} for #{event[:model]} (#{event[:detail]}); " \
                           "sent without it, so thinking stays as the model has it")
    rescue StandardError
      nil
    end

    def thinking_notice_once(kind, target, level, text)
      key = [@session&.id, target.entry.name, kind]
      return unless (@thinking_notices ||= Set.new).add?(key)

      hook_notify(text, level, "thinking")
    end

    # +target+'s thinking level (Thinking.resolve).
    def thinking_level(target)
      Thinking.resolve(target, names: model_lookup_names(target)).first
    rescue StandardError
      Thinking::DEFAULT
    end

    def vision_adapter(target)
      target.entry.chat? ? @host_registry.adapter_for(target.entry) : nil
    rescue StandardError
      nil
    end

    # A model known not to see images fails a turn with images up front.
    def refuse_images!(vision)
      return if vision.sendable?

      host = @host_registry.resolve(@effective_model_name).entry.name
      raise LLM::VisionUnsupported.new("#{host}: #{vision.refusal_reason}", host: host)
    end

    # JSON-safe digest of a finished turn for renderers (in-process or over the
    # Bridge): the bits of the native loop's result a UI needs beyond `result:`.
    # @param result [LLM::ModelResult]
    # @return [Hash]
    def turn_summary(result)
      {
        output: result.output.to_s,
        exhausted: result.exhausted?,
        resumable: result.resumable?,
        pending_tool_calls: result.pending_tool_calls?,
        tool_activity: Array(result.tool_activity).map(&:dup),
        context_status: result.context_status&.dup
      }
    end

    # ── Session messages API ───────────────────────────────────────────────
    #
    # Out-of-turn edits to the current session's conversation (`!cmd` output,
    # rollback after Ctrl-C). Each replaces the array rather than mutating it,
    # so the recap's lock-free snapshot never sees a half-applied edit.

    # @return [Array<Hash>] a copy of the current session's messages to hand
    #   back to #rollback_to later
    def messages_checkpoint
      clone_messages(@session&.messages)
    end

    # Append messages to the current session's conversation.
    # @param messages [Array<Hash>]
    # @return [Array<Hash>] the session's messages
    def append_messages(messages)
      raise ArgumentError, "no current session" unless @session

      replace_session_messages(@session, Array(@session.messages) + clone_messages(messages))
    end

    # Restore the current session's conversation to a #messages_checkpoint.
    # @param checkpoint [Array<Hash>]
    # @return [Array<Hash>] the session's messages
    def rollback_to(checkpoint)
      raise ArgumentError, "no current session" unless @session

      replace_session_messages(@session, clone_messages(checkpoint))
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

    # Pick the loop for a target; the chat loop is pointed at the target
    # host's adapter (one per host, kept for its cached model list).
    def backend_for(target)
      return @native_backend unless target.entry.chat?

      @chat_backend_mutex.synchronize do
        @chat_backend ||= LLM::ChatLoop.new(kernel: @kernel)
        @chat_backend.adapter = @host_registry.adapter_for(target.entry)
        @chat_backend.session_id = session&.id
        @chat_backend
      end
    end

    # Load hooks from the global config file using the Hooks::Loader.
    # Returns a Registry with all plugins registered (or an empty Registry if
    # no hooks config is present).
    def load_hooks_from_config
      config_path = Samagotchi::ConfigFile.global_path
      data = Samagotchi::ConfigFile.read_yaml(path: config_path)
      return Hooks::Loader.load(data, failures: @guardrail_failures) if data.is_a?(Hash)
      Hooks::Registry.new
    end

    def load_hooks_from_bundles
      require_relative "memory_bundle/provenance"
      settings = bundle_settings
      MemoryBundle::Provenance.each_installed(holding: :hooks) do |bundle_name, data|
        if data[:error]
          Log.warn(:hooks, "bundle_manifest_invalid", echo: "[samagotchi:hooks] bundle '#{bundle_name}': #{data[:error]}; its hooks are not loaded",
                                                      bundle: bundle_name)
          @guardrail_failures.add("hooks (bundle #{bundle_name})", data[:error], required: false)
          next
        end
        bundle_dir = File.join(MemoryBundle::Provenance.bundles_dir, bundle_name)
        hooks_dir = File.join(bundle_dir, "hooks")
        if (data[:trust_level] || "experimental").to_s == "experimental"
          Log.info(:hooks, "experimental_bundle", echo: "[hooks] Bundle '#{bundle_name}' is experimental — its hooks may change or misbehave.", bundle: bundle_name)
        end
        begin
          Hooks::BundleLoader.load(bundle_name: bundle_name, hooks_dir: hooks_dir, metadata: data[:hooks], registry: @hooks,
                                   failures: @guardrail_failures, settings: settings[bundle_name.to_s] || {},
                                   requires_chi: data[:requires_chi])
        rescue Exception => e
          Log.error(:hooks, "bundle_load_failed", echo: "[samagotchi:hooks] bundle '#{bundle_name}' failed to load hooks: #{e.class}: #{e.message}", bundle: bundle_name, error: e.class.name)
        end
      end
    rescue Exception => e
      Log.error(:hooks, "bundles_load_failed", echo: "[samagotchi:hooks] failed to load bundle hooks: #{e.class}: #{e.message}", error: e.class.name)
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
        }
      )
      # What plugins show while they load (an MCP server that didn't
      # start) waits for the first turn, beside the load warnings: no UI
      # is there yet, and the Engine isn't built.
      @plugin_load_events = []
      @loading_plugins = true
      Plugin::Loader.load_installed(registries, failures: @plugin_failures, settings: bundle_settings)
    ensure
      @loading_plugins = false
    end

    # Keep a notice or card a plugin showed while loading (#load_plugins).
    def hold_load_event(event)
      @plugin_load_events << event
      event
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
        notify: ->(text, level, label) { hook_notify(text, level, label) },
        ask_user: lambda { |question:, options:, header:, allow_freeform:, hook:|
          hook_ask_user(question, options, header, allow_freeform, hook)
        },
        # An init task's is its own (a Ctrl-C ends a turn, not the task).
        cancelled: lambda {
          (task = current_init_task) ? task.cancelled? : active_cancel_controller&.cancelled?
        },
        card: ->(**card) { show_card(**card) },
        steer: ->(text, label) { steer(text, source: hook_source(label)) },
        stop_turn: ->(reason, label) { hook_stop_turn(reason, label) },
        stop_generation: ->(reason, label) { hook_stop_generation(reason, label) },
        ask_model: lambda { |request, timeout:, max_tokens:, cancel_controller:|
          ask_side_model(request, timeout: timeout, max_tokens: max_tokens, cancel_controller: cancel_controller)
        },
        model_name: -> { @session&.model_name || @effective_model_name },
        state_dir: -> { session_state_dir },
        scratch: -> { @scratch }
      )
    end

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
    # a turn resolves them (a /model switch counts), through its own
    # IdleClient, so it shares nothing with the turn's backend.
    # @return [String] the answer
    def ask_side_model(request, timeout:, max_tokens:, cancel_controller:)
      target = session_model_recap_target
      client = IdleClient.new(model: target[:model], base_url: target[:base_url], api_key_env: target[:api_key_env],
                              timeout: timeout)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      answer = client.ask(request, max_tokens: max_tokens, cancel_controller: cancel_controller)
      Log.info(:plugins, "ask_model", model: target[:label], answer_model: answer.model, chars: answer.text.length,
                                      ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      answer.text
    end
    private :ask_side_model

    # config.yml `bundles:` (ConfigFile.bundle_settings), read once: the
    # bundle hooks and the plugins both want it.
    def bundle_settings
      @bundle_settings ||= Samagotchi::ConfigFile.bundle_settings
    end
    private :bundle_settings


    # The session's current model as a recap target: its host's OpenAI API
    # (native llama.cpp hosts serve /v1/chat/completions too), key variable
    # and bare model name, as a turn resolves them.
    def session_model_recap_target
      target = @host_registry.resolve(@effective_model_name)
      { base_url: target.openai_base_url, api_key_env: target.entry.api_key_env,
        model: target.bare_model, label: @effective_model_name.to_s }
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

    # Always return a handler so raw kernel loop events reach the persistent
    # SessionObserver (and thus the analytics collector) even when there is no
    # turn-scoped +on_event+ sink (e.g. the -p/--resume paths and
    # SessionManager background workers). emit_event tolerates a nil on_event by
    # only notifying the observer.
    # Wrap a raw kernel stream event and fan it out to the turn sink + observers.
    #
    # Each :generation_chunk comes split already, by the loop that streamed it:
    # besides the raw `content` (left untouched — the TUI thinking spinner,
    # analytics, and Bridge replay rely on it) it carries
    #   * :text     — visible prose (thinking AND tool_call blocks removed)
    #   * :thinking — thinking-only content
    # KernelLoop splits a native stream with a ThoughtStreamSplitter per
    # generation (every profile, Gemma's thought channel included); the chat
    # loop gets reasoning apart from the answer. The web routes on those
    # fields (chunk_router.js).
    #
    # With a :generation_progress hook registered, a Hooks::StreamWatch gets
    # each chunk's thinking and text after the UIs had it.
    def build_stream_event_handler(on_event, cancel_controller: nil)
      watch = stream_watch(cancel_controller)
      proc do |event|
        progress = nil
        case event[:type]
        when :generation_started
          watch&.started(event[:iteration])
        when :generation_chunk
          # A chunk without the lanes (no loop of ours sends one) counts as text.
          text = event.key?(:text) ? event[:text] : event[:content]
          progress = { thinking: event[:thinking].to_s, text: text.to_s }
        end
        # The chat loop asked again without the thinking fields: a notice,
        # not an event of its own.
        next thinking_refused(event) if event[:type] == :thinking_refused

        emit_event(on_event, event)
        watch.feed(**progress) if watch && progress
        if event[:type] == :generation_completed
          check_thinking_honoured(event)
          announce_effort_ignored
        end
      end
    end

    # The turn's StreamWatch, or nil when no hook listens.
    def stream_watch(cancel_controller)
      return nil unless cancel_controller && @hooks.any?(Hooks::StreamWatch::EVENT)

      Hooks::StreamWatch.new(hooks: @hooks, cancel_controller: cancel_controller)
    end
    private :stream_watch

    def emit_event(on_event, event)
      # Capture used memories synchronously in the turn thread.
      read_names = begin
        @used_memories.capture(event, muted: @muted_memory_names)
      rescue StandardError
        nil
      end
      # Turn-scoped sink: receives the original event hash (no event_seq),
      # byte-for-byte unchanged. Sink errors are isolated and never break the
      # kernel loop (same as KernelLoop's own handling).
      if on_event
        begin
          on_event.call(event)
        rescue StandardError
          # Sink errors must not break the kernel loop (same as KernelLoop's own handling)
        end
      end

      # Persistent subscribers: receive a copy with a locally-monotonic
      # `event_seq`, fan out with per-subscriber error isolation.
      @session_observer.notify(event)
      # Every memory read, after its tool_call_started: the whole list for
      # the UIs' memory line, and the names this call read (read_names).
      return unless read_names

      emit_event(on_event, { type: :used_memories_updated, used_memory_names: used_memory_names, read_names: read_names })
    end

    # The window as the target's loop would see it (see ChatLoop#context_window:
    # a remote chat host has no /props, only its model list).
    def current_context_window(target)
      client = target.client
      adapter = nil
      if target.entry.chat?
        adapter = @host_registry.adapter_for(target.entry)
        client = nil if adapter.remote?
      end
      ContextWindow.resolve(client: client, model: target.bare_model, adapter: adapter)
    rescue StandardError
      nil
    end

    # See #served_model. A report for another name (before a /model switch)
    # doesn't count. Without a target, no probe. A remote chat host has no
    # /props: nil until a turn.
    def served_model_for(snapshot, target: nil)
      asked = bare_model_name(@effective_model_name)
      return [snapshot[:served_model], asked] if snapshot[:served_model] && snapshot[:served_model_for] == asked
      return [nil, nil] unless target

      client = target.client
      if target.entry.chat?
        adapter = @host_registry.adapter_for(target.entry)
        return [nil, nil] if adapter.remote?
      end
      served = ServedModel.from_props(client.server_props(model: target.bare_model))
      served ? [served, asked] : [nil, nil]
    rescue StandardError
      [nil, nil]
    end

    # ── Prompt profile ─────────────────────────────────────────────────────────

    def resolve_profile
      if @given_profile
        return ModelProfile::Resolution.new(profile: @given_profile, source: :given, detail: nil, retry: false)
      end

      target = @host_registry.resolve(@effective_model_name)
      ModelProfile.resolve(names: model_lookup_names(target), entry: target.entry, client: target.client, bare_model: target.bare_model)
    end

    # The names a models: entry may be under (HostRegistry#lookup_names):
    # the model as typed at start or at the last /model, and what it became.
    def model_lookup_names(target)
      @host_registry.lookup_names(@typed_model_name, resolved: @effective_model_name, target: target)
    end

    # Everything that holds a profile follows the resolution: the kernel's
    # prompt format and parser, and the system prompts built for the old one.
    def apply_profile(resolution)
      @prompt_builder&.reset! if @profile_resolution && @profile_resolution.profile.name != resolution.profile.name
      @kernel.use_profile!(resolution)
      resolution
    end

    # Before a turn: resolve now if nothing has yet, or again if the last
    # server probe failed (unreachable, or 503 while loading a model). A
    # profile that changes here drops the cached system prompts.
    def refresh_profile!
      if @profile_resolution&.retry?
        @profile_resolution = apply_profile(resolve_profile)
      else
        profile_resolution
      end
    end
  end
end
