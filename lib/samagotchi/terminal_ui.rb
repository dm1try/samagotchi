# frozen_string_literal: true

require "json"
require "fileutils"
require "io/console"
require "reline"

require_relative "model_profile"
require_relative "config"
require_relative "cancellation_controller"
require_relative "llm/errors"
require_relative "host_registry"
require_relative "context_usage"
require_relative "context_window"
require_relative "kernel_loop"
require_relative "session"
require_relative "owner_lock"
require_relative "engine"
require_relative "tools/memory"
require_relative "output_formatter"
require_relative "turn_preamble"
require_relative "turn_flow"
require_relative "session_commands"
require_relative "terminal_ui/event_renderer"
require_relative "terminal_ui/formatting"
require_relative "terminal_ui/input_support"
require_relative "terminal_ui/legacy_surface"
require_relative "terminal_ui/live_region"
require_relative "terminal_ui/question_prompt"

module Samagotchi
  # TerminalUI encapsulates the single operating mode of the harness.
  #
  # assist mode  — interactive REPL: user types, model responds, tools execute inline.
  class TerminalUI
    include Formatting
    include InputSupport

    AGENT_DESCRIPTION_FILE = "AGENT.md"
    SKIP_AGENT_DESCRIPTION_ENV = "SAMAGOTCHI_SKIP_AGENT_MD"
    STATS_COMMAND = "/stats"
    RECAP_COMMAND = "/recap"
    CONTINUE_PROMPT = "continue(yes/no/no_with_reason)> "
    THINKING_UI_ENV = "SAMAGOTCHI_THINKING_UI"
    THINKING_UI_SPINNER = "spinner"
    THINKING_UI_OFF = "off"
    THINKING_SPINNER_FRAMES = ["|", "/", "-", "\\"].freeze
    TURN_PREAMBLE_SPINNER_COLOR = 36
    MEMORY_SPINNER_COLOR = "38;5;208"
    TOOL_SPINNER_COLOR = 32
    NETWORK_RETRY_SPINNER_COLOR = 31
    MEMORY_SPINNER_PREVIEW_LIMIT = 3
    MEMORY_STICKY_PREVIEW_LIMIT = 8
    THINKING_PREVIEW_WIDTH = 120
    THINKING_PREVIEW_LINES_ENV = "SAMAGOTCHI_THINKING_PREVIEW_LINES"
    THINKING_PREVIEW_LINES_DEFAULT = 1
    THINKING_PREVIEW_LINES_MAX = 3
    THINKING_TAIL_PREVIEW_BUFFER_LIMIT = 4096
    THINKING_TOOL_PREVIEW_LIMIT = 56
    THINKING_RENDER_MIN_INTERVAL = 0.08
    THINKING_RENDER_INTERVAL_ENV = "SAMAGOTCHI_THINKING_RENDER_INTERVAL"
    STATUS_LINE_ENV = "SAMAGOTCHI_STATUS_LINE"
    STATUS_LINE_ON = "on"
    STATUS_LINE_OFF = "off"
    STATUS_WIDTH_MODE_ENV = "SAMAGOTCHI_STATUS_WIDTH_MODE"
    STATUS_WIDTH_MODE_TERMINAL_CAP = "terminal_cap"
    STATUS_WIDTH_MODE_FIXED = "fixed"
    STATUS_FIXED_WIDTH_ENV = "SAMAGOTCHI_STATUS_FIXED_WIDTH"
    STATUS_MAX_WIDTH_ENV = "SAMAGOTCHI_STATUS_MAX_WIDTH"
    STATUS_MAX_WIDTH_DEFAULT = 160
    CANCEL_MONITOR_POLL_INTERVAL = 0.05
    CTRL_C_BYTE = "\u0003"
    REMINDER_PENDING_POLL_INTERVAL = 0.5

    # Raised when another process (a `chi web` worker or another chi) owns the
    # session this TUI was asked to run.
    class SessionBusy < StandardError; end

    # ── System prompts (delegated to Engine) ─────────────────────────────────
    def self.system_prompt_for(profile)
      Engine.system_prompt_for(profile)
    end

    def initialize(mode: :assist, prompt: nil, client: nil, host_registry: nil, verbose: false, log_file: nil, profile: nil, session_id: nil, no_interrupt: false, no_default_input: false, model_name: nil, memories: [], non_interactive: false, surface: nil)
      @mode           = mode.to_sym
      @prompt         = prompt
      @default_model_name = ModelProfile.required_model_name(nil)
      aliased_model_name = model_name.to_s.strip.empty? ? nil : ConfigFile.resolve_model_alias(model_name)
      flag_model_name = aliased_model_name.to_s.strip.empty? ? nil : ModelProfile.required_model_name(aliased_model_name)
      @effective_model_name = flag_model_name || @default_model_name
      @host_registry  = host_registry || Samagotchi::HostRegistry.new
      # An injected client (specs) stands in for every host's client.
      @host_registry.client_override = client if client
      @client = @host_registry.resolve(@effective_model_name).client
      # Own the session before loading it, so a worker can't write a turn
      # between the load and the lock that this TUI would later save over.
      claim_session!(session_id) if session_id
      @resume_session = session_id ? Session.load(session_id) : nil
      if @resume_session
        # --model overrides resumed session's model (runtime only, default unchanged)
        if flag_model_name
          @effective_model_name = flag_model_name
        else
          @effective_model_name = @resume_session.model_name.to_s.strip.empty? ? @default_model_name : @resume_session.model_name
        end
        # Re-resolve client after resume may change effective model
        @client = @host_registry.resolve(@effective_model_name).client
      end
      @profile        = profile ? ModelProfile.normalize(profile) : ModelProfile.from_model_name(bare_model_for(@effective_model_name))
      @kernel         = KernelLoop.new(client: @client, verbose: verbose, log_file: log_file, profile: @profile, no_interrupt: no_interrupt, reminder_store: Samagotchi::ReminderStore.new)
      @no_default_input = no_default_input
      @non_interactive = non_interactive
      @requested_memories = Array(memories)
      @last_recap = nil
      @last_recap_generation = nil
      # Every terminal write goes through the surface. The REPL swaps in a
      # live region when the terminal can show one (#assist_loop), unless it
      # was given a surface to draw on.
      @surface = surface || LegacySurface.new
      @surface_given = !surface.nil?
      @renderer = EventRenderer.new(self)
      @render_event = ->(event) { handle_stream_event(event) }
      @engine         = Engine.new(
        mode: :assist,
        client: client,
        host_registry: @host_registry,
        verbose: verbose,
        log_file: log_file,
        profile: @profile,
        session_id: session_id,
        no_interrupt: no_interrupt,
        model_name: @default_model_name,
        memories: @requested_memories,
        kernel: @kernel,
        recap: recap_config,
        reminders: {
          callback: lambda { |due_names|
            # When a reminder is due, queue a synthetic turn that
            # run_assist_loop checks before read_input. The synthetic turn
            # uses an empty prompt so the agent can see
            # [SYSTEM: REMINDERS DUE] and act on them.
            @engine.note_due_reminders(due_names)
          }
        }
      )
      @turn_flow = TurnFlow.new(engine: @engine)
      @commands = SessionCommands.new(engine: @engine, turn_flow: @turn_flow, default_model: @default_model_name)
      # Runtime --model flag or resumed session: switch the Engine (client,
      # kernel profile) without persisting the default.
      @engine.switch_model!(@effective_model_name) if @effective_model_name != @default_model_name
      # Render an idle session-recap via the cursor-safe background writer; the
      # detector itself is Engine-owned (see Engine#recap) and opt-in.
      @recap_handle = @engine.subscribe(observer: ->(event) { handle_recap_ready(event) })
      @question_handle = @engine.subscribe(observer: ->(event) { handle_question_event(event) })
      # Synchronous TUI handler for in-turn ask_user_question: the turn thread IS the
      # REPL thread (run_engine_turn runs Engine#run_turn inline), so we must render
      # and collect input on the SAME thread without parking on a second thread.
      @engine.set_question_sync_handler do |pending|
        # render_question_widget records the choice via Engine#answer_question,
        # which Engine.request_question reads back once this handler returns.
        render_question_widget(pending)
        nil
      end
    end

    # Single dispatch for all entrypoints (interactive REPL, --prompt,
    # --non-interactive, --resume). Builds the working session and its seed
    # messages once, runs a single prompt turn when -p/--prompt is given
    # (auto-executing it, then saving), then either exits when there is no
    # follow-up REPL (--non-interactive) or drops into the REPL carrying the
    # post-turn conversation.
    def run
      unless @mode == :assist
        raise ArgumentError, "Unknown mode '#{@mode}'. Use: assist"
      end

      # --non-interactive with no --prompt is a harmless no-op exit: build
      # nothing and return (no transient session, no banner).
      return if @non_interactive && @prompt.nil?

      session = @resume_session || Session.new_session(
        mode: @mode.to_s,
        model_name: @effective_model_name,
        working_directory: Dir.pwd
      )
      claim_session!(session.id) unless @owner_lock
      # Attach before building the prompt so it can name the session id.
      @engine.session = session
      messages = messages_for(session)

      if @prompt && @non_interactive
        # Headless / CI mode: run directly without TTY rendering.
        result = @engine.run_turn(
          session,
          @prompt,
          on_event: nil,
          max_iterations: 1000,
          cancel_controller: nil
        )
        @surface.commit(result.output)
        session.save
        return
      end

      assist_loop(session: session, messages: messages)
    end

    # Take the session's OwnerLock for this process's lifetime: the TUI runs
    # its own Engine, so no worker may run the session meanwhile.
    # @raise [SessionBusy] when a worker or another TUI owns it
    def claim_session!(session_id)
      session_dir = Session.session_dir(session_id)
      @owner_lock = OwnerLock.acquire(session_dir, kind: "tui", wait: 1.0)
      return @owner_lock if @owner_lock

      owner = OwnerLock.owner(session_dir) || {}
      where = owner["kind"] == "tui" ? "another chi" : "a `chi web` worker"
      raise SessionBusy, "Session #{session_id} is open in #{where} (pid #{owner["pid"] || "unknown"}). " \
                         "Close it there first."
    end

    # Build the seed messages for the working session.
    #
    # Resumed sessions keep their prior conversation (only the system-prompt
    # slot is replaced); fresh sessions start with just the system prompt.
    # Prints a one-line banner so the user sees which session they're in.
    def messages_for(session)
      system_message = { role: "system", content: seed_system_prompt }
      if @resume_session
        messages = session.messages.dup
        if messages.empty?
          messages = [system_message]
        else
          messages[0] = system_message
        end
        @surface.commit("Resumed session: #{session.id}")
      else
        messages = [system_message]
        @surface.commit("Session: #{session.id}")
      end
      messages
    end

    # Public entrypoint for background session workers.
    # Keeps worker call sites out of TerminalUI private API details.
    def process_background_prompt(session:, prompt:)
      @engine.process_background_prompt(session: session, prompt: prompt)
    end

    private

    # Generate profile-aware tool calling hint.
    # Kept as a one-line delegator to Engine (single source of truth).
    def tool_call_hint
      return @engine.tool_call_hint
    end

    # Assist system prompt — delegates wholesale to Engine so the two can
    # never drift apart. This single delegator fixes the 4-line regression.
    def assist_system_prompt
      return @engine.assist_system_prompt
    end

    # Interactive REPL loop. Session seed + messages are built by #run and
    # threaded in here (so --prompt / --resume share one code path). The
    # working session is persisted at the end of every turn.
    def assist_loop(session:, messages:)
      load_persistent_history

      # queue_default_input self-guards on @resume_session, so calling it
      # unconditionally preserves the original fresh-session prefill behavior.
      # Skip the default input prefill when a user-provided --prompt was used —
      # the explicit prompt means the user is in command and shouldn't see the
      # default input ("Hey Chi," etc.) on the next REPL prompt.
      queue_default_input if @prompt.nil?

      # The idle layer (reminders + optional recap) is Engine-owned; start the
      # shared scheduler for this REPL and stop it on exit. with_activity_hook
      # resets the shared inactivity clock when a prompt opens and on each key.
      with_live_region do
        with_interrupt_arbiter do
          @engine.start_idle
          with_activity_hook do
            run_assist_loop(session: session, messages: messages)
          ensure
            @engine.stop_idle
          end
        end
      end
    end

    # Ctrl-C while a Reline read owns stdin: Reline's INT trap catches it, so
    # the REPL hears of it through RelineSeam. A running turn is cancelled and
    # the prompt stays as typed; with no turn running it is Reline's Ctrl-C.
    # (With no read open, Ctrl-C stays an Interrupt on the turn's thread.)
    def with_interrupt_arbiter
      return yield unless RelineSeam.supported?

      RelineSeam.install
      previous = RelineSeam.interrupt_handler
      RelineSeam.interrupt_handler = method(:cancel_turn_from_prompt)
      begin
        yield
      ensure
        RelineSeam.interrupt_handler = previous
      end
    end

    # @return [Boolean] a running turn was cancelled
    def cancel_turn_from_prompt
      controller = @active_cancel_controller
      return false unless controller

      controller.cancel!(:ctrl_c)
      true
    end

    # Draw the REPL on a live region (a Screen, with Reline's prompt in it)
    # when the terminal can show one; plain output otherwise, or on the
    # surface the UI was given.
    def with_live_region
      screen = LiveRegion.open unless @surface_given
      return yield unless screen

      plain = @surface
      @surface = screen
      begin
        yield
      ensure
        @surface = plain
        LiveRegion.close(screen)
      end
    end

    # Interactive REPL loop. Session seed + messages are built by #run and
    # threaded in here (so --prompt / --resume share one code path). The
    # session's conversation is the single working copy: turns go through
    # Engine#run_turn and out-of-turn edits through Engine's messages API.
    # The checkpoint and continue state live in @turn_flow (shared with
    # session workers). The session is persisted at the end of every turn.
    def run_assist_loop(session:, messages:)
      session.messages = messages
      @engine.session = session
      # UI-agnostic steering queue. Nothing pushes mid-turn in the TUI yet
      # (typed-during-generation input is intentionally out of scope — the tty
      # render stack is too fragile), but wiring the drain here keeps the
      # interface live and identical to the web/background hosts.
      @pending_input_queue = PendingInputQueue.new

      loop do
        # Drain any pending ask_user_question first — it has priority over reminders and
        # must be rendered on the REPL thread (turn thread is parked on Engine Monitor).
        drain_pending_question?

        # A due reminder runs its turn now. The prompt may be open (a read
        # left running by #poll_input_with_reminder_check): the turn's output
        # commits above it and whatever is typed there stays.
        unless @engine.due_reminder_names.empty?
          run_reminder_turn(session)
          @turn_flow.after_reminder_turn
          next
        end
        input = @prompt
        @prompt = nil if input
        if input.nil?
          input = poll_input_with_reminder_check(awaiting_continue: @turn_flow.awaiting_continue?)
          # A reminder fell due: run it at the top, with the prompt still open.
          next if input == :due
        end
        break if input.nil?
        break if exit_command?(input)

        if @turn_flow.awaiting_continue?
          answer_continue_offer(session, input)
        else
          run_input_line(session, input)
        end
      end

      @surface.commit("\nContinue session: chi --resume #{session.id}")
    end

    # An answer at the continue(yes/no/no_with_reason) prompt.
    def answer_continue_offer(session, input)
      answer = @commands.continue_answer(input)
      return show_command_result(answer) unless answer.resume

      @turn_flow.before_continue_turn
      begin
        result = run_engine_turn(session, nil, continue: true)
      rescue LLM::ProviderError => e
        @surface.commit("\nmodel> #{e.summary}; continue prompt preserved")
        return
      end
      finish_turn(session, result, continue: true)
    end

    # A line at the main prompt: a command, or a prompt for a turn.
    def run_input_line(session, input)
      return if input.empty?

      # /model, /models, !rollback, !cmd, /continue (shared with workers)
      if (command = @commands.run(input))
        show_command_result(command)
        persist_recent_history(input) if command.shell
        return
      end
      return @surface.commit("\nmodel> session stats:\n#{format_session_metrics(@engine.metrics.snapshot)}") if stats_command?(input)
      return @surface.commit("\nmodel> #{handle_recap_command}") if recap_command?(input)

      @turn_flow.before_prompt_turn
      persist_recent_history(input)
      begin
        # Engine#run_turn injects due reminders as a tail message, appends
        # the prompt, and renders through @renderer via on_event.
        result = run_engine_turn(session, normalize_model_input(input))
      rescue LLM::ProviderError => e
        # Engine closed the turn (:turn_failed); show its duration.
        # Retries were already tallied via generation_retrying events.
        emit_interactive_turn_duration(canceled: false)
        @turn_flow.prompt_turn_failed
        queue_input_prefill(input)
        @surface.commit("\nmodel> #{e.summary}; prompt restored for retry")
        return
      end
      finish_turn(session, result, continue: false)
    end

    # After a prompt or continue turn: TurnFlow keeps the checkpoint and the
    # continue offer; the REPL saves and tells the user.
    def finish_turn(session, result, continue:)
      if result.respond_to?(:canceled?) && result.canceled?
        outcome = @turn_flow.after_turn(result, continue: continue)
        # A cancelled continue is back where it started, the offer still open.
        return if outcome == :continue_cancelled

        # Ctrl-C on a fresh turn. The kernel salvaged completed tool calls
        # and the partial assistant reply (marked [interrupted]) into
        # result.conversation, so progress is preserved by default — the
        # user's next message continues from it. !rollback restores the
        # pre-turn checkpoint for an explicit full discard.
        emit_interactive_turn_duration(canceled: true)
        save_session(session) if result.respond_to?(:conversation) && result.conversation.is_a?(Array)
        @surface.commit("\nmodel> turn cancelled; partial progress kept in context; use !rollback immediately after cancellation to restore the pre-turn checkpoint")
        return
      end

      # The REPL keeps the kernel's conversation as-is (no [No response]
      # placeholder), so /continue resumes from the tool results.
      session.messages = result.conversation
      @turn_flow.after_turn(result, continue: continue)
      save_session(session)
    end

    def save_session(session)
      session.model_name = @effective_model_name
      session.save
    end

    # A !cmd shows its own output; everything else is the model> line.
    def show_command_result(result)
      if result.shell
        @surface.commit(result.output)
        @surface.commit("")
      else
        @surface.commit("\nmodel> #{result.output}")
      end
      sync_model_mirrors if result.changed.include?(:model)
    end

    # The status line and the next session save read these.
    def sync_model_mirrors
      @effective_model_name = @engine.effective_model_name
      @default_model_name = @commands.default_model
      @profile = @engine.profile
    end

    def status_server_segment
      # Show per-host info when multi-host is configured
      if @host_registry && @host_registry.entries.size > 1
        active = @host_registry.resolve(@effective_model_name).entry rescue nil
        if active
          host = active.host
          port = active.port
          total = @host_registry.entries.size
          return "" if ["localhost", "127.0.0.1"].include?(host) && total == 1
          # When multiple hosts, always show active + count
          return "server=#{host}:#{port} (#{total} hosts)"
        end
      end
      host = Samagotchi::Config.get("server.host")
      return "" if ["localhost", "127.0.0.1"].include?(host)

      port = Samagotchi::Config.get("server.port")
      "server=#{host}:#{port}"
    end

    # Engine's built-once system prompt (the one run_turn sends), plus the
    # --memory activations it recorded for the sticky status line.
    def seed_system_prompt
      prompt = @engine.system_prompt
      sync_engine_activated_memories
      prompt
    end

    # Appends the current memory index to the base system prompt so the agent
    # is always aware of stored memories without needing to call a tool first.
    # Delegates wholesale to Engine (single source of truth).
    def system_prompt_with_index(base)
      result = @engine.system_prompt_with_index(base)
      # Mirror any --memory activations the Engine performed so the sticky
      # status line can surface them. The prompt body injection moved into
      # Engine; echoing the activated names here is purely a UI concern.
      sync_engine_activated_memories
      result
    end

    # Engine owns the system prompt (including --memory activation), but the
    # sticky status line is a UI concern. Mirror the activated names so they
    # appear in the status line.
    def sync_engine_activated_memories
      @engine.activated_memory_names.each do |name|
        add_unique_memory_name(:@session_memory_names, name)
      end
    end

    # Render a result from a turn that bypassed Engine#run_turn (continue,
    # reminder turns) exactly as a :turn_completed would be rendered.
    def emit_result(result)
      @renderer.render_turn_summary(@engine.turn_summary(result))
    end

    # ── Turn view: the drawing surface EventRenderer calls ──────────────────
    public

    def emit_active_memories_line
      lines = sticky_status_lines(width: status_effective_width)
      return if lines.empty?

      lines.each { |line| @surface.commit(line) }
    end

    def print_line(text)
      @surface.commit(text)
    end

    def reset_turn_feedback
      clear_retry_spinner_status
      reset_thinking_memory_notification
      reset_thinking_memory_names
      reset_thinking_tool_notification
    end

    def generation_feedback_started(event = {})
      @context_window_tokens = event[:context_window_tokens] if event[:context_window_tokens]
      start_cancel_hotkey_monitor(@active_cancel_controller)
      clear_retry_spinner_status
      @latest_server_context_status = nil
      reset_thinking_tail_preview
      reset_turn_preamble
      start_thinking_spinner
    end

    def generation_feedback_retrying(event)
      set_retry_spinner_status(event)
      refresh_thinking_spinner_status
    end

    def generation_feedback_chunk(event)
      clear_retry_spinner_status if retry_spinner_status_active?
      capture_server_context_status_from_payload(event[:payload])
      capture_thinking_tail_chunk(event[:content])
      capture_turn_preamble_chunk(event[:thinking])
      tick_thinking_spinner
    end

    def tool_call_feedback_started(event)
      clear_retry_spinner_status
      memory_loaded = capture_memory_tool_call(event)
      capture_thinking_tool_call(event) if memory_loaded
      refresh_thinking_spinner_status
    end

    def clear_generation_retry
      clear_retry_spinner_status
    end

    def generation_feedback_finished
      stop_cancel_hotkey_monitor
      clear_retry_spinner_status
      reset_thinking_tail_preview
      reset_turn_preamble
      finish_thinking_spinner
    end

    # The kernel reports the last emitted context status on the result; keep
    # the previous one when a turn reports none.
    def capture_context_status(status)
      return unless status

      @latest_context_status = {
        est_pct: status[:est_pct],
        bucket: status[:bucket]
      }
    end

    private

    def emit_interactive_turn_duration(canceled:)
      record = Array(@engine.metrics.snapshot[:turn_records]).last
      return unless record && record[:duration_ms]

      state = canceled ? "canceled" : "completed"
      @surface.commit("#{paint('chi>', 36)} turn #{state} (#{format_elapsed_duration(record[:duration_ms])})")
    end

    def split_memory_scope(raw)
      value = raw.to_s.strip
      if value.include?("/")
        scope, name = value.split("/", 2)
        return [scope, name] if Tools::VALID_SCOPES.include?(scope)
      end

      [nil, value]
    end

    def read_input(awaiting_continue:)
      emit_idle_status_line

      if awaiting_continue
        prompt = color_output? ? paint(CONTINUE_PROMPT, 33) : CONTINUE_PROMPT
        input = Reline.readline(prompt, true)
        return nil if input.nil?

        return input.strip
      end

      read_prompt_line(paint("> ", 92))
    rescue Interrupt
      nil
    end

    # The synthetic turn for due reminders (Engine#run_turn injects them as
    # a tail message). The hints row says which, while it runs.
    def run_reminder_turn(session)
      names = @engine.due_reminder_names
      @engine.clear_due_reminder_names!
      # A normal turn may already have injected them (a stale latch): no
      # empty synthetic turn then (it duplicated output).
      return unless @engine.reminders_due?

      hint = "reminder: #{names.join(", ")} · Ctrl-C cancels it"
      @surface.set_slot(:hints, [color_output? ? paint(hint, 90) : hint])
      result = nil
      begin
        result = run_engine_turn(session, nil, continue: true)
        @prompt = nil
      rescue LLM::ProviderError => e
        # like other failed turns: back to the prompt
        @surface.commit("\nmodel> #{e.summary}")
      ensure
        @surface.clear_slot(:hints)
      end
      canceled = result.respond_to?(:canceled?) && result.canceled?
      emit_interactive_turn_duration(canceled: canceled)
      if result && !canceled
        session.messages = result.conversation if result.respond_to?(:conversation) && result.conversation.is_a?(Array)
        session.model_name = @effective_model_name
        session.save
      end
      # The synthetic turn is activity: the next reminder waits a full
      # interval (without it they fired back to back).
      @engine.record_activity
    end

    # The next line from the prompt, or :due when a reminder falls due first.
    # On a terminal the read runs on its own thread and stays open across a
    # :due: the reminder turn runs with the prompt (and anything typed in it)
    # still there, and a line submitted meanwhile is returned afterwards.
    # Ctrl-C during that turn reaches #cancel_turn_from_prompt.
    def poll_input_with_reminder_check(awaiting_continue:)
      return :due unless @engine.due_reminder_names.empty?
      # Specs and pipes: a plain blocking read.
      return read_input(awaiting_continue: awaiting_continue) unless STDIN.tty? && $stdin.tty?

      @prompt_reader ||= Thread.new do
        Thread.current.report_on_exception = false
        read_input(awaiting_continue: awaiting_continue)
      end
      loop do
        unless @prompt_reader.alive?
          reader = @prompt_reader
          @prompt_reader = nil
          return reader.value
        end
        return :due unless @engine.due_reminder_names.empty?

        @prompt_reader.join(REMINDER_PENDING_POLL_INTERVAL)
      end
    end

    def shell_bang_command?(input)
      input.to_s.match?(/\A!\s*\S/)
    end

    def stats_command?(input)
      input.to_s.strip == STATS_COMMAND
    end

    def recap_command?(input)
      input.to_s.strip == RECAP_COMMAND
    end

    # SessionCommands runs /model; the REPL mirrors the result.
    def handle_model_command(input)
      result = @commands.run(input)
      sync_model_mirrors
      result.output
    end

    def handle_models_command
      @commands.run(SessionCommands::MODELS_COMMAND).output
    end

    # Handle /recap command - display the last generated recap
    def handle_recap_command
      unless @engine.recap
        return "recap feature not enabled (add recap: {host_ref:, model:} to config.yml, " \
               "or set SAMAGOTCHI_RECAP_BASE_URL and SAMAGOTCHI_RECAP_MODEL)"
      end

      if @last_recap
        # Any later turn (or recap attempt) bumps the generation, so a
        # mismatch means the conversation moved on since this recap.
        stale = @engine.recap.generation != @last_recap_generation
        "session recap#{' (from before your latest turn)' if stale}:\n#{@last_recap}"
      else
        recap = @engine.recap
        "no recap available yet — the session needs at least #{recap.min_user_turns} user turns and #{recap.inactivity.to_i}s of inactivity to generate one automatically"
      end
    end

    # A resumed session doesn't get the default input either.
    def default_input_wanted? = !@resume_session && !@no_default_input

    def exit_command?(input)
      normalized = input.to_s.strip.downcase
      normalized == "exit" || normalized == "/exit"
    end

    def clone_messages(messages)
      Array(messages).map(&:dup)
    end

    def skip_agent_description?
      value = ENV[SKIP_AGENT_DESCRIPTION_ENV]
      value == "1" || value&.casecmp?("true")
    end

    def rg_available?
      system("command -v rg", out: File::NULL, err: File::NULL)
    end

    # Run one REPL turn (a prompt, or a continue/reminder turn with nil) through
    # Engine#run_turn, rendering via @renderer.
    def run_engine_turn(session, prompt, continue: false, max_iterations: 100)
      cancellation_controller = CancellationController.new
      @active_cancel_controller = cancellation_controller
      @renderer.begin_turn
      # Build the (memoized) prompt now so --memory activations show in this
      # turn's status lines, including after /model rebuilt it.
      seed_system_prompt
      result = @engine.run_turn(
        session,
        prompt,
        on_event: @render_event,
        max_iterations: max_iterations,
        cancel_controller: cancellation_controller,
        pending_input: @pending_input_queue&.method(:drain),
        continue: continue
      )
      emit_cancellation_notice(result)
      result
    rescue Interrupt
      # Engine kept the prompt in the session and emitted :turn_canceled.
      cancellation_controller&.cancel!(:ctrl_c)
      result = cancelled_result_from(session.messages, reason: :ctrl_c)
      emit_cancellation_notice(result)
      result
    ensure
      stop_cancel_hotkey_monitor
      @active_cancel_controller = nil
      finish_thinking_spinner
    end

    # The REPL's on_event sink for Engine#run_turn: render one event. Engine
    # swallows on_event errors to protect the turn, so log ours instead.
    def handle_stream_event(event)
      @renderer.call(event)
    rescue StandardError => e
      warn "[render] #{event[:type]}: #{e.class}: #{e.message}"
    end

    def emit_cancellation_notice(result)
      return unless result.respond_to?(:canceled?) && result.canceled?

      reason = result.respond_to?(:cancellation_reason) ? result.cancellation_reason : nil
      label = cancellation_reason_label(reason)
      @surface.commit("\nmodel> request cancelled#{label.empty? ? "" : " (#{label})"}")
    end

    def cancelled_result_from(messages, reason:)
      KernelLoop::Result.new(
        output: "",
        conversation: clone_messages(messages),
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: [],
        canceled: true,
        cancellation_reason: reason
      )
    end

    def cancellation_reason_label(reason)
      return "" if reason.nil?

      case reason.to_sym
      when :ctrl_c
        "ctrl-c"
      else
        reason.to_s
      end
    end

    def start_cancel_hotkey_monitor(cancellation_controller)
      return unless cancellation_controller
      return unless cancel_hotkey_monitor_enabled?
      # Reline has stdin (and its own tty mode) while a read is open, and the
      # seam hands its Ctrl-C to the turn; a second reader would steal keys.
      return if RelineSeam.reading?

      stop_cancel_hotkey_monitor
      @cancel_hotkey_stop_requested = false

      @cancel_hotkey_thread = Thread.new do
        Thread.current.report_on_exception = false
        stdin = $stdin

        begin
          with_cancel_hotkey_input_mode(stdin) do
            loop do
              break if @cancel_hotkey_stop_requested
              break if cancellation_controller.cancelled?

              readable = IO.select([stdin], nil, nil, CANCEL_MONITOR_POLL_INTERVAL)
              next unless readable

              key = begin
                stdin.read_nonblock(1)
              rescue IO::WaitReadable, EOFError
                nil
              end
              next if key.nil?

              process_cancel_hotkey_char(key, at: monotonic_time, controller: cancellation_controller)
              break if cancellation_controller.cancelled?
            end
          end
        rescue StandardError
          nil
        end
      end
    end

    def stop_cancel_hotkey_monitor
      thread = @cancel_hotkey_thread
      @cancel_hotkey_thread = nil
      @cancel_hotkey_stop_requested = true
      return unless thread
      return if thread == Thread.current

      thread.join(CANCEL_MONITOR_POLL_INTERVAL * 3)
    rescue StandardError
      nil
    end

    def with_cancel_hotkey_input_mode(stdin)
      stdin.cbreak do
        yield
      end
    end

    def cancel_hotkey_monitor_enabled?
      return false unless @mode == :assist
      return false unless $stdin.tty?
      return false unless $stdout.tty?

      ENV.fetch("TERM", "") != "dumb"
    end

    def process_cancel_hotkey_char(char, at:, controller:)
      if char == CTRL_C_BYTE
        controller.cancel!(:ctrl_c)
      end
    end

    def start_thinking_spinner
      return unless thinking_spinner_enabled?

      @thinking_spinner_active = true
      @thinking_spinner_index = 0 if @thinking_spinner_index.nil?
      @thinking_spinner_last_render_at = nil
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = false
      render_thinking_spinner
    end

    def tick_thinking_spinner
      return unless @thinking_spinner_active

      @thinking_spinner_index = (@thinking_spinner_index + 1) % THINKING_SPINNER_FRAMES.length
      render_thinking_spinner_if_due
    end

    def refresh_thinking_spinner_status
      return unless @thinking_spinner_active

      render_thinking_spinner
    end

    def render_thinking_spinner_if_due
      return render_thinking_spinner if force_spinner_render?

      last = @thinking_spinner_last_render_at
      return render_thinking_spinner if last.nil?
      return if (monotonic_time - last) < thinking_render_min_interval

      render_thinking_spinner
    end

    def force_spinner_render?
      @thinking_tail_preview_dirty && !@thinking_preview_has_content
    end

    public

    # Erase the spinner rows; nothing to do when none are shown.
    def finish_thinking_spinner
      return unless @surface.clear_slot(:activity)

      @thinking_spinner_active = false
      @thinking_spinner_last_render_at = nil
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = false
    end

    private

    # Only Qwen streams thinking cleanly enough (explicit close marker) for a
    # reliable turn-preamble extraction; Gemma 4 keeps the raw preview instead.
    def turn_preamble_enabled?
      @profile&.name == "qwen36" && Samagotchi::Config.get("thinking.turn_preamble") != false
    end

    def reset_turn_preamble
      @turn_preamble = TurnPreamble.new
    end

    def capture_turn_preamble_chunk(thinking_chunk)
      return unless turn_preamble_enabled?

      (@turn_preamble ||= TurnPreamble.new).feed(thinking_chunk)
    end

    def turn_preamble_status_base(frame)
      return nil unless turn_preamble_enabled?

      phrase = @turn_preamble&.phrase
      return nil if phrase.nil? || phrase.empty?

      "chi> #{phrase} #{frame}"
    end

    def capture_thinking_tail_chunk(chunk)
      return unless thinking_tail_preview_enabled?
      return if chunk.nil? || chunk.empty?

      buffer = String.new(@thinking_tail_preview_buffer.to_s)
      buffer << chunk.to_s
      @thinking_tail_preview_buffer = buffer[-THINKING_TAIL_PREVIEW_BUFFER_LIMIT, THINKING_TAIL_PREVIEW_BUFFER_LIMIT] || buffer
      @thinking_tail_preview_dirty = true
    end

    def thinking_tail_preview_enabled?
      @thinking_spinner_active
    end

    def thinking_tail_preview_line
      lines, has_content = thinking_tail_preview_lines
      return nil unless has_content

      lines.first
    end

    # @param width [Integer] the status width (#status_effective_width)
    def thinking_tail_preview_lines(width: status_effective_width)
      line_count = thinking_preview_lines_count
      prefix = "model> … "
      continuation = " " * prefix.length
      preview_width = thinking_preview_width(width)
      first_width = [preview_width - prefix.length, 1].max
      continuation_width = [preview_width - continuation.length, 1].max

      text = thinking_tail_preview_text
      capacity = thinking_tail_preview_capacity(width)
      text = text[-capacity, capacity] || text
      chunks = [text.slice(0, first_width).to_s]
      offset = first_width
      (line_count - 1).times do
        chunks << text.slice(offset, continuation_width).to_s
        offset += continuation_width
      end

      lines = [cap_preview_line("#{prefix}#{chunks[0]}", width)]
      chunks.drop(1).each do |chunk|
        lines << cap_preview_line("#{continuation}#{chunk}", width)
      end

      [lines, !text.empty?]
    end

    def thinking_tail_preview_text
      raw = @thinking_tail_preview_buffer.to_s
      return "" if raw.empty?

      # OutputFormatter strips both wire-format token families (control +
      # literal) as the single source of truth; the single-line preview then
      # collapses whitespace for display.
      OutputFormatter.strip(raw).gsub(/\s+/, " ").strip
    end

    def reset_thinking_tail_preview
      @thinking_tail_preview_buffer = String.new
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = false
    end

    def retry_spinner_status_line(frame, width)
      data = @retry_spinner_status || {}
      attempt = data[:attempt].to_i
      max_retries = data[:max_retries].to_i
      total_attempts = max_retries + 1
      delay = format("%.1f", data[:next_delay].to_f)
      error_class = data[:error_class].to_s
      message = "model> network error: retrying (#{attempt}/#{total_attempts} in #{delay}s) #{frame}"
      message += " #{error_class}" unless error_class.empty?
      capped = cap_preview_line(message, width)
      color_output? ? paint(capped, NETWORK_RETRY_SPINNER_COLOR) : capped
    end

    def cap_preview_line(text, width)
      cap_preview_text(text, thinking_preview_width(width))
    end

    def thinking_preview_width(width)
      return THINKING_PREVIEW_WIDTH if width <= 0

      [width, THINKING_PREVIEW_WIDTH].min
    end


    def thinking_preview_lines_count
      raw = ENV.fetch(THINKING_PREVIEW_LINES_ENV, THINKING_PREVIEW_LINES_DEFAULT.to_s).to_s.strip
      value = Integer(raw)
      value = THINKING_PREVIEW_LINES_DEFAULT unless value.positive?
      [[value, 1].max, THINKING_PREVIEW_LINES_MAX].min
    rescue ArgumentError
      THINKING_PREVIEW_LINES_DEFAULT
    end

    def thinking_tail_preview_capacity(width)
      prefix_length = "model> … ".length
      preview_width = thinking_preview_width(width)
      first_width = [preview_width - prefix_length, 1].max
      continuation_width = first_width
      first_width + ((thinking_preview_lines_count - 1) * continuation_width)
    end

    def thinking_render_min_interval
      value = ENV.fetch(THINKING_RENDER_INTERVAL_ENV, THINKING_RENDER_MIN_INTERVAL.to_s).to_f
      return THINKING_RENDER_MIN_INTERVAL unless value.positive?

      value
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def capture_memory_tool_call(event)
      call = event[:call].is_a?(Hash) ? event[:call] : {}
      memory_name = memory_name_from_tool_call(call)
      return false if memory_name.nil? || memory_name.empty?

      added_to_thinking = add_unique_memory_name(:@thinking_memory_names, memory_name)
      add_unique_memory_name(:@session_memory_names, memory_name)
      @thinking_recent_memory_loaded = memory_name if added_to_thinking
      added_to_thinking
    end

    def capture_thinking_tool_call(event)
      call = event[:call].is_a?(Hash) ? event[:call] : {}
      name = call[:name].to_s.strip
      return if name.empty?

      params = thinking_tool_params_preview(call, event[:params])
      text = params.empty? ? name : "#{name}(#{params})"
      @thinking_recent_tool_call = cap_preview_text(text, THINKING_TOOL_PREVIEW_LIMIT)
    end

    def thinking_tool_params_preview(call, raw_params)
      compact = raw_params.to_s.gsub(/\s+/, " ").strip
      return compact unless compact.empty?

      tool_name = call[:name].to_s
      case tool_name
      when Tools::Execute::NAME
        "command=#{preview_value_for_spinner(call[:content])}"
      when Tools::Read::NAME
        "path=#{preview_value_for_spinner(call[:content])}"
      when Tools::Write::NAME, Tools::Edit::NAME
        "path=#{preview_value_for_spinner(call[:path])}"
      when Tools::MemoryRead::NAME
        parts = []
        name = call[:content].to_s.strip
        parts << "name=#{preview_value_for_spinner(name)}" unless name.empty?
        scope = call[:scope].to_s.strip
        parts << "scope=#{preview_value_for_spinner(scope)}" unless scope.empty?
        parts.join(" ")
      when Tools::MemoryWrite::NAME
        parts = []
        path = call[:path].to_s.strip
        parts << "name=#{preview_value_for_spinner(path)}" unless path.empty?
        scope = call[:scope].to_s.strip
        parts << "scope=#{preview_value_for_spinner(scope)}" unless scope.empty?
        parts.join(" ")
      else
        ""
      end
    end

    def preview_value_for_spinner(value)
      text = value.to_s.gsub(/\s+/, " ").strip
      return '""' if text.empty?

      text.inspect
    end

    def add_unique_memory_name(ivar_name, value)
      names = instance_variable_get(ivar_name) || []
      return false if names.include?(value)

      names << value
      instance_variable_set(ivar_name, names)
      true
    end

    def memory_name_from_tool_call(call)
      tool_name = call[:name].to_s
      case tool_name
      when Tools::MemoryRead::NAME
        normalize_memory_name(call[:content])
      when Tools::Read::NAME
        memory_name_from_read_path(call[:content])
      else
        nil
      end
    end

    def normalize_memory_name(raw)
      value = raw.to_s.strip
      return nil if value.empty?

      File.basename(value, ".md")
    end

    def memory_name_from_read_path(raw_path)
      path = raw_path.to_s.strip.tr("\\", "/")
      return nil if path.empty?
      return nil unless path.match?(/memories[\/].+\.md\z/)

      normalize_memory_name(path)
    end

    def memory_spinner_segment
      segment = memory_spinner_segment_plain
      return "" if segment.empty?

      color_output? ? paint(segment, MEMORY_SPINNER_COLOR) : segment
    end

    def memory_spinner_segment_plain
      names = Array(@thinking_memory_names)
      return "" if names.empty?

      visible = names.first(MEMORY_SPINNER_PREVIEW_LIMIT)
      suffix = names.length > visible.length ? ", +#{names.length - visible.length}" : ""
      " mem: #{visible.join(', ')}#{suffix}"
    end

    def memory_sticky_line
      names = Array(@session_memory_names)
      return "" if names.empty?

      visible = names.first(MEMORY_STICKY_PREVIEW_LIMIT)
      suffix = names.length > visible.length ? ", +#{names.length - visible.length}" : ""
      body = "memories> active this session: #{visible.join(', ')}#{suffix}"
      color_output? ? paint(body, MEMORY_SPINNER_COLOR) : body
    end

    def reset_thinking_memory_names
      @thinking_memory_names = []
    end

    def reset_thinking_memory_notification
      @thinking_recent_memory_loaded = nil
    end

    def reset_thinking_tool_notification
      @thinking_recent_tool_call = nil
    end

    def capture_context_status_from_result(result)
      capture_context_status(result.respond_to?(:context_status) ? result.context_status : nil)
    end

    def capture_server_context_status_from_payload(payload)
      # The window the kernel resolved for this generation (see
      # :generation_started); the configured one before the first generation.
      window_tokens = @context_window_tokens || ContextWindow.configured.tokens
      normalized = ContextUsage.normalize(payload, window_tokens: window_tokens)
      return unless normalized

      @latest_server_context_status = normalized
    end


    def emit_idle_status_line
      return unless status_line_enabled?

      lines = idle_status_lines(width: status_effective_width)
      return if lines.empty?

      @surface.set_slot(:status, lines)
    end

    # ── Idle session recap ───────────────────────────────────────────────────
    #
    # The Engine's idle detector (opt-in via SAMAGOTCHI_RECAP_BASE_URL +
    # SAMAGOTCHI_RECAP_MODEL) emits a :recap_ready event once the session has
    # been idle for its inactivity threshold. We store it for on-demand display
    # via the /recap command.

    def handle_recap_ready(event)
      return unless event[:type] == :recap_ready
      recap = event[:recap]
      generation = event[:generation]
      return if recap.nil? || recap.to_s.strip.empty?
      return unless @engine.recap&.generation == generation
      # Store the recap for on-demand display via /recap command
      @last_recap = recap
      @last_recap_generation = generation
    end

    # Resolve the recap config (OFF by default). Returns false when explicitly
    # disabled, nil when nothing is configured, or a Hash when enabled so the
    # Engine can build the detector. Single precedence path via the Config
    # registry: CLI > ENV (SAMAGOTCHI_RECAP_*) > file (recap:) > default.
    def recap_config
      ConfigFile.recap_config
    end

    def bare_model_for(full_ref)
      @host_registry.bare_name(full_ref)
    end

    def spinner_status_line
      return "" unless status_line_enabled?

      lines = spinner_status_lines
      lines.empty? ? "" : lines.first
    end

    def spinner_status_lines(width: status_effective_width)
      return [] unless status_line_enabled?

      build_status_lines(scope: :spinner, width: width)
    end

    def sticky_status_line
      return "" unless status_line_enabled?

      lines = sticky_status_lines
      lines.empty? ? "" : lines.first
    end

    def sticky_status_lines(width: status_effective_width)
      return [] unless status_line_enabled?

      build_status_lines(scope: :sticky, width: width)
    end

    def idle_status_line
      return "" unless status_line_enabled?

      lines = idle_status_lines
      lines.empty? ? "" : lines.first
    end

    def idle_status_lines(width: status_effective_width)
      return [] unless status_line_enabled?

      build_status_lines(scope: :idle, width: width)
    end

    def build_status_line(scope:)
      lines = build_status_lines(scope: scope)
      lines.empty? ? "" : lines.first
    end

    # The status rows for +scope+ (:spinner, :sticky or :idle), cut to +width+.
    def build_status_lines(scope:, width: status_effective_width)
      status_rows(status_segments(scope), width)
    end


    def status_width_mode
      mode = ENV.fetch(STATUS_WIDTH_MODE_ENV, STATUS_WIDTH_MODE_TERMINAL_CAP).to_s.strip.downcase
      return STATUS_WIDTH_MODE_FIXED if mode == STATUS_WIDTH_MODE_FIXED

      STATUS_WIDTH_MODE_TERMINAL_CAP
    end

    def status_effective_width
      mode = status_width_mode
      width = if mode == STATUS_WIDTH_MODE_FIXED
                status_fixed_width
              else
                [terminal_columns, status_max_width].min
              end
      width = status_fixed_width unless width.positive?
      width
    end

    def status_fixed_width
      env_positive_int(STATUS_FIXED_WIDTH_ENV, THINKING_PREVIEW_WIDTH)
    end

    def status_max_width
      env_positive_int(STATUS_MAX_WIDTH_ENV, STATUS_MAX_WIDTH_DEFAULT)
    end

    def terminal_columns
      columns = begin
        io = IO.console
        io&.winsize&.[](1).to_i
      rescue StandardError
        0
      end
      return columns if columns.positive?

      env_positive_int("COLUMNS", status_max_width)
    end

    def env_positive_int(key, default)
      value = ENV.fetch(key, default.to_s).to_i
      value.positive? ? value : default
    end

    def status_segments(scope)
      segments = [status_model_segment, status_server_segment].reject(&:empty?)
      context_segment = status_context_segment
      memory_segment = status_memory_segment(scope)
      segments << context_segment unless context_segment.empty?
      segments << memory_segment unless memory_segment.empty?
      segments
    end

    def status_model_segment
      status_model_text(@effective_model_name, @default_model_name)
    end

    def status_context_segment
      status_context_text(server: @latest_server_context_status, estimate: @latest_context_status)
    end

    def status_memory_segment(scope)
      names, limit = case scope
                     when :spinner
                       [Array(@thinking_memory_names), MEMORY_SPINNER_PREVIEW_LIMIT]
                     else
                       [Array(@session_memory_names), MEMORY_STICKY_PREVIEW_LIMIT]
                     end
      status_memory_text(names, limit)
    end

    def thinking_memory_notification_suffix
      memory_name = @thinking_recent_memory_loaded.to_s.strip
      return "" if memory_name.empty?

      " memory_loaded: #{memory_name}"
    end

    def thinking_tool_notification_suffix
      tool_call = @thinking_recent_tool_call.to_s.strip
      return "" if tool_call.empty?

      " last_tool: #{tool_call}"
    end

    def thinking_notification_segments(width)
      return ["", ""] if width <= 0

      memory_suffix = cap_preview_text(thinking_memory_notification_suffix, width)
      remaining = [width - memory_suffix.length, 0].max
      tool_suffix = cap_preview_text(thinking_tool_notification_suffix, remaining)
      [memory_suffix, tool_suffix]
    end

    def paint_if_present(text, code)
      return "" if text.to_s.empty?

      paint(text, code)
    end

    def thinking_spinner_enabled?
      return false unless $stdout.tty?

      mode = ENV.fetch(THINKING_UI_ENV, THINKING_UI_SPINNER).to_s.strip.downcase
      return false if mode.empty? || mode == THINKING_UI_OFF || mode == "false" || mode == "0"

      mode == THINKING_UI_SPINNER && ENV.fetch("TERM", "") != "dumb"
    end

    def set_retry_spinner_status(event)
      @retry_spinner_status = {
        attempt: event[:attempt],
        max_retries: event[:max_retries],
        next_delay: event[:next_delay],
        error_class: event[:error_class]
      }
    end

    def clear_retry_spinner_status
      @retry_spinner_status = nil
    end

    def retry_spinner_status_active?
      @retry_spinner_status.is_a?(Hash)
    end

    # Reset the Engine's shared inactivity clock when a prompt opens (a
    # Reline.pre_input_hook) and on each key typed (RelineSeam.key_handler). This is the
    # single seam the Engine-owned idle recap detector reads, so the idle clock
    # is identical for the REPL and any other Engine-backed UI. Chains onto any
    # previously-installed hook (e.g. the input prefill hook).
    def with_activity_hook
      previous_hook = Reline.pre_input_hook
      previous_key_handler = RelineSeam.key_handler
      Reline.pre_input_hook = proc do
        @engine.record_activity
        previous_hook.call if previous_hook
      end
      # Typing is activity too: a reminder waits while you type.
      RelineSeam.key_handler = -> { @engine.record_activity }
      yield
    ensure
      Reline.pre_input_hook = previous_hook
      RelineSeam.key_handler = previous_key_handler
    end

    def render_thinking_spinner
      frame = THINKING_SPINNER_FRAMES[@thinking_spinner_index % THINKING_SPINNER_FRAMES.length]
      width = status_effective_width
      spinner_lines = thinking_spinner_status_lines(frame, width: width)
      preview_lines, preview_has_content = turn_preamble_enabled? ? [[], false] : thinking_tail_preview_lines(width: width)
      if color_output?
        preview_lines = preview_lines.map { |text| paint(text, 90) }
      end
      # The spinner and preview go above the prompt, the status rows below it.
      @surface.set_slots(activity: spinner_lines + preview_lines, status: spinner_status_lines(width: width))
      @thinking_spinner_last_render_at = monotonic_time
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = preview_has_content
    end

    def thinking_spinner_status_line(frame)
      lines = thinking_spinner_status_lines(frame)
      lines.empty? ? "" : lines.first
    end

    def thinking_spinner_status_lines(frame, width: status_effective_width)
      if retry_spinner_status_active?
        return [retry_spinner_status_line(frame, width)]
      end

      preamble_active = turn_preamble_status_base(frame)
      base = preamble_active || "model> thinking... #{frame}"
      available_for_notification = [width - base.length, 0].max
      memory_notification, tool_notification = thinking_notification_segments(available_for_notification)
      notification = "#{memory_notification}#{tool_notification}"

      return ["#{base}#{notification}"] unless color_output?

      base_color = preamble_active ? TURN_PREAMBLE_SPINNER_COLOR : 90
      ["#{paint(base, base_color)}#{paint_if_present(memory_notification, MEMORY_SPINNER_COLOR)}#{paint_if_present(tool_notification, TOOL_SPINNER_COLOR)}"]
    end

    # ── Ask-user-question adapter (generic TUI renderer) ─────────────────────

    # Non-blocking observer: the turn thread emits :question_requested; we stash
    # it so the REPL thread (the only one that may touch Reline) can drain it
    # at the top of run_assist_loop without racing the completion.
    def handle_question_event(event)
      return unless event.is_a?(Hash)

      type = event[:type] || event["type"]
      return unless type.to_s == "question_requested"

      pq = event[:pending_question] || event["pending_question"] || event[:pendingQuestion]
      return unless pq

      @pending_question_event = pq
    rescue StandardError
      nil
    end

    def pending_question_event?
      !!@pending_question_event
    end

    # Called from REPL thread (run_assist_loop top) — renders widget, blocks
    # until user selects, then answers via Engine#answer_question which wakes
    # the parked turn thread.
    def drain_pending_question?
      pq = @pending_question_event
      # Also check Engine's persisted pending (covers resume)
      pq ||= @engine.pending_question
      return false unless pq

      # If the pending no longer matches the engine's current pending (stale
      # event after sync handler already answered and cleared), discard.
      current = @engine.pending_question
      if current && (pq[:id] || pq["id"]).to_s != (current[:id] || current["id"]).to_s
        @pending_question_event = nil
        return false
      end
      if current.nil? && @pending_question_event
        # Stale stash where engine already cleared (sync path completed)
        @pending_question_event = nil
        return false
      end

      @pending_question_event = nil
      result = render_question_widget(pq)
      return false unless result

      # result is already answered via Engine#answer_question in render_question_widget
      true
    rescue StandardError => e
      warn "[ask_user_question] drain failed: #{e.class}: #{e.message}"
      false
    end

    def render_question_widget(pending)
      prompt = QuestionPrompt.new(pending)

      # Ensure spinner cleared and terminal in known state (same as reminder mute handling)
      finish_thinking_spinner rescue nil

      # The question is output, not the notes slot: on a live region the slot
      # would vanish when cleared, and the question must stay above its answer.
      # A reminder turn asks with the prompt open: Reline reads one line at a
      # time, so the next line submitted there is the answer.
      at_prompt = @prompt_reader&.alive?
      rows = prompt.lines(paint: method(:paint), color: color_output?)
      rows.unshift("") if $stdout.tty?
      rows << "  Enter empty to cancel." if !prompt.free? # still allow cancel
      rows << "  Answer at the prompt." if at_prompt
      @surface.commit(rows.join("\n"))

      # Loop until valid selection or cancel
      loop do
        choice_prompt = color_output? ? paint("choice> ", 33) : "choice> "
        raw = nil
        begin
          if at_prompt
            at_prompt = false # a retry after an invalid answer reads choice>
            raw = take_open_prompt_line
            if raw == :canceled
              @engine.cancel_question("user") rescue nil
              return false
            end
          # Use plain Reline.readline when tty, else $stdin.gets for non-tty/specs
          elsif $stdin.tty? && $stdout.tty?
            raw = Reline.readline(choice_prompt, true)
          else
            @surface.set_slot(:editor, [choice_prompt])
            raw = $stdin.gets
          end
        rescue Interrupt
          raw = nil
        end
        if raw.nil?
          # EOF / Ctrl-D -> cancel
          @engine.cancel_question("user") rescue nil
          return false
        end
        raw = raw.to_s.strip
        if raw.empty?
          @engine.cancel_question("user") rescue nil
          @surface.commit("(cancelled)") if $stdout.tty?
          return false
        end

        answer = prompt.parse(raw)
        @surface.commit(answer.note) if answer.note
        unless answer.ok?
          @surface.commit(answer.error)
          next
        end

        begin
          @engine.answer_question(id: prompt.id, selected: answer.selected, freeform: answer.freeform)
          return true
        rescue ArgumentError => e
          @surface.commit("Invalid: #{e.message}. Try again.")
          next
        rescue StandardError => e
          @surface.commit("Error: #{e.message}")
          return false
        end
      end
    end

    # The line submitted at the open prompt, or :canceled when the running
    # turn is cancelled first (Ctrl-C there); the prompt then stays open.
    def take_open_prompt_line
      controller = @active_cancel_controller
      until @prompt_reader.join(REMINDER_PENDING_POLL_INTERVAL)
        return :canceled if controller&.cancelled?
      end
      reader = @prompt_reader
      @prompt_reader = nil
      reader.value
    end

    # Process a prompt through the kernel loop and return the model response.
    # Delegates to the internal Engine instance.
    def process_prompt_through_kernel(session, prompt)
      @engine.process_prompt_through_kernel(session, prompt)
    end

    # Write an agent response to the session output directory.
    def write_session_output(output_dir, response)
      timestamp = Time.now.strftime("%Y%m%d%H%M%S%9N")
      File.write(File.join(output_dir, "#{timestamp}.txt"), response.to_s)
    end
  end
end
