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
require_relative "model_profile"
require_relative "effective_model"
require_relative "session_setting"
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
require_relative "hook_routes"
require_relative "guardrails"
require_relative "reminder_store"
require_relative "reminder_queue"
require_relative "tools/memory"
require_relative "muted_memories"
require_relative "used_memories"
require_relative "turn_state"
require_relative "steer_cut"
require_relative "engine_peers"
require_relative "bundle_needs"
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
require_relative "edit_preview"
require_relative "question_desk"
require_relative "child_reports"
require_relative "relay_desk"
require_relative "guardrail_wiring"
require_relative "plugin_tasks"
require_relative "prompt_warmup"

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
    def initialize(client: nil, host_registry: nil, profile: nil, session_id: nil, no_interrupt: false, model_name: nil, memories: [], muted_memories: [], kernel: nil, recap: nil, reminders: nil,
                   plugins: true, scratch: false, model_typed: nil, appended_prompt_files: [])
      # The turn as other threads see it (flag, cancel controller, sink,
      # steers) and the idle layer's activity clock. Built first: a plugin
      # may steer or ask whether a turn runs while it loads.
      @turn_state = TurnState.new(clock: -> { monotonic_now })
      # A message for the running turn cutting its generation.
      @steer_cut = SteerCut.new(clock: -> { monotonic_now }, controller: -> { active_cancel_controller },
                                cut_after: -> { steer_cut_after })
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
      # Guards the model choice and the profile cached for it (#store_profile).
      @profile_mutex = Mutex.new
      typed = model_typed.to_s.strip
      @model_choice = ModelChoice.new(name: @default_model_name, typed: typed.empty? ? @default_model_name : typed)
      # An injected client (specs) stands in for every host's client.
      @host_registry.client_override = client if client
      @client = effective_model.client
      # A caller's profile pins it (until a model switch); otherwise
      # #profile_resolution decides on first need (see there), so building an
      # Engine makes no network call.
      @given_profile = profile ? ModelProfile.normalize(profile) : nil
      @profile_resolution = nil
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
      # that may notify.
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
      @extension_load = ExtensionLoad.new(hook_failures: @guardrail_failures)
      @hooks = @extension_load.hooks
      # The tools this session offers (the prompts' declarations and the
      # kernel's dispatch): the built-ins, per Engine. execute.description
      # off: execute offers no description parameter.
      @tools = Tools::Builtins.registry(command_description: Config.get("execute.description") != false,
                                        policy: Config.get(LLMContextStrategy::POLICY_SETTING))
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
      # The notices a turn's thinking level leads to (once per session and host).
      @thinking_notices = ThinkingNotices.new(session: -> { @session }, profile: -> { self.profile },
                                              notify: ->(text, level, source) { hook_notify(text, level, source) })
      # The tools plugins publish without declaring (chi.tool_source), and
      # the search and call tools that reach them (Tools::ToolIndex).
      @tool_index = Tools::ToolIndex.new
      # The context sources the peer bundles declare as a peer agent's
      # answers (chi.peer_source); the worker's ContextAbsorber asks it.
      @peer_sources = PeerSources.new
      @lifecycle_mutex = Mutex.new
      @shut_down = false
      load_plugins if plugins
      # Registered from what the sources published while they loaded, and
      # with no plugins too: a toolkit's left-out built-ins are reachable
      # either way (declared per toolkit, Tools::Registry).
      @tool_index.declare(@tools, failures: @plugin_failures)
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
      @prompt_builder = SystemPrompt.new(profile: -> { self.profile }, tools: -> { @tools }, session: -> { @session },
                                         thinking: -> { turn_thinking }, model: -> { model_identity },
                                         model_notes: -> { model_notes }, memories: memories,
                                         muted_memory_names: @muted_memory_names, appended_files: appended_prompt_files)
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
      subscribe_session_observers
    end

    # ── initialize's collaborators ──────────────────────────────────────────

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
      @kernel = kernel || KernelLoop.new(client: @client, profile: @given_profile, model_name: effective_model_name,
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
        model_key: -> { @model_key },
        model_name: -> { guardrail_model_name },
        cancelled: -> { !!active_cancel_controller&.cancelled? },
        ask: ->(fields) { open_question(fields) },
        notify: ->(message) { guardrail_notify(message) }
      )
    end
    private :build_guardrail_wiring

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
    # +covered+ counts the session messages it summarizes.
    def emit_recap(recap:, generation:, covered: nil)
      @session_observer.notify(type: :recap_ready, recap: recap, generation: generation, covered: covered)
    end

    # @return [SessionMetrics] the per-session analytics collector
    attr_reader :metrics

    # The model as given (maybe an alias; HostRegistry#resolve applies it).
    def effective_model_name = @model_choice.name

    # The model as typed at start or at the last /model.
    def typed_model_name = @model_choice.typed

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
      SystemPrompt::ModelIdentity.new(ref: model.ref, host: host, key: @model_key,
                                      served: model.prompt_served, fallback_key: @fallback_model_key)
    end

    # The model notes for the effective model (ModelNotes): matched on its
    # bare id and key, the session's mutes left out.
    # @return [Array<ModelNotes::Note>]
    def model_notes
      ModelNotes.for(name: guardrail_model_name, key: @model_key, fallback_key: @fallback_model_key,
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
    # Kept with the model choice it was resolved for: one that finishes
    # after a switch is neither kept nor applied (#store_profile).
    # @return [ModelProfile::Resolution]
    def profile_resolution
      choice = @model_choice
      cached = @profile_resolution
      return cached.last if cached&.first.equal?(choice)

      store_profile(choice, resolve_profile(choice))
    end
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

    # The memory overlay key follows the model sent (ModelOverlay.key_for
    # its id). A model typed as an alias used to key overlays by the alias
    # (before aliases were applied there): that key is read when the
    # target's overlay is missing (KernelLoop#sync_model_key!).
    def sync_model_key!
      choice = @model_choice
      @model_key = ModelOverlay.key_for(bare_model_name(choice.name))
      typed_key = ModelOverlay.key_for(@host_registry.parse_qualified_model(choice.typed).last)
      @fallback_model_key = typed_key == @model_key ? nil : typed_key
      @kernel.sync_model_key!(@model_key, fallback: @fallback_model_key)
    end
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
    def synchronize_events(&)
      @session_observer.synchronize(&)
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
      return @extension_load.hold(card.merge(in_turn: true))[:id] if @extension_load.loading?
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
      choice = ModelChoice.new(name: resolved, typed: typed.to_s.strip.empty? ? model_name : typed.to_s.strip)
      @profile_mutex.synchronize do
        # One assignment: a reader on another thread sees the old pair or the new one.
        @model_choice = choice
        # A profile given to .new was for the starting model.
        @given_profile = nil
        @profile_resolution = nil
      end
      sync_model_key!
      @prompt_builder.reset!
      # The notes the new model's prompt loads at its next build, so /model,
      # /stats and the web name them before the next turn does.
      record_prompt_notes(model_notes) if @session
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

    # The metrics for /stats. Before the first generation reports them, the
    # context window, the served model and (on a native host) the prompt
    # profile come from the effective model's server, so this may make one
    # short /props GET; the cheap #session_state_snapshot never does.
    # price_host: the effective model's host, whose hosts.<name>.models
    # prices the cost estimate names.
    # @return [Hash] @metrics.snapshot, filled in
    def stats_snapshot
      snapshot = @metrics.snapshot
      # One resolve for the whole snapshot (its readers' rescues stay theirs);
      # a model that doesn't resolve raises here, as it always has.
      model = effective_model
      served, served_for = served_model_for(snapshot, model: model)
      snapshot = snapshot.merge(served_model: served, served_model_for: served_for,
                                served_expected_by: model.served_expected_by(served),
                                **setting_chips(SessionSetting::STATS, model),
                                prompt_notes: prompt_notes.map(&:to_h), prompt_files: @prompt_builder.prompt_files,
                                price_host: model.host_name)
      unless snapshot.dig(:context, :window_tokens)
        window = current_context_window(model)
        if window
          snapshot = snapshot.merge(context: snapshot[:context].merge(window_tokens: window.tokens,
                                                                      window_source: window.source.to_s))
        end
      end
      # The chat loop uses no prompt profile: drop one a native turn reported.
      return snapshot.except(:profile, :profile_source) if model.chat?

      unless snapshot[:profile]
        resolution = profile_resolution
        snapshot = snapshot.merge(profile: resolution.profile.name, profile_source: resolution.label)
      end
      snapshot
    end

    # The status line's ctx from the saved context, for a worker that has run
    # no turn yet (it woke after an idle exit): nil when either count is
    # unknown or context.status is off. Counted as the turns count it:
    # against the effective model's llm_context budget when it has one.
    def saved_context_status(context, model: :current)
      return nil unless context

      llm_context = model == :current ? turn_llm_context : model&.llm_context_explained(llm_context_session_args)&.resolved
      ContextStatus.new(llm_context: llm_context)
                   .display_for(used_tokens: context[:used_tokens], window_tokens: context[:window_tokens])
    end

    # #turn_llm_context with where each value came from
    # (LLMContextStrategy.explain), nil when it can't be resolved.
    # @return [LLMContextStrategy::Explained, nil]
    def llm_context_explained
      model_setting(nil) { |model| model.llm_context_explained(llm_context_session_args) }
    end

    # #llm_context_explained's summary (Explained#summary), nil when it
    # can't be resolved: /stats, the snapshot, the web's info bar.
    # @return [Hash, nil]
    def llm_context_summary
      llm_context_explained&.summary(llm_context_override)
    end

    # The session's own llm_context values, nil when it has none.
    # @return [LLMContextOverride, nil]
    def llm_context_override = SessionSetting::LLM_CONTEXT.own(@session)

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

    # The effective model is on a chat host (api: openai or anthropic), whose loop uses
    # no prompt profile.
    def chat_model? = effective_model.chat?

    # "temperature=0.6 (hosts.work)" for /model: the effective model's
    # configured sampling, nil when none.
    def sampling_summary = model_setting(nil, &:sampling_summary)

    # "off (models: qwen)", "low (session)" for /model: the effective
    # model's thinking level and where it came from, nil when none is set.
    def thinking_summary
      explained = thinking_explained
      explained&.source ? explained.label : nil
    end

    # The seconds a cut waits for the effective model to stream only
    # thinking (SteerCutAfter.resolve), resolved on every call, as
    # turn_sampling; on any error, the global and its name.
    # @return [Array(Integer, String|nil)]
    def steer_cut_after_explained
      model_setting([SteerCut.cut_after, "steer.cut_after"], &:steer_cut_after_explained)
    end

    # #steer_cut_after_explained's seconds: what SteerCut#cut_for_steer
    # reads, per host and model.
    def steer_cut_after = steer_cut_after_explained.first

    # "after 60 s (models: qwen)", "never (hosts.splash)" for /model: the
    # effective model's cut wait and where it came from, nil for the
    # default.
    def steer_cut_summary
      seconds, source = steer_cut_after_explained
      source ? SteerCutAfter.label(seconds, source) : nil
    end

    # The effective model's thinking level with where it came from and the
    # session's own (SettingExplained), as the next turn resolves it;
    # nil when it can't be resolved.
    # @return [SettingExplained, nil]
    # +own+: the session's own level to resolve with (the current one by
    # default; /thinking asks what a change would resolve to).
    def thinking_explained(own: thinking_override)
      model_setting(nil) { |model| model.thinking_explained(own: own) }
    end

    # "drop (models: qwen)" for /model: the effective chat model's
    # reasoning_history level and where it came from; nil when it is the
    # default, the model runs on the native loop (which ignores it) or it
    # can't be resolved.
    def reasoning_history_summary
      model_setting(nil) { |model| model.reasoning_history_summary(own: reasoning_history_override) }
    end

    # The effective chat model's reasoning_history level with where it came
    # from and the session's own (SettingExplained), as the next turn
    # resolves it; nil on a native host (the native loop ignores it; native:
    # true resolves it there too, for /reasoning-history) or when it can't
    # be resolved.
    # @return [SettingExplained, nil]
    # +own+: the session's own level to resolve with (the current one by
    # default; a command asks what a change would resolve to).
    def reasoning_history_explained(native: false, own: reasoning_history_override)
      model_setting(nil) { |model| model.reasoning_history_explained(own: own, native: native) }
    end

    # What a reasoning_history change from level +from+ to level +to+ costs
    # the effective model's prompt cache, given the session's conversation
    # (ReasoningHistory.cache_cost): :history or nil. A host ChatLoop
    # marked as refusing it may still get :history (one needless ask).
    # @return [Symbol, nil]
    def reasoning_history_cache_cost(from, to)
      model_setting(nil) { |model| model.reasoning_history_cache_cost(from, to, conversation: @session&.messages) }
    end

    # Whether the session has a model reply (a cache to restart at all).
    def history?
      Array(@session&.messages).any? { |entry| entry[:role].to_s == "model" }
    end

    # The session's own reasoning_history level, nil when it has none.
    # @return [Symbol, nil]
    def reasoning_history_override = SessionSetting::REASONING_HISTORY.own(@session)

    # Set the session's own reasoning_history level (nil unsets it); the
    # next turn's start resolves it. The caller saves the session.
    # @raise [ArgumentError] with no session yet
    def reasoning_history_override=(level)
      raise ArgumentError, "no session yet" unless @session

      SessionSetting::REASONING_HISTORY.set(@session, level)
    end

    # The session's own thinking level, nil when it has none.
    # @return [Symbol, nil]
    def thinking_override = SessionSetting::THINKING.own(@session)

    # What a thinking level change costs the effective model's prompt
    # cache (Thinking.cache_cost): :full, :provider or :tail.
    # @return [Symbol]
    def thinking_cache_cost
      effective_model.thinking_cache_cost { profile }
    end

    # Set the session's own thinking level (nil unsets it); the next turn's
    # start resolves it, never a running one (its TurnSettings are fixed).
    # The caller saves the session.
    # @raise [ArgumentError] with no session yet
    def thinking_override=(level)
      raise ArgumentError, "no session yet" unless @session

      SessionSetting::THINKING.set(@session, level)
    end

    # The model the server serves for the current model, and the name asked
    # for: what the last generation of that name reported, else llama.cpp's
    # model_alias (/props, one short cached probe; not with probe: false),
    # else [nil, nil].
    # @return [Array(String, String), Array(nil, nil)]
    def served_model(probe: true)
      served_model_for(@metrics.served_report, model: probe ? effective_model : nil)
    end

    # The host whose hosts.<name>.models.<id>.served names +served+ for the
    # current model (a gateway's round-robin targets): not a mismatch to
    # warn about. nil when none does.
    # @return [String, nil]
    def served_expected_by(served)
      model_setting(nil) { |model| model.served_expected_by(served) }
    end

    def served_expected?(served) = !served_expected_by(served).nil?

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
    #   :prompt_notes  [Array<Hash>] the model notes the prompt carried
    #     ({name:, scope:, chars:, digest:}; #prompt_notes)
    #   :parent_id     [String, nil] the session that delegated this one
    #   :model_name    [String]    the model turns run on now (after /model)
    #   :served_model, :served_model_for [String, nil] what a generation of
    #     that model reported serving, and the name asked (#served_model
    #     without the probe)
    #   :served_expected_by [String, nil] the host whose models: entry names
    #     that served model under served: (#served_expected_by)
    #   :recap_enabled [Boolean]   whether an idle recap is configured, with
    #     :recap_min_user_turns and :recap_inactivity_seconds (nil when not)
    def session_state_snapshot
      served_pair = served_model(probe: false)
      metrics = @metrics.snapshot
      # One resolve for the model's fields; nil when it doesn't resolve (the
      # Bridge's /state and reset frames rely on this never raising): those
      # fields are nil then, as their own rescues always gave.
      model = model_setting(nil) { |resolved| resolved }
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
        prompt_notes: prompt_notes.map(&:to_h),
        parent_id: @session&.parent_id,
        model_name: effective_model_ref,
        served_model: served_pair[0],
        served_model_for: served_pair[1],
        served_expected_by: model&.served_expected_by(served_pair[0]),
        context_status: @last_context_status&.dup || saved_context_status(metrics[:context], model: model),
        **setting_chips(SessionSetting::ALL, model),
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
    # (label: "plugins"; the UIs say guardrails without one), then the
    # notices and cards plugins showed as they loaded.
    def announce_guardrail_failures(on_event)
      return if @guardrail_failures_announced

      @guardrail_failures_announced = true
      message = @guardrail_failures.message
      emit_event(on_event, { type: :guardrail_warning, message: message }) if message
      plugins = @plugin_failures.message
      emit_event(on_event, { type: :guardrail_warning, message: plugins, label: "plugins" }) if plugins
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
    # @param event [Hash] the turn's end event (#stop_facts)
    def record_last_turn(session, outcome, seconds, origin, event, limit: nil)
      client_id = origin.is_a?(Hash) ? origin[:client_id].to_s : ""
      source = if client_id.start_with?(ClientId::DELEGATE_PREFIX) then "delegate"
               elsif client_id.start_with?(ClientId::CHILD_PREFIX) then "delegate_report"
               elsif client_id.start_with?(ClientId::CONTEXT_PREFIX) then "context"
               elsif client_id == ClientId::REMINDER then "reminder"
               else "client"
               end
      enqueued_id = origin.is_a?(Hash) ? origin[:enqueued_id] : nil
      session.last_turn = LastTurn.new(outcome: outcome, ended_at: Time.now.iso8601(3), seconds: seconds.round(1),
                                       origin: source, exhausted: limit ? true : nil, limit: limit,
                                       enqueued_id: enqueued_id.to_s.empty? ? nil : enqueued_id.to_s,
                                       **stop_facts(event))
    end

    # Why a turn stopped, from its end event (LastTurn::STOP_FACTS), for a
    # parent agent's wait (ReplyWait): a provider error's kind and whether
    # a retry may help, a cancel's reason and the hook that stopped it.
    # Only what is known.
    def stop_facts(event)
      case event&.dig(:type)
      # kept_steps: the turn's work stayed (a parent must not send the task again).
      when :turn_failed
        { error_kind: event[:error_kind]&.to_s, retryable: event[:retryable], kept_steps: event[:kept_steps] }
      when :turn_canceled
        { cancel_reason: event[:cancellation_reason]&.to_s, stopped_by: event[:cancelled_by]&.to_s }
      else {}
      end
    end
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
        turn.session.status = Session::STATUS_IDLE
        record_last_turn(turn.session, outcome, seconds, turn.origin, event, limit: exhausted ? turn.limit : nil)
        emit_event(turn.on_event, turn.tag(event))
      end
      turn.ended = true
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

    # @return [Hash, nil] {selected:, freeform:, selected_indices:}
    def hook_ask_user(question, options, header, allow_freeform, hook)
      @hook_routes.ask_user(question, options, header, allow_freeform, hook)
    end
    private :hook_ask_user

    # @return [Boolean] true when a running turn was cancelled now
    def hook_stop_turn(reason, hook) = @hook_routes.stop_turn(reason, hook)
    private :hook_stop_turn

    # @return [Boolean] true when a streaming generation was cut now
    def hook_stop_generation(reason, hook) = @hook_routes.stop_generation(reason, hook)
    private :hook_stop_generation

    # The hook routes (see #initialize for when).
    def build_hook_routes
      HookRoutes.new(
        extension_load: -> { @extension_load },
        in_turn_sink: -> { @turn_state.in_turn_sink },
        anytime_thread: -> { anytime_thread? },
        announce_anytime: ->(event) { announce_anytime(event) },
        init_task: -> { current_init_task },
        announce: ->(event) { announce(event) },
        announce_or_hold: ->(event) { announce_or_hold(event) },
        emit: ->(sink, event) { emit_event(sink, event) },
        question_desk: -> { @question_desk },
        cancel_controller: -> { active_cancel_controller },
        steer: ->(text, source) { steer(text, source: source) }
      )
    end
    private :build_hook_routes

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

    # Open a question for the UIs and wait for its answer
    # (QuestionDesk#open_question: BLOCKS until answered or cancelled).
    # @param fields [Hash] question:, options:, header:, multi_select:, allow_freeform:, …
    #   (as a Hash or as keywords)
    # @param watch [#call, nil] closes the question with the reason it returns
    # @return [Hash, String] the answer, or {error:, …}
    def open_question(fields = nil, watch: nil, **more)
      @question_desk.open_question({ **fields.to_h, **more }, watch: watch)
    end

    # Publish a standing question that blocks nobody (QuestionDesk#post: a
    # worker's step-limit question).
    # @return [Hash, nil] the pending question, nil while another is open
    def post_question(fields, on_answer:, on_superseded_close: nil)
      @question_desk.post(fields, on_answer: on_answer, on_superseded_close: on_superseded_close)
    end

    # Withdraw the standing question (QuestionDesk#withdraw).
    # @return [Boolean]
    def withdraw_question(reason, id: nil)
      @question_desk.withdraw(reason, id: id)
    end

    # Answer the pending question (called from UI thread; QuestionDesk#answer).
    # @return [Hash] normalized answer
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
    # The native prompt depends on the thinking level too (Gemma's token,
    # Qwen's turn preamble): a level change builds it again. A build that
    # misses the cache names the model and the level through its own
    # lambdas (#model_identity, #turn_thinking), which resolve again.
    def system_prompt(model = nil)
      model ||= effective_model
      chat = model.chat?
      level = chat ? nil : thinking_level(model)
      prompt = @prompt_builder.build(chat: chat, thinking: level, layers: model.llm_context_layers(llm_context_session_args))
      # The memory indexes this prompt holds: /stats, the snapshot, analytics.json.
      @metrics.memory_index = @prompt_builder.memory_index
      # The model notes it carries: the session records them (/stats, /model, the web).
      record_prompt_notes(@prompt_builder.prompt_notes)
      prompt
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
      # A woken worker's /stats and status line count the turns before it.
      bind_metrics(session)
      @used_memories.absorb(session)
    end

    # @return [IdleRecap, nil] the idle recap detector, or nil when disabled
    attr_reader :recap

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
    # +id+: names the turn on :turn_started (its metrics record's id) and on
    # its saved prompt, so a UI pairs the two whatever left the conversation.
    # +limit+: the iteration limit #generate ran it with.
    # +resumed+: a step-limit Continue (run_turn's resumed:).
    # +resume_from+: where its reasoning starts, the run it resumes
    # (run_turn's resume_from:); nil for every other turn, and for a
    # Continue that starts cold (after a model change).
    Turn = Struct.new(:session, :prompt, :continue, :on_event, :controller, :origin, :started_at, :messages, :ended,
                      :settings, :id, :limit, :resumed, :resume_from) do
      def resumed? = resumed ? true : false

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
    # @param origin [Hash, nil] who queued the turn ({client_id:, enqueued_id:});
    #   when given, the turn's boundary events (:turn_started, :turn_completed,
    #   :turn_canceled, :turn_failed) carry it as `origin:`
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
    # An Interrupt (SIGINT) cancels the turn: the pre-turn conversation plus
    # the prompt is kept in the session and :turn_canceled is emitted, then the
    # Interrupt is re-raised so the caller still decides whether to exit. One
    # after the turn's end event (in its after_turn/session_end hooks) is
    # only re-raised: the turn already ended; so is any error there. Any
    # other error (e.g. an LLM::ProviderError) emits :turn_failed and
    # re-raises; a provider error adds error_kind:, retryable:, host: and a
    # one-line summary:.
    def run_turn(session, prompt, on_event: nil, max_iterations: nil, cancel_controller: nil, max_tool_output_chars: nil, pending_input: nil, continue: false, origin: nil,
                 images: [], id: nil, resumed: false, resume_from: nil)
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
    def begin_turn(session, prompt, on_event:, cancel_controller:, origin:, continue:, id: nil)
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
               id: id || SecureRandom.uuid)
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
      turn_started = { type: :turn_started, session_id: session.id, prompt: turn.prompt, turn_id: turn.id }
      turn_started[:continue] = true if turn.continue
      turn_started[:resumed] = true if turn.resumed?
      turn_started[:images] = image_refs unless image_refs.empty?
      turn_started[:cut_after] = steer_cut_after
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
      level = thinking_level(model)
      @thinking_notices.turn_started(level, model.target)
      LLM::TurnSettings.new(vision: vision, sampling: sampling, thinking: level,
                            reasoning_history: reasoning_history_level(model), model_name: nil,
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
      prompt, images = @kernel.warmup_prompt(messages, llm_context: turn_llm_context || @kernel.turn_settings&.llm_context)
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
    # not measured), nor a non-llama.cpp transport.
    def warmup_target?(model, client)
      return false if model.chat? || model.entry.remote?
      return false unless client.respond_to?(:warm_up) && client.respond_to?(:transport) && client.transport.native?

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
      due_reminders = @reminder_queue.inject!(turn.messages)
      if due_reminders.any?
        emit_event(turn.on_event, {
          type: :reminder_injected,
          reminders: due_reminders
        })
      end

      return if turn.continue

      user_message = { role: "user", content: turn.prompt, turn_id: turn.id }
      user_message[:images] = image_refs unless image_refs.empty?
      turn.messages << user_message
      session.last_prompt = turn.prompt
    end
    private :turn_messages

    # Ask the effective model's backend.
    def generate(turn, max_iterations:, max_tool_output_chars:, pending_input:)
      # One resolve for the request: nothing runs between these reads that
      # could change what a resolve gives (the hooks ran before).
      model = effective_model
      sync_kernel_client!(model)
      # Route model name as bare (without host prefix) to the transport;
      # host selection already done via active client.
      bare_for_backend = bare_model_name(model.name)
      # The turn's settings, set once here. The chat loop dispatches tools
      # through the kernel without its #run: tag those dumps with this
      # turn's model, not the last native one.
      explained = model.llm_context_explained(llm_context_session_args)
      @kernel.turn_settings = turn.settings.with(model_name: bare_for_backend, window_setting: model.window_setting,
                                                 llm_context: explained&.resolved, price: model.price)
      log_llm_context(explained)

      turn.limit = @no_interrupt ? IterationLimit.for(no_interrupt: true) : max_iterations || IterationLimit.for
      # Where this run starts (ChatLoop::Run's start): an offer made at its
      # end keeps it, so a Continue resumes this run.
      run_start = turn.messages.length
      reasoning_since = resumed_run_start(turn, run_start)
      result = backend(model).complete(
        messages: turn.messages,
        max_iterations: turn.limit,
        on_stream_event: build_stream_event_handler(turn.on_event, cancel_controller: turn.controller),
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

    # What the session keeps of a turn that ended normally (nil: nothing to
    # replace). Runs under the event lock: it also adds the turn's note to
    # result.conversation, which the REPL keeps as-is.
    # A turn that ran out of iterations ends at its tool results, so a
    # continue resumes from them rather than after a made-up reply (and a
    # step-limit Continue from its run's start: ModelResult#run_start).
    def kept_messages(turn, result, seconds)
      conversation = result.conversation if result.conversation.is_a?(Array)
      # Nothing visible (no text) is a turn the model should know ended
      # that way: the note, and nothing made up as its answer. The note's
      # marker is for the UIs (the notice, and the empty steps after a
      # reload); it goes on the result's conversation too (the REPL keeps it).
      # A retry's nudge at the tail goes: this note says it all. An earlier
      # turn's note stays: it says why that turn ended.
      if result.empty_answer?
        note = TurnNote.empty(retries: result.empty_retries, steps: result.empty_steps, refusal: result.refusal)
        conversation&.replace(TurnNote.without_trailing_nudge(conversation))
        saved = TurnNote.without_trailing_nudge(conversation || turn.session.messages)
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
    # the model. The model reads why on its next turn. A turn that got to
    # tool results (LLM::FailedTurn.progress) says so in the note; on the
    # error (kept_steps) too unless it failed in a way that rolls back
    # (FailedTurn.keeps_work?: a context overflow). The UIs keep a marked
    # turn (TurnFlow#prompt_turn_failed), and roll back the others, with a
    # note of their own; -p --non-interactive keeps what this keeps.
    def failed_messages(turn, error)
      kept = error.respond_to?(:partial_conversation) && error.partial_conversation.is_a?(Array) ? error.partial_conversation : turn.messages
      return nil unless kept

      steps = LLM::FailedTurn.progress(turn.session.messages, kept)
      error.kept_steps = steps if steps && error.is_a?(LLM::FailedTurn) && LLM::FailedTurn.keeps_work?(error)
      summary = error.respond_to?(:summary) ? error.summary : error.message
      TurnNote.replace_trailing(kept, TurnNote.failed(summary, continued: turn.continue, steps: steps))
    end
    private :failed_messages

    # Called after #failed_messages, which marks the error's kept steps.
    def failed_event(error, seconds)
      failed = { type: :turn_failed, error_class: error.class.name, message: error.message,
                 duration_ms: (seconds * 1000).round }
      # Its work stays: the UIs say so, as after a cancel.
      steps = LLM::FailedTurn.kept_steps(error)
      failed[:kept_steps] = steps if steps
      # A provider error says what kind it is, for one line per kind in the UIs.
      if error.is_a?(LLM::ProviderError)
        failed.merge!(error_kind: error.kind, retryable: error.retryable?, host: error.host, summary: failure_summary(error))
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

    # The effective model's request parameters (hosts: and models:
    # sampling), read per turn: /model can change the model between turns.
    def turn_sampling = model_setting(SamplingSettings::EMPTY, &:sampling)

    # The effective model's thinking level (Thinking.resolve), read each turn.
    def turn_thinking = model_setting(Thinking::DEFAULT) { |model| thinking_level(model) }

    # +model+'s ReasoningHistory level, the session's own first; the
    # default when it can't be resolved.
    def reasoning_history_level(model) = model.reasoning_history(own: reasoning_history_override)

    # +model+'s thinking level (Thinking.resolve), the session's own first.
    def thinking_level(model) = model.thinking(own: thinking_override)

    # A model known not to see images fails a turn with images up front.
    def refuse_images!(vision)
      return if vision.sendable?

      host = effective_model.host_name
      raise LLM::VisionUnsupported.new("#{host}: #{vision.refusal_reason}", host: host)
    end

    # JSON-safe digest of a finished turn for renderers (in-process or over the
    # Bridge): the bits of the native loop's result a UI needs beyond `result:`.
    # @param result [LLM::ModelResult]
    # @return [Hash]
    def turn_summary(result)
      summary = {
        output: result.output.to_s,
        exhausted: result.exhausted?,
        resumable: result.resumable?,
        pending_tool_calls: result.pending_tool_calls?,
        tool_activity: Array(result.tool_activity).map(&:dup),
        context_status: result.context_status&.dup
      }
      # No answer: every UI shows its notice (TurnNote.empty_answer_line).
      summary[:empty_answer] = { retries: result.empty_retries.to_i, refusal: result.refusal }.compact if result.empty_answer?
      summary
    end

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
        toolkit: -> { @toolkit_binding.name },
        declared_tools: -> { toolkit_explained.declared.map(&:name) },
        use_toolkit: ->(name) { use_toolkit(name) },
        ask_model: lambda { |request, timeout:, max_tokens:, cancel_controller:|
          ask_side_model(request, timeout: timeout, max_tokens: max_tokens, cancel_controller: cancel_controller)
        },
        model_name: -> { effective_model_ref },
        model_key: -> { @model_key },
        state_dir: -> { session_state_dir },
        scratch: -> { @scratch },
        setup: -> { SessionSetup.of(@session) },
        # The files whose text the built system prompt holds; [] until a
        # build and after a rebuild that drops them (SystemPrompt#prompt_files
        # returns [] itself: the || keeps a nil builder safe).
        prompt_files: -> { @prompt_builder&.prompt_files || [] },
        frontend: -> { interface }
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
    # IdleClient, so it shares nothing with the turn's backend. The client
    # is kept while the target and timeout stay (what it learned, e.g. a
    # refused thinking-off, holds for the next request); the session's id
    # goes with the request.
    # @return [String] the answer
    def ask_side_model(request, timeout:, max_tokens:, cancel_controller:)
      target = session_model_recap_target
      client = side_model_client(target, timeout)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      answer = client.ask(request, max_tokens: max_tokens, cancel_controller: cancel_controller, session_id: @session&.id)
      Log.info(:plugins, "ask_model", model: target.label, answer_model: answer.model, chars: answer.text.length,
                                      ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      answer.text
    end
    private :ask_side_model

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
        progress = SteerCut.lanes(event) if event[:type] == :generation_chunk
        @steer_cut.observe(event, progress)
        case event[:type]
        when :generation_started
          @thinking_notices.generation_started
          watch&.started(event[:iteration])
        when :generation_retrying
          # A dropped stream's step asked again: it streams from the start.
          if event[:restarted]
            @thinking_notices.generation_started
            watch&.started(event[:iteration], restarted: true)
          end
        when :generation_chunk then @thinking_notices.note_thought(progress[:thinking])
        end
        # The chat loop asked again without the thinking fields or the
        # reasoning sent back: a notice, not an event of its own.
        next @thinking_notices.thinking_refused(event) if event[:type] == :thinking_refused
        next @thinking_notices.reasoning_history_refused(event) if event[:type] == :reasoning_history_refused
        next @thinking_notices.sampling_refused(event) if event[:type] == :sampling_refused

        event = with_generation_report(event) if event[:type] == :generation_completed
        emit_event(on_event, event)
        watch.feed(**progress) if watch && progress
        @thinking_notices.generation_completed(event) if event[:type] == :generation_completed
      end
    end

    # A :generation_completed with the generation's decode speed (`speed:`
    # {decode_tps:, source:}, nil without one), the session's running
    # token totals (`tokens:`, the snapshot's block) and whether its served
    # model is an expected one (`served_expected_by:`, its host): the web's info bar
    # reads them from the stream. SessionMetrics closes the generation here,
    # so the event it gets next finds it closed.
    def with_generation_report(event)
      report = @metrics.finish_generation
      event.merge(speed: report.speed&.to_h, tokens: report.tokens, served_expected_by: served_expected_by(event[:served_model]))
    rescue StandardError => e
      Log.warn(:turn, "generation_report_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      event
    end
    private :with_generation_report

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
      rescue StandardError => e
        Log.warn(:memory, "used_memories_capture_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        nil
      end
      # Turn-scoped sink: receives the event hash as the stream handler
      # passed it (no event_seq; a :generation_completed has its report). Sink errors are isolated and never break the
      # kernel loop (same as KernelLoop's own handling).
      if on_event
        begin
          on_event.call(event)
        rescue StandardError => e
          # Sink errors must not break the kernel loop (same as KernelLoop's own handling)
          Log.warn(:turn, "sink_failed", event_type: event[:type].to_s, error: e.class.name, msg: e.message.to_s[0, 200])
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

    # The effective model's models:/hosts: window_tokens, read per turn
    # (after the hooks that may switch the model).
    def turn_window_setting = model_setting(nil, &:window_setting)

    # The effective model's price on its host (hosts.<name>.models.<id>.price),
    # by the requested id, never the served one; read per turn as the window is.
    def turn_price = model_setting(nil, &:price)

    # The LLM context strategy the next turn runs under: the session's own
    # (Session#llm_context), else the effective model's (models:/hosts:
    # llm_context_strategy), else llm_context.strategy; read per turn as
    # the window is.
    def turn_llm_context
      llm_context_explained&.resolved
    end

    def llm_context_session_args = @session&.llm_context&.resolve_args || {}
    private :llm_context_session_args

    # See #served_model. A report for another name (before a /model switch)
    # doesn't count. Without a model (EffectiveModel), no probe. A remote
    # chat host has no /props: nil until a turn. The name asked is never
    # resolved (HostRegistry#bare_name), so it holds on a broken resolve.
    def served_model_for(snapshot, model: nil)
      asked = bare_model_name(model ? model.name : effective_model_name)
      return [snapshot[:served_model], asked] if snapshot[:served_model] && snapshot[:served_model_for] == asked
      return [nil, nil] unless model

      model.served_from_props(asked)
    # Only bare_model_name and the snapshot lookup are left to fail here:
    # the probe's failure is EffectiveModel#served_from_props's.
    rescue StandardError
      [nil, nil]
    end

    # The window as +model+'s loop would see it (EffectiveModel#context_window).
    def current_context_window(model) = model.context_window

    # +settings+' chips (SessionSetting), the model's from +model+ (nil
    # when it doesn't resolve): /stats, the session state, a :command_ran.
    def setting_chips(settings, model)
      settings.to_h { |setting| [setting.key, setting.model? ? setting.chip_for(model, @session) : toolkit_summary] }
    end

    # The effective model now (EffectiveModel.of): resolved on each call,
    # never kept (config.yml, a model listing and another process's saved
    # lists all move a resolve). Raises as HostRegistry#resolve does.
    # @return [EffectiveModel]
    def effective_model(choice = @model_choice) = EffectiveModel.of(@host_registry, choice)

    # The block's answer for the effective model, or +fallback+ when the
    # model doesn't resolve: the readers whose rescue always covered the
    # resolve too. Each setting's own failure is the EffectiveModel's.
    def model_setting(fallback)
      # One read: the log line names the model that failed, even if a
      # /model switched it meanwhile.
      choice = @model_choice
      model = begin
        effective_model(choice)
      rescue StandardError => e
        return EffectiveModel::Unresolved.fallback(:effective_model_unresolved, choice.name, e, fallback)
      end
      yield model
    end

    # ── Prompt profile ─────────────────────────────────────────────────────────

    # +choice+'s profile (ModelProfile.resolve; may probe /props), or the
    # one given to .new.
    def resolve_profile(choice)
      given = @given_profile
      return ModelProfile::Resolution.new(profile: given, source: :given, detail: nil, retry: false) if given

      EffectiveModel.of(@host_registry, choice).profile_resolution
    end

    # Keeps +resolution+ as +choice+'s and applies it, unless the model
    # switched while it was resolved (a /stats on a Bridge thread probing
    # as a /model ran): then it is only returned, and the new model's is
    # resolved on its first need.
    # @return [ModelProfile::Resolution]
    def store_profile(choice, resolution)
      @profile_mutex.synchronize do
        return resolution unless @model_choice.equal?(choice)

        apply_profile(resolution)
        @profile_resolution = [choice, resolution]
      end
      resolution
    end

    # Everything that holds a profile follows the resolution: the kernel's
    # prompt format and parser, and the system prompts built for the old one.
    def apply_profile(resolution)
      kept = @profile_resolution&.last
      @prompt_builder&.reset! if kept && kept.profile.name != resolution.profile.name
      @kernel.use_profile!(resolution)
      resolution
    end

    # Before a turn: resolve now if nothing has yet, or again if the last
    # server probe failed (unreachable, or 503 while loading a model). A
    # profile that changes here drops the cached system prompts.
    def refresh_profile!
      choice, kept = @profile_resolution
      return profile_resolution unless choice.equal?(@model_choice) && kept.retry?

      store_profile(choice, resolve_profile(choice))
    end
  end
end
