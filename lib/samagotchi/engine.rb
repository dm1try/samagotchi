# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "yaml"

require_relative "config_file"
require_relative "model_profile"
require_relative "kernel_loop"
require_relative "llm/backend"
require_relative "session"
require_relative "session_observer"
require_relative "tool_declarations"
require_relative "session_metrics"
require_relative "token_usage"
require_relative "idle_recap"
require_relative "idle_reminders"
require_relative "hooks"
require_relative "reminder_store"
require_relative "tools/memory"

module Samagotchi
  # Engine owns the core agent logic: system prompt construction, tool
  # declarations, session lifecycle, and the model↔tool loop.
  #
  # It exposes an event-based API (`on_event`) so that any UI can run
  # turns without coupling to terminal rendering.
  class Engine
    AGENT_DESCRIPTION_FILE = "AGENT.md"
    SKIP_AGENT_DESCRIPTION_ENV = "SAMAGOTCHI_SKIP_AGENT_MD"

    # Build a system prompt string for the given profile.
    # Used by specs and inspection.
    def self.system_prompt_for(profile)
      profile = ModelProfile.normalize(profile) unless profile.is_a?(ModelProfile)
      new(mode: :assist, profile: profile).send(:assist_system_prompt)
    end

    # @param mode               [Symbol] :assist or other (Engine only supports :assist)
    # @param client             [Client, nil] defaults to Client.new
    # @param verbose            [Boolean]
    # @param log_file           [String, nil]
    # @param profile            [ModelProfile, Symbol, String, nil]
    # @param session_id         [String, nil] resume an existing session
    # @param no_interrupt       [Boolean]
    # @param model_name         [String, nil] defaults from SAMAGOTCHI_MODEL
    # @param memories           [Array<String>] --memory preload list
    def initialize(mode:, client: nil, verbose: false, log_file: nil, profile: nil, session_id: nil, no_interrupt: false, model_name: nil, memories: [], kernel: nil, recap: nil, reminders: nil)
      @mode = mode.to_sym
      @base_model_name = ModelProfile.required_model_name(model_name)
      @session_model_name = @base_model_name
      @client = client || Client.new
      @profile = profile ? ModelProfile.normalize(profile) : ModelProfile.from_model_name(@base_model_name)
      # Load hooks from config (plugins) and create the registry
      @hooks = load_hooks_from_config
      # Use the KernelLoop's reminder_store if provided (TerminalUI path),
      # otherwise create our own (SessionManager/one-shot paths). This ensures
      # tool calls via KernelLoop and reminder injection via Engine read/write
      # the same store.
      if kernel && kernel.respond_to?(:reminder_store)
        @reminder_store = kernel.reminder_store
      else
        @reminder_store = ReminderStore.new
      end
      # Build the idle reminders detector (wired to reminder_store)
      callback = reminders.is_a?(Hash) && reminders[:callback] ? reminders[:callback] : nil
      @reminders = build_reminders(auto_turn_callback: callback)
      # Track whether this is the first turn in the session (for session_start event)
      @first_turn = true
      @kernel = kernel || KernelLoop.new(client: @client, verbose: verbose, log_file: log_file, profile: @profile, no_interrupt: no_interrupt, hooks: @hooks, reminder_store: @reminder_store)
      # Resolve the backend provider at the Engine boundary: no `provider:` kwarg
      # is required at the call sites, so the two `Engine.new` callers
      # (TerminalUI, SessionManager) are untouched. Falls back to
      # `ENV["SAMAGOTCHI_BACKEND"]` when unset/blank, defaulting to `:native`
      # (Phase 4; see the provider-selection plan).
      @backend = LLM::Factory.factory(
        provider: LLM::Factory.resolve_provider,
        model_name: @base_model_name,
        kernel: @kernel
      )
      @resume_session = session_id ? Session.load(session_id) : nil
      @requested_memories = Array(memories)
      @session = nil
      @session_observer = SessionObserver.new
      @metrics = SessionMetrics.new
      # Shared inactivity clock + turn-running flag for the optional idle
      # session-recap detector. `record_activity` is the single seam both the
      # run_turn/worker path and the interactive REPL (which drives KernelLoop
      # directly) call, so the idle detector's clock is identical across UIs.
      @activity_mutex = Monitor.new
      @last_activity_at = monotonic_now
      @activity_seq = 0
      @turn_running = false
      @recap = build_recap(recap)
      # The metrics collector is a persistent observer so every run_turn event
      # (covering -p/--non-interactive/--resume and SessionManager workers)
      # feeds it automatically. The interactive REPL drives KernelLoop directly
      # and forwards its stream events into the same instance.
      @session_observer.subscribe(observer: @metrics)
    end

    # A monotonically-increasing clock (wall clock can jump backwards; the idle
    # detector must never treat a jump as "activity"). Injectable for specs.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Record that activity happened (user input or a completed turn). Shared,
    # mutex-guarded seam for the idle recap detector. Idempotent-ish: each call
    # advances both the last-activity timestamp and the activity sequence.
    # @param now [Float, nil] injectable monotonic time (defaults to now)
    def record_activity(now = nil)
      @activity_mutex.synchronize do
        @last_activity_at = now ? now.to_f : monotonic_now
        @activity_seq += 1
      end
    end

    # @return [Float] monotonic seconds of the last recorded activity
    def last_activity_at
      @activity_mutex.synchronize { @last_activity_at }
    end

    # @return [Integer] monotonically-increasing activity counter (advanced by
    #   #record_activity; lets the idle detector summarize once per idle window)
    def activity_seq
      @activity_mutex.synchronize { @activity_seq }
    end

    # Mark whether a turn is currently running (shared with the idle detector so
    # a recap never fires, or renders, while the model is generating).
    def set_turn_running(running)
      @activity_mutex.synchronize { @turn_running = running }
    end

    # @return [Boolean] true while a turn is in flight
    def turn_running?
      @activity_mutex.synchronize { @turn_running }
    end

    # Snapshot the current session messages as a JSON string for the idle
    # recap. Reads the array reference under the mutex (a single atomic
    # pointer read in CRuby) then serializes a dup'd copy OUTSIDE the lock so
    # the brief serialization never blocks the main turn thread. Never mutates
    # session.messages.
    # @return [String] JSON array of the messages
    def messages_json_for_recap
      snapshot = @activity_mutex.synchronize { @session&.messages }
      return "[]" if snapshot.nil?

      JSON.generate(Array(snapshot).map(&:dup))
    end

    # Emit a :recap_ready event (additive slot) carrying the generated recap
    # and the generation id an observer uses to reject an invalidated recap.
    def emit_recap(recap:, generation:)
      @session_observer.notify(type: :recap_ready, recap: recap, generation: generation)
    end

    # @return [SessionMetrics] the per-session analytics collector
    attr_reader :metrics

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

    # Start the idle reminders detector (no-op when already running).
    # TerminalUI calls this before the REPL; background workers never call it.
    # @return [self]
    def start_reminders
      @reminders&.start
      self
    end

    # Stop the idle reminders detector (TerminalUI calls this when the REPL exits).
    def stop_reminders
      @reminders&.stop
      self
    end

    # Get and inject all due reminders into the conversation. Called at the top
    # of run_turn (before set_turn_running(true)) so injection happens on the
    # main thread, serially with the turn — no TOCTOU race.
    #
    # Returns the array of due reminder hashes (may be empty). Injects a
    # [SYSTEM: REMINDERS DUE] message into the conversation when there are
    # Get due reminders, inject them into the provided messages array as
    # [SYSTEM: REMINDERS DUE], and atomically mark all as fired under one
    # ReminderStore lock.
    #
    # This is the canonical method for reminder injection, called from
    # Engine#run_turn after system prompt construction so the reminder text
    # is never overwritten.
    #
    # @param messages [Array<Hash>] the conversation messages (mutated in place)
    # @return [Array<Hash>] [{name:, description:, interval_minutes:}, ...]
    def collect_due_reminders(messages)
      due = @reminders&.due_reminders
      return [] if due.empty?

      # Build reminder text and append to the system message
      reminder_lines = due.map do |r|
        "  #{r[:name]}: #{r[:description]} (interval: #{r[:interval_minutes]}m)"
      end.join("\n")
      reminder_text = "[SYSTEM: REMINDERS DUE]\n#{reminder_lines}\n[END REMINDERS]"
      if messages.first&.dig(:role) == "system"
        messages.first[:content] = "#{messages.first[:content]}\n\n#{reminder_text}"
      else
        messages.unshift({ role: "system", content: reminder_text })
      end
      # Atomically mark all due as fired under one lock
      @reminder_store&.mark_fired_batch(due.map { |r| r[:name] })
      due
    end
    # Alias for backward compatibility.
    alias maybe_inject_reminders collect_due_reminders

    # @return [ReminderStore] the reminder store for inspection
    attr_reader :reminder_store

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
    def session_state_snapshot
      {
        status: @session&.status,
        message_count: (@session&.messages || []).size,
        last_prompt: @session&.last_prompt,
        event_seq: @session_observer&.event_count,
        metrics: @metrics.snapshot
      }
    end

    # @return [String] fully built system prompt (for inspection/tests)
    def system_prompt
      @system_prompt ||= system_prompt_with_index(assist_system_prompt)
    end

    # @return [Session] current session (Engine owns create/resume)
    def session
      @session
    end

    # Set the current session for recap tracking (used by REPL which bypasses run_turn)
    def session=(session)
      @session = session
    end

    # @return [IdleRecap, nil] the idle recap detector, or nil when disabled
    def recap
      @recap
    end

    # Start the idle recap detector (no-op when disabled). TerminalUI calls this
    # before the REPL; one-shot/worker paths never call it, so recap never fires
    # there.
    def start_recap
      @recap&.start
      self
    end

    # Stop the idle recap detector (TerminalUI calls this when the REPL exits).
    def stop_recap
      @recap&.stop
      self
    end

    # Run a single turn with event emission.
    #
    # Builds the system prompt + user messages, runs the kernel loop with
    # event forwarding, and returns a KernelLoop::Result.
    #
    # @param session  [Session] the session to operate on
    # @param prompt   [String] user input
    # @param on_event [Proc, nil] receives event hashes
    # @param max_iterations [Integer] max kernel iterations
    # @param cancel_controller [Client::CancellationController, nil]
    # @param max_tool_output_chars [Integer, nil] per-output char cap for the
    #   :tool_call_completed event's `output:` (nil → env/DEFAULT_MAX_TOOL_OUTPUT_CHARS)
    # @return [KernelLoop::Result]
    def run_turn(session, prompt, on_event: nil, max_iterations: 100, cancel_controller: nil, max_tool_output_chars: nil)
      # Track the active session for recap and status snapshot.
      @session = session
      # Mark the turn running before generating so the idle recap detector does
      # not fire (or render an invalidated recap) while the model is working.
      set_turn_running(true)

      begin
        # Emit turn_started event
        @metrics.session_id = session.id
        emit_event(on_event, {
          type: :turn_started,
          session_id: session.id,
          prompt: prompt
        })

        # Fire :session_start on the very first turn
        if @first_turn
          @hooks.fire(:session_start, { type: :session_start, session_id: session.id })
          @first_turn = false
        end

        # Fire :before_turn hook
        @hooks.fire(:before_turn, { type: :before_turn })

        messages = session.messages.dup
        system_message = { role: "system", content: system_prompt_with_index(assist_system_prompt) }
        # Inject due reminders AFTER system prompt construction so they are
        # not overwritten. The method mutates `system_message[:content]`.
        due_reminders = collect_due_reminders([system_message])
        if due_reminders.any?
          emit_event(on_event, {
            type: :reminder_injected,
            reminders: due_reminders
          })
        end
        if messages.empty?
          messages = [system_message]
        elsif messages.first[:role].to_s != "system"
          messages.unshift(system_message)
        else
          messages[0] = system_message
        end

        messages << { role: "user", content: prompt }
        session.last_prompt = prompt

        result = @backend.complete(
          messages: messages,
          max_iterations: max_iterations,
          on_stream_event: build_stream_event_handler(on_event),
          cancel_controller: cancel_controller,
          model_name: @session_model_name,
          max_tool_output_chars: max_tool_output_chars
        )

        @metrics.persist
        session.messages = result.conversation if result.respond_to?(:conversation) && result.conversation.is_a?(Array)

        # Emit turn_completed or turn_canceled
        if result.respond_to?(:canceled?) && result.canceled?
          emit_event(on_event, {
            type: :turn_canceled,
            cancellation_reason: result.cancellation_reason
          })
        else
          emit_event(on_event, {
            type: :turn_completed,
            result: result
          })
        end

        response = result.respond_to?(:output) ? result.output.to_s : result.to_s
        if response.strip.empty?
          session.messages << { role: "model", content: "[No response]" }
        end

        # Fire :after_turn hook (runs even on cancel/success)
        @hooks.fire(:after_turn, { type: :after_turn })

        # Fire :session_end after every turn (turn-level lifecycle)
        @hooks.fire(:session_end, { type: :session_end, session_id: session.id })

        result
      ensure
        # A completed turn is activity: release the turn flag and advance the
        # shared inactivity clock so the idle recap detector (shared with the REPL)
        # treats the just-finished turn as activity and re-arms its window.
        # Always runs, even if an exception occurred.
        set_turn_running(false)
        record_activity
        # Clear hooks so they remain turn-scoped and never leak into the next turn.
        clear_hooks
      end
    end

    # Backward-compatible: runs a prompt through the kernel loop without event forwarding.
    # @param session  [Session]
    # @param prompt   [String]
    # @return [String] model response text
    def process_prompt_through_kernel(session, prompt)
      messages = session.messages.dup
      system_message = { role: "system", content: system_prompt_with_index(assist_system_prompt) }

      if messages.empty?
        messages = [system_message]
      elsif messages.first[:role].to_s != "system"
        messages.unshift(system_message)
      else
        messages[0] = system_message
      end

      messages << { role: "user", content: prompt }
      session.last_prompt = prompt

      result = @kernel.run(messages)
      session.messages = result.conversation if result.respond_to?(:conversation) && result.conversation.is_a?(Array)

      response = result.respond_to?(:output) ? result.output.to_s : result.to_s
      if response.strip.empty?
        session.messages << { role: "model", content: "[No response]" }
        "[No response]"
      else
        response
      end
    end

    # Public entrypoint for background session workers.
    # @param session  [Session]
    # @param prompt   [String]
    # @return [String] model response
    def process_background_prompt(session:, prompt:)
      process_prompt_through_kernel(session, prompt)
    end

    # Clone a messages array (shallow dup of each element).
    # @param messages [Array<Hash>]
    # @return [Array<Hash>]
    def clone_messages(messages)
      Array(messages).map(&:dup)
    end

    private

    # Load hooks from the global config file using the Hooks::Loader.
    # Returns a Registry with all plugins registered (or an empty Registry if
    # no hooks config is present).
    def load_hooks_from_config
      config_path = Samagotchi::ConfigFile.global_path
      if File.file?(config_path)
        begin
          data = YAML.safe_load(File.read(config_path), permitted_classes: [], aliases: false)
          return Hooks::Loader.load(data) if data.is_a?(Hash)
        rescue StandardError
          # If config parsing fails, fall back to an empty registry
        end
      end
      Hooks::Registry.new
    end

    # Build (or disable) the idle recap detector from the `recap:` kwarg.
    #
    # Enabled when a `base_url` (points at a local OpenAI-compatible
    # /chat/completions server) and a `model` are both present — resolved from
    # the kwarg Hash, or from the SAMAGOTCHI_RECAP_* env vars. Missing either
    # fails fast with a warning and leaves recap disabled — the idle thread must
    # never spin up with no configured endpoint. An explicit `recap: false`
    # disables it regardless of env.
    def build_recap(recap)
      return nil if recap == false

      config = recap.is_a?(Hash) ? recap : {}
      base_url = string_config(config, :base_url) || env_or_nil("SAMAGOTCHI_RECAP_BASE_URL")
      model = string_config(config, :model) || env_or_nil("SAMAGOTCHI_RECAP_MODEL")
      if base_url.to_s.strip.empty? || model.to_s.strip.empty?
        warn "Warning: SAMAGOTCHI session recap is enabled but base_url/model are missing; recap disabled. " \
             "Set SAMAGOTCHI_RECAP_BASE_URL and SAMAGOTCHI_RECAP_MODEL (or pass recap: {base_url:, model:})."
        return nil
      end

      IdleRecap.new(
        engine: self,
        model: model.to_s.strip,
        base_url: base_url.to_s.strip,
        inactivity: float_config(config, :inactivity, IdleRecap::DEFAULT_INACTIVITY_SECONDS, "SAMAGOTCHI_RECAP_INACTIVITY"),
        min_user_turns: int_config(config, :min_user_turns, IdleRecap::DEFAULT_MIN_USER_TURNS, "SAMAGOTCHI_RECAP_MIN_USER_TURNS"),
        timeout: float_config(config, :timeout, IdleRecap::DEFAULT_TIMEOUT_SECONDS, "SAMAGOTCHI_RECAP_TIMEOUT")
      )
    end

    # Build the idle reminders detector. Always created (reminders are opt-in
    # via the agent calling register_reminder). The background thread polls
    # and triggers synthetic turns when reminders are due.
    #
    # @param auto_turn_callback [Proc, nil] called when a reminder is due;
    #   receives the due reminder names; responsible for triggering a synthetic
    #   turn (e.g. SessionManager writes a file, TerminalUI queues input).
    def build_reminders(auto_turn_callback: nil)
      @auto_turn_callback = auto_turn_callback
      IdleReminders.new(
        engine: self,
        reminder_store: @reminder_store,
        callback: @auto_turn_callback
      )
    end

    def env_or_nil(key)
      value = ENV[key]
      return nil if value.nil? || value.strip.empty?

      value
    end

    def string_config(config, key)
      value = config[key]
      value.to_s.strip.empty? ? nil : value.to_s
    end

    def float_config(config, key, default, env_key = nil)
      value = config[key]
      value = ENV[env_key] if value.to_s.strip.empty? && env_key
      return default if value.nil? || value.to_s.strip.empty?

      value.to_f
    end

    def int_config(config, key, default, env_key = nil)
      value = config[key]
      value = ENV[env_key] if value.to_s.strip.empty? && env_key
      return default if value.nil? || value.to_s.strip.empty?

      value.to_i
    end

    # ── Event helpers ──────────────────────────────────────────────────────────

    # Always return a handler so raw kernel loop events reach the persistent
    # SessionObserver (and thus the analytics collector) even when there is no
    # turn-scoped +on_event+ sink (e.g. the -p/--resume paths and
    # SessionManager background workers). emit_event tolerates a nil on_event by
    # only notifying the observer.
    def build_stream_event_handler(on_event)
      proc do |event|
        emit_event(on_event, event)
      end
    end

    def emit_event(on_event, event)
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
    end

    # ── Tool declarations ──────────────────────────────────────────────────────

    def tool_declarations
      case @profile.name
      when "qwen36"
        "<tools>\n#{JSON.pretty_generate(ToolDeclarations::QWEN_TOOLS_JSON)}\n</tools>"
      else
        # Gemma 4 format
        [
          ToolDeclarations::TOOL_EXECUTE,
          ToolDeclarations::TOOL_READ,
          ToolDeclarations::TOOL_WRITE,
          ToolDeclarations::TOOL_EDIT,
          ToolDeclarations::TOOL_MEMORY_READ,
          ToolDeclarations::TOOL_MEMORY_WRITE,
          ToolDeclarations::TOOL_TASK_CREATE,
          ToolDeclarations::TOOL_TASK_GET,
          ToolDeclarations::TOOL_TASK_LIST,
          ToolDeclarations::TOOL_TASK_STOP,
          ToolDeclarations::TOOL_TASK_WAIT,
          ToolDeclarations::TOOL_WEB_FETCH,
          ToolDeclarations::TOOL_REGISTER_REMINDER,
          ToolDeclarations::TOOL_CANCEL_REMINDER,
          ToolDeclarations::TOOL_LIST_REMINDERS
        ].join("\n")
      end
    end

    def tool_call_hint
      case @profile.name
      when "qwen36"
        ToolDeclarations::QWEN_TOOL_CALL_HINT
      else
        ToolDeclarations::TOOL_CALL_HINT
      end
    end

    # ── System prompts ─────────────────────────────────────────────────────────

    def assist_system_prompt
      declarations = tool_declarations
      hint = tool_call_hint

      <<~SYS
        You are Chi (pronounced "chee"), the friendly name for the Samagotchi assistant harness. You have access to the following tools:

        #{declarations}

        #{hint}
        You may make multiple tool calls. After seeing tool results, continue reasoning or answer the user.

        #{ToolDeclarations::SMALL_CONTEXT_PROTOCOL}

        Editing workflow:
          1. Read the target file or line range immediately before calling edit.
          2. For exact-match mode, copy old_text verbatim from that read output; do not reconstruct it from memory.
          3. Prefer the smallest unique block (about 3-15 lines) that contains the change.
          4. For large files, prefer range mode (start_line/end_line) to minimize context.
          5. If exact-match mode reports not found or multiple matches, read again and retry with a smaller or more unique block.
          6. Use write for full-file rewrites or creating new files.

        Memory convention:
          Project scope: ~/.config/samagotchi/memories/projects/<name>_<hash>/ (project-local)
          System scope:  ~/.config/samagotchi/memories/ (cross-project)
          memory_read accepts optional scope (project|system).
          memory_write requires explicit scope and entry name.
          User prompts may contain memory shorthand like #entry_name.
          Treat #entry_name as a memory reference, not as a file path.
          If shorthand includes a scope prefix, such as #project/entry_name or #system/entry_name,
          preserve that scope when reading the memory.
          Keep each scope's index.md updated when adding/updating entries.
          Each scope's `index.md` is auto-maintained by `memory_write` (one
          managed line per entry with name/scope/date/size); free-form sections
          are preserved. The verbatim `index` write (`path: "index"`) is kept.

        #{ToolDeclarations::CONTEXT_STATUS_PROTOCOL}
      SYS
    end

    def system_prompt_with_index(base)
      project_index = read_memory_index("project")
      system_index = read_memory_index("system")
      project_description = project_specific_description
      thinking_token = if @profile.name == "gemma4" && ENV["THINKING_MODE"] != "false"
                         "<|think|>\n"
                       else
                         ""
                       end
      memory_sections = [
        "Project memories:\n#{project_index}",
        "System memories:\n#{system_index}"
      ].join("\n\n")
      [thinking_token + base, rg_guidance, project_description, current_directory, memory_sections, explicit_memory_section].compact.join("\n")
    end

    # ── Memory helpers ─────────────────────────────────────────────────────────

    def read_memory_index(scope)
      Tools::MemoryRead.call("", scope: scope)
    end

    def explicit_memory_section
      return nil if @requested_memories.empty?

      entries = []
      @activated_memory_names ||= []
      @requested_memories.each do |raw|
        names = raw.split(",").map(&:strip).reject(&:empty?)
        names.each do |name|
          scope, actual_name = split_memory_scope(name)
          body = Tools::MemoryRead.call(actual_name, scope: scope)
          if body.start_with?("Error:")
            warn "Warning: --memory '#{name}' could not be loaded (#{body})"
            next
          end
          # Record activated names so the UI can echo them in the sticky
          # status line. The memory-body injection itself stays here — the
          # Engine is the single source of truth for the system prompt.
          @activated_memory_names << actual_name
          entries << "this memory is required by the user in the current context: memory name: #{actual_name}\n#{body}"
        end
      end

      return nil if entries.empty?

      entries.join("\n\n")
    end

    # Names activated via preloaded --memory entries during system-prompt
    # construction. Exposed so the UI can surface them in the sticky status
    # line; Engine still owns the prompt, the UI owns the rendering state.
    def activated_memory_names
      @activated_memory_names ||= []
    end

    def split_memory_scope(raw)
      value = raw.to_s.strip
      if value.include?("/")
        scope, name = value.split("/", 2)
        return [scope, name] if Tools::VALID_SCOPES.include?(scope)
      end

      [nil, value]
    end

    # ── Project / rg helpers ───────────────────────────────────────────────────

    def project_specific_description
      return nil if skip_agent_description?

      path = File.join(Dir.pwd, AGENT_DESCRIPTION_FILE)
      return nil unless File.file?(path)

      content = File.read(path).strip
      return nil if content.empty?

      "Project specific description:\n#{content}"
    rescue StandardError
      nil
    end

    def current_directory
      "Current working directory:\n#{Dir.pwd}"
    rescue StandardError
      nil
    end

    def skip_agent_description?
      value = ENV[SKIP_AGENT_DESCRIPTION_ENV]
      value == "1" || value&.casecmp?("true")
    end

    def rg_available?
      system("command -v rg", out: File::NULL, err: File::NULL)
    end

    def rg_guidance
      ToolDeclarations::RG_GUIDANCE if rg_available?
    end
  end
end
