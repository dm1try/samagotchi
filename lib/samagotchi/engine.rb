# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "yaml"

require_relative "config"
require_relative "model_profile"
require_relative "kernel_loop"
require_relative "host_registry"
require_relative "llm/backend"
require_relative "session"
require_relative "session_observer"
require_relative "tool_declarations"
require_relative "session_metrics"
require_relative "token_usage"
require_relative "idle_recap"
require_relative "idle_reminders"
require_relative "idle_scheduler"
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

    # @param mode               [Symbol] :assist (harness is single-mode; memory-reliant; kwarg kept for compat, ignored)
    # @param client             [Client, nil] defaults to Client.new
    # @param verbose            [Boolean]
    # @param log_file           [String, nil]
    # @param profile            [ModelProfile, Symbol, String, nil]
    # @param session_id         [String, nil] resume an existing session
    # @param no_interrupt       [Boolean]
    # @param model_name         [String, nil] defaults from SAMAGOTCHI_DEFAULT_MODEL
    # @param memories           [Array<String>] --memory preload list
    DEFAULT_SYSTEM_MEMORIES = %w[identity].freeze

    def initialize(mode: :assist, client: nil, host_registry: nil, verbose: false, log_file: nil, profile: nil, session_id: nil, no_interrupt: false, model_name: nil, memories: [], kernel: nil, recap: nil, reminders: nil)
      @mode = mode.to_sym
      @default_model_name = ModelProfile.required_model_name(model_name)
      @effective_model_name = @default_model_name
      @host_registry = host_registry || HostRegistry.new
      @client_injected = !client.nil?
      @client = client || default_client_for(@effective_model_name)
      # If client was injected, ensure registry's default points to it (for routing)
      if @client_injected && @host_registry.entries["default"]
        @host_registry.entries["default"].client = @client
      end
      @profile = profile ? ModelProfile.normalize(profile) : ModelProfile.from_model_name(bare_model_name(@default_model_name))
      # Ensure the built-in system bundle is installed (lazy, warn-only).
      # This is the single seam for both TUI and non-TUI (web/worker) paths.
      begin
        require_relative "memory_bundle/system_bundle"
        MemoryBundle::SystemBundle.ensure!
      rescue StandardError
        nil
      end
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
      sync_kernel_client!
      # Keep kernel client in sync with active host via setter
      @kernel_client_synced = false
      # Engine owns hooks; if a kernel was supplied externally (TUI path) propagate
      # the Engine's registry so all UIs reuse the same instance. Without this the
      # TUI's KernelLoop fires with nil hooks and before_generation/after_generation
      # etc. never fire in interactive mode.
      if kernel && @kernel.respond_to?(:hooks=)
        @kernel.hooks = @hooks
      end
      # Cross-link kernel ↔ engine for ask_user_question blocking path (kernel needs to call back into engine)
      if @kernel.instance_variable_defined?(:@engine) || @kernel.respond_to?(:engine=)
        @kernel.instance_variable_set(:@engine, self) rescue nil
        @kernel.instance_variable_set(:@engine_ref, self) rescue nil
      else
        @kernel.instance_variable_set(:@engine, self) rescue nil
      end
      # Also expose a direct handler proc on kernel for the fallback path
      begin
        @kernel.instance_variable_set(:@engine_request_question_handler, proc { |payload| request_question(payload) })
      rescue StandardError
        nil
      end
      # If session was resumed and has a pending_question, hydrate engine state
      if @resume_session && @resume_session.pending_question
        @pending_question = @resume_session.pending_question.dup
        @session = @resume_session
      end
      # Resolve the backend provider at the Engine boundary: no `provider:` kwarg
      # is required at the call sites, so the two `Engine.new` callers
      # (TerminalUI, SessionManager) are untouched. Falls back to
      # `ENV["SAMAGOTCHI_BACKEND"]` when unset/blank, defaulting to `:native`
      # (Phase 4; see the provider-selection plan).
      @backend = LLM::Factory.factory(
        provider: LLM::Factory.resolve_provider,
        model_name: @default_model_name,
        kernel: @kernel
      )
      @resume_session = session_id ? Session.load(session_id) : nil
      @requested_memories = Array(memories)
      @session = nil
      @session_observer = SessionObserver.new
      @metrics = SessionMetrics.new
      # Shared inactivity clock + turn-running flag for the idle subsystems
      # (session recap + reminders), all polled by the shared IdleScheduler.
      # `record_activity` is the single seam both the run_turn/worker path and
      # the interactive REPL (which drives KernelLoop directly) call, so the
      # idle layer's clock is identical across UIs.
      @activity_mutex = Monitor.new
      @last_activity_at = monotonic_now
      @activity_seq = 0
      @turn_running = false
      @active_cancel_controller = nil
      @question_mutex = Monitor.new
      @question_cv = @question_mutex.new_cond
      @pending_question = nil
      @question_answer = nil
      @recap = build_recap(recap)
      # One shared poller for the whole idle layer (reminders + optional
      # recap). Both jobs read the activity seam above; the scheduler owns
      # the single background thread and isolates per-job failures.
      @idle_scheduler = IdleScheduler.new(
        engine: self,
        jobs: [@reminders, @recap].compact
      )
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

    # @return [Client::CancellationController, nil] active turn's cancellation controller
    def active_cancel_controller
      @activity_mutex.synchronize { @active_cancel_controller }
    end

    # Cancel the currently running turn, if any.
    # @param reason [Symbol] cancellation reason
    # @return [Boolean] whether a cancellation was triggered
    def cancel_current_turn!(reason = :manual)
      ctrl = active_cancel_controller
      return false unless ctrl

      ctrl.cancel!(reason)
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
    attr_reader :default_model_name, :effective_model_name
    attr_reader :host_registry, :client

    def bare_model_name(full_ref)
      _, bare = @host_registry.parse_qualified_model(full_ref)
      bare.to_s.strip.empty? ? full_ref.to_s.strip : bare
    end

    def default_client_for(model_name)
      return @client if @client_injected
      client, _bare, _entry = @host_registry.client_for_model(model_name)
      client
    end

    def sync_kernel_client!
      return if @client_injected
      active = default_client_for(@effective_model_name)
      @client = active
      if @kernel.respond_to?(:client) && @kernel.client != active
        @kernel.client = active if @kernel.respond_to?(:client=)
      elsif @kernel.instance_variable_defined?(:@client)
        @kernel.instance_variable_set(:@client, active)
      end
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

    # ── Model switching ────────────────────────────────────────────────────────

    def switch_model!(model_name, persist_default: false)
      # Resolve alias first (alias may point to qualified ref)
      aliased = ConfigFile.resolve_model_alias(model_name)
      resolved = ModelProfile.required_model_name(aliased)
      @effective_model_name = resolved
      bare = bare_model_name(resolved)
      @profile = ModelProfile.from_model_name(bare)
      @kernel.sync_profile_from_model!(bare) if @kernel.respond_to?(:sync_profile_from_model!)
      @system_prompt = nil
      sync_kernel_client!
      if persist_default
        ConfigFile.write_default_model!(resolved)
        @default_model_name = resolved
      end
      resolved
    end

    def reset_model!
      switch_model!(@default_model_name)
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
      return [] if due.nil? || due.empty?

      reminder_lines = due.map do |r|
        "  #{r[:name]}: #{r[:description]} (interval: #{r[:interval_minutes]}m)"
      end.join("\n")
      reminder_text = "[SYSTEM: REMINDERS DUE]\n#{reminder_lines}\n[END REMINDERS]"
      # Append as a tail message to preserve prefix KV cache. Mutating the
      # head system prompt invalidates the cache for the entire conversation
      # (prompt re-evaluated every interval). A tail append keeps the prefix
      # intact — only the new reminder suffix is evaluated. Mirrors the
      # context-status injection at lib/samagotchi/kernel_loop.rb:447.
      messages << { role: "system", content: reminder_text }
      # Atomically mark all due as fired under one lock and clear the
      # IdleReminders latch so the next interval can be detected.
      @reminder_store&.mark_fired_batch(due.map { |r| r[:name] })
      @reminders&.clear_due
      # Also clear the TerminalUI queue latch (Engine#@due_reminder_names is
      # set by the IdleReminders callback). Without this, a normal-turn
      # injection (via collect_due_reminders at lib/terminal_ui.rb:732/818)
      # leaves a stale @due_reminder_names entry, causing the next
      # top-of-loop synthetic turn to fire empty and duplicate output.
      if instance_variable_defined?(:@due_reminder_names)
        instance_variable_set(:@due_reminder_names, [])
      end
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
    #   :pending_question [Hash, nil] current pending structured question
    def session_state_snapshot
      {
        status: @session&.status,
        message_count: (@session&.messages || []).size,
        last_prompt: @session&.last_prompt,
        event_seq: @session_observer&.event_count,
        metrics: @metrics.snapshot,
        pending_question: @question_mutex.synchronize { @pending_question&.dup }
      }
    end

    # ── Ask-user-question (structured qualification) ──────────────────────────

    # @return [Hash, nil] current pending question (thread-safe copy)
    def pending_question
      @question_mutex.synchronize { @pending_question&.dup }
    end

    # Request a structured question from the user. Called from KernelLoop's
    # turn thread (via dispatch). Emits :question_requested, persists to session,
    # and BLOCKS until answer_question / cancel_question wakes it (or controller
    # cancels). Returns a normalized JSON string for the tool_response.
    # @param payload [Hash] {question:, options:, header:, multi_select:, allow_freeform:}
    # @return [String] normalized answer JSON
    def request_question(payload)
      question = payload[:question].to_s.strip
      options = Samagotchi::Tools::AskUserQuestion.normalize_options_lenient(payload[:options])
      # Fallback for string JSON that lenient missed
      if options.empty? && payload[:options].is_a?(String)
        options = Samagotchi::Tools::AskUserQuestion.normalize_options_lenient(payload[:options].to_s)
      end
      if question.empty? || options.empty?
        return JSON.generate({ error: "invalid question", detail: "question and 2-8 options required (got #{options.size})" })
      end
      # Dumb-model salvage: allow single option (don't hard error, just render what we have)
      if options.size == 1
        # keep as is
      elsif options.size < 2
        return JSON.generate({ error: "invalid question", detail: "question and 2-8 options required (got #{options.size})" })
      end
      if options.size > 8
        options = options.first(8)
      end

      id = SecureRandom.uuid
      pending = {
        id: id,
        question: question,
        options: options,
        header: payload[:header].to_s.strip.empty? ? nil : payload[:header].to_s.strip,
        multi_select: !!payload[:multi_select],
        allow_freeform: !!payload[:allow_freeform],
        status: "pending",
        created_at: Time.now.iso8601(3)
      }.compact

      @question_mutex.synchronize do
        @pending_question = pending
        @question_answer = nil
      end
      # Persist to session file for WEB stub + resume (generic for all UIs)
      if @session
        @session.pending_question = pending.dup
        begin; @session.save; rescue StandardError; nil; end
      end
      # Generic emit for all UIs (TUI, WEB, Bridge, future). Observers that
      # stash this event (e.g. TerminalUI handle_question_event) will
      # discard it as stale if the synchronous handler below already answers
      # and clears pending — see drain_pending_question? staleness check.
      emit_event(nil, { type: :question_requested, pending_question: pending })

      # If a synchronous UI handler is registered (TUI), invoke it inline on the
      # SAME thread that called request_question (TerminalUI's REPL thread is the
      # turn thread — no second thread exists to answer). This avoids deadlock.
      # This path is TUI-specific but the surrounding emit/clear is generic, so
      # any future UI that registers a sync handler gets the same guarantee.
      if instance_variable_defined?(:@question_sync_handler) && @question_sync_handler
        begin
          sync_res = @question_sync_handler.call(pending.dup)
          # Handler may have called answer_question or returned a hash/string
          @question_mutex.synchronize do
            if @question_answer
              ans = @question_answer
              @pending_question = nil
              if @session
                @session.pending_question = nil
                begin; @session.save; rescue StandardError; nil; end
              end
              emit_event(nil, { type: :question_answered, id: id, answer: ans })
              return JSON.generate(ans)
            end
            if sync_res.is_a?(Hash) && sync_res[:selected]
              # Treat returned hash as answer (handler rendered and parsed)
              @question_answer = sync_res
              @pending_question = nil
              if @session
                @session.pending_question = nil
                begin; @session.save; rescue StandardError; nil; end
              end
              emit_event(nil, { type: :question_answered, id: id, answer: sync_res })
              return JSON.generate(sync_res)
            elsif sync_res.is_a?(String) && !sync_res.strip.empty?
              return sync_res
            end
          end
        rescue StandardError => e
          warn "[ask_user_question] sync handler failed: #{e.message}"
        end
        # Sync handler existed but did not produce an answer — do not deadlock on
        # CV (no cross-thread answerer exists for synchronous UIs). Clear pending
        # and return an error so the model can fallback to plain text. Generic
        # observers will discard the stale question_requested via staleness check.
        @question_mutex.synchronize { @pending_question = nil }
        if @session
          @session.pending_question = nil
          begin; @session.save; rescue StandardError; nil; end
        end
        return JSON.generate({ error: "no answer", detail: "handler failed to capture selection", id: id })
      end

      # Block until answered/cancelled (cross-thread path: WEB/Bridge/background worker)
      answer = nil
      @question_mutex.synchronize do
        loop do
          break if @question_answer
          break if active_cancel_controller&.cancelled?
          break if @pending_question.nil? || @pending_question[:status] != "pending"

          # Wait with timeout to check cancel; 0.2s matches reminder poll
          @question_cv.wait(0.2)
        end
        answer = @question_answer
        # If cancelled
        if active_cancel_controller&.cancelled? && answer.nil?
          @pending_question = nil
          if @session
            @session.pending_question = nil
            begin; @session.save; rescue StandardError; nil; end
          end
          emit_event(nil, { type: :question_cancelled, id: id, reason: active_cancel_controller.reason.to_s })
          return JSON.generate({ error: "cancelled", reason: active_cancel_controller.reason.to_s, id: id })
        end
      end

      # Clear persisted
      @question_mutex.synchronize { @pending_question = nil }
      if @session
        @session.pending_question = nil
        begin; @session.save; rescue StandardError; nil; end
      end
      if answer
        emit_event(nil, { type: :question_answered, id: id, answer: answer })
        JSON.generate(answer)
      else
        JSON.generate({ error: "no answer", id: id })
      end
    end

    # Answer the pending question (called from UI thread).
    # @param id [String] pending id
    # @param selected [Array<String>] values/labels
    # @param freeform [String, nil]
    # @return [Hash] normalized answer
    def answer_question(id:, selected:, freeform: nil)
      sel = Array(selected).map { |v| v.to_s.strip }.reject(&:empty?)
      fm = freeform.to_s.strip
      fm = nil if fm.empty?
      @question_mutex.synchronize do
        pending = @pending_question
        raise ArgumentError, "no pending question" unless pending
        raise ArgumentError, "id mismatch" unless pending[:id].to_s == id.to_s

        opts = Array(pending[:options])
        # Validate selected subset of options (value == label in v1)
        invalid = sel.reject { |v| opts.include?(v) }
        unless invalid.empty?
          raise ArgumentError, "invalid selection: #{invalid.join(', ')} (valid: #{opts.join(', ')})"
        end
        if !pending[:multi_select] && sel.size > 1
          raise ArgumentError, "single-select question: got #{sel.size} selections"
        end
        if pending[:multi_select] == false && sel.empty? && fm.nil?
          raise ArgumentError, "selection required"
        end
        # Persist pending cleared elsewhere; just set answer
        answer = { id: id.to_s, selected: sel, freeform: fm }
        # Derive indices for convenience
        answer[:selected_indices] = sel.map { |v| opts.index(v) }.compact
        @question_answer = answer
        @question_cv.broadcast
        answer
      end
    end

    def set_question_sync_handler(&block)
      @question_sync_handler = block
    end

    # Cancel the pending question (e.g. /cancel).
    def cancel_question(reason = "user")
      @question_mutex.synchronize do
        if @pending_question
          @pending_question[:status] = "cancelled"
          @question_cv.broadcast
        end
      end
      emit_event(nil, { type: :question_cancelled, reason: reason.to_s }) rescue nil
      true
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
      # Provide a cancellable controller for this turn (cross-process cancel via file flag)
      effective_controller = cancel_controller || Client::CancellationController.new
      @activity_mutex.synchronize { @active_cancel_controller = effective_controller }

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
        if messages.empty?
          messages = [system_message]
        elsif messages.first[:role].to_s != "system"
          messages.unshift(system_message)
        else
          messages[0] = system_message
        end

        # Inject due reminders as a tail system message (after history, before
        # the new user prompt) to preserve prefix KV cache. Mutating the head
        # system prompt invalidates cache for the entire prefix.
        due_reminders = collect_due_reminders(messages)
        if due_reminders.any?
          emit_event(on_event, {
            type: :reminder_injected,
            reminders: due_reminders
          })
        end

        messages << { role: "user", content: prompt }
        session.last_prompt = prompt

        sync_kernel_client!
        # Route model name as bare (without host prefix) to the transport;
        # host selection already done via active client.
        bare_for_backend = bare_model_name(@effective_model_name)
        result = @backend.complete(
          messages: messages,
          max_iterations: max_iterations,
          on_stream_event: build_stream_event_handler(on_event),
          cancel_controller: effective_controller,
          model_name: bare_for_backend,
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
        @activity_mutex.synchronize { @active_cancel_controller = nil }
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
      data = Samagotchi::ConfigFile.read_yaml(path: config_path)
      return Hooks::Loader.load(data) if data.is_a?(Hash)
      Hooks::Registry.new
    end

    # Build (or disable) the idle recap job. Recap is opt-in: it is active
    # only when (a) not explicitly disabled and (b) both a `base_url`
    # (a local OpenAI-compatible /chat/completions server) and a `model`
    # are present. Missing either fails fast with a warning and leaves
    # recap disabled — the idle job must never run with no configured
    # endpoint.
    #
    # Single precedence path: explicit `recap:` kwarg > Config registry
    # (CLI > ENV > file > default). An explicit disable (`recap: false` in
    # the config file, `recap: {enabled: false}`, or
    # SAMAGOTCHI_RECAP_ENABLED=false) always wins.
    def build_recap(recap)
      return nil if Samagotchi::Config.get("recap.enabled") == false

      # Normalize kwarg (TerminalUI passes recap: recap_config hash or nil)
      kwarg_config = recap.is_a?(Hash) ? recap : {}

      base_url = string_config(kwarg_config, :base_url) || registry_string("recap.base_url")
      host_ref = string_config(kwarg_config, :host_ref) || string_config(kwarg_config, :host) || registry_string("recap.host_ref")
      model = string_config(kwarg_config, :model) || registry_string("recap.model")

      # If host_ref given, derive base_url from host_registry entry
      if host_ref && !host_ref.empty?
        entry = @host_registry.find_entry(host_ref)
        if entry
          base_url = "http://#{entry.host}:#{entry.port}"
          # If model is host-qualified, extract bare model for recap client
          _, bare = @host_registry.parse_qualified_model(model) if model
          model = bare if bare && !bare.empty?
        else
          warn "Warning: recap host_ref '#{host_ref}' not found in hosts:; recap disabled."
          return nil
        end
      end

      if base_url.to_s.strip.empty? || model.to_s.strip.empty?
        # Something recap-related was configured but is incomplete
        if base_url || model || host_ref || !kwarg_config.empty?
          warn "Warning: SAMAGOTCHI session recap is enabled but base_url/model are missing; recap disabled. " \
               "Set recap: {host_ref:, model:} or SAMAGOTCHI_RECAP_BASE_URL and SAMAGOTCHI_RECAP_MODEL (or pass recap: {base_url:, model:})."
        end
        return nil
      end

      IdleRecap.new(
        engine: self,
        model: model.to_s.strip,
        base_url: base_url.to_s.strip,
        inactivity: recap_number_setting(kwarg_config, :inactivity, "recap.inactivity", IdleRecap::DEFAULT_INACTIVITY_SECONDS, :float),
        min_user_turns: recap_number_setting(kwarg_config, :min_user_turns, "recap.min_user_turns", IdleRecap::DEFAULT_MIN_USER_TURNS, :int),
        timeout: recap_number_setting(kwarg_config, :timeout, "recap.timeout", IdleRecap::DEFAULT_TIMEOUT_SECONDS, :float)
      )
    end

    # Read a scalar recap setting via the Config registry (ENV > file > default).
    def registry_string(key)
      value = Samagotchi::Config.get(key)
      value = value.to_s.strip
      value.empty? ? nil : value
    rescue StandardError
      nil
    end

    # Resolve a numeric recap setting: kwarg > Config registry > built-in default.
    def recap_number_setting(kwarg_config, kwarg_key, config_key, default, numeric_type)
      value = kwarg_config[kwarg_key] || kwarg_config[kwarg_key.to_s]
      value = Samagotchi::Config.get(config_key) if value.nil? || value.to_s.strip.empty?
      value = default if value.nil? || value.to_s.strip.empty?
      numeric_type == :float ? value.to_f : value.to_i
    rescue StandardError
      numeric_type == :float ? default.to_f : default.to_i
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
        reminder_store: @reminder_store,
        callback: @auto_turn_callback
      )
    end

    def string_config(config, key)
      value = config[key]
      value.to_s.strip.empty? ? nil : value.to_s
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
          ToolDeclarations::TOOL_LIST_REMINDERS,
          ToolDeclarations::TOOL_ASK_USER_QUESTION
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

        Memory priority:
          Treat loaded Project/System memories as priority knowledge — second only to the current user prompt.
          When a memory conflicts with older history or generic knowledge, prefer the memory.
          Read memories with memory_read before answering if the task touches remembered conventions.

        Structured qualification:
          When you need a clear user choice (qualification, disambiguation, confirmation), prefer ask_user_question over plain numbered lists.
          ask_user_question supports single/multi selection plus optional freeform/Other text. The harness renders it natively (TUI/Web) and returns {selected, freeform}.
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
      [thinking_token + base, rg_guidance, project_description, current_directory, memory_sections, system_identity_section, explicit_memory_section].compact.join("\n")
    end

    # B-light: auto-preload the built-in identity memory.
    # The file is installed by SystemBundle.ensure! as a normal system memory,
    # but its body is injected here so the agent has it without an extra tool call.
    # Identity is not tracked as an "activated" memory for the sticky status line
    # to avoid always showing `mem: identity`.
    def system_identity_section
      DEFAULT_SYSTEM_MEMORIES.each do |name|
        body = Tools::MemoryRead.call(name, scope: "system")
        next if body.start_with?("Error:")
        next if body.strip.empty?

        return "System identity (auto-loaded, scope=system):\n#{body}"
      end
      nil
    rescue StandardError
      nil
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
