# frozen_string_literal: true

require "json"
require "fileutils"
require "io/console"
require "reline"
require "set"

require_relative "model_profile"
require_relative "config"
require_relative "host_registry"
require_relative "context_usage"
require_relative "kernel_loop"
require_relative "session"
require_relative "engine"
require_relative "tools/memory"
require_relative "output_formatter"
require_relative "turn_preamble"
require_relative "terminal_ui/event_renderer"

module Samagotchi
  # TerminalUI encapsulates the single operating mode of the harness.
  #
  # assist mode  — interactive REPL: user types, model responds, tools execute inline.
  class TerminalUI
    AGENT_DESCRIPTION_FILE = "AGENT.md"
    PROMPT_HISTORY_ENV = "SAMAGOTCHI_HISTORY_FILE"
    XDG_STATE_HOME_ENV = "XDG_STATE_HOME"
    PROMPT_HISTORY_FILE = "history.json"
    PROMPT_HISTORY_STATE_DIR = "samagotchi"
    PROMPT_HISTORY_LIMIT = 20
    DEFAULT_INPUT_ENV = "SAMAGOTCHI_DEFAULT_INPUT"
    SKIP_AGENT_DESCRIPTION_ENV = "SAMAGOTCHI_SKIP_AGENT_MD"
    CONTINUE_COMMAND = "/continue"
    MODEL_COMMAND = "/model"
    MODELS_COMMAND = "/models"
    STATS_COMMAND = "/stats"
    RECAP_COMMAND = "/recap"
    ROLLBACK_COMMAND = "!rollback"
    SLASH_COMMANDS = %w[/continue /exit /model /models /recap /stats].freeze
    SHELL_BANG_PREFIX = "!"
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
    INTERRUPTED_SUMMARY_PROMPT_LIMIT = 600
    INTERRUPTED_SUMMARY_MODEL_LIMIT = 360
    INTERRUPTED_SUMMARY_PARAMS_LIMIT = 80
    INTERRUPTED_SUMMARY_TOOLS_LIMIT = 5
    AT_PATH_COMPLETION_PREFIX = "@"
    MEMORY_COMPLETION_PREFIX = "#"
    AT_PATH_COMPLETION_MAX_CANDIDATES = 200
    CANCEL_MONITOR_POLL_INTERVAL = 0.05
    CTRL_C_BYTE = "\u0003"
    REMINDER_TYPING_PAUSE_SECONDS = 2.0
    REMINDER_PENDING_POLL_INTERVAL = 0.5

    # ── System prompts (delegated to Engine) ─────────────────────────────────
    def self.system_prompt_for(profile)
      Engine.system_prompt_for(profile)
    end

    def initialize(mode: :assist, prompt: nil, client: nil, host_registry: nil, verbose: false, log_file: nil, profile: nil, session_id: nil, no_interrupt: false, no_default_input: false, model_name: nil, memories: [], non_interactive: false, backend: nil)
      @mode           = mode.to_sym
      @prompt         = prompt
      @default_model_name = ModelProfile.required_model_name(nil)
      aliased_model_name = model_name.to_s.strip.empty? ? nil : ConfigFile.resolve_model_alias(model_name)
      flag_model_name = aliased_model_name.to_s.strip.empty? ? nil : ModelProfile.required_model_name(aliased_model_name)
      @effective_model_name = flag_model_name || @default_model_name
      @host_registry  = host_registry || Samagotchi::HostRegistry.new
      # Client is now registry-aware: resolve active host for effective model
      if client
        @client = client
        # Ensure registry's default entry points to injected client so routing respects stub
        if @host_registry.entries["default"]
          @host_registry.entries["default"].client = client
        end
      else
        _cli, _bare, _entry = @host_registry.client_for_model(@effective_model_name)
        @client = _cli
      end
      @resume_session = session_id ? Session.load(session_id) : nil
      if @resume_session
        # --model overrides resumed session's model (runtime only, default unchanged)
        if flag_model_name
          @effective_model_name = flag_model_name
        else
          @effective_model_name = @resume_session.model_name.to_s.strip.empty? ? @default_model_name : @resume_session.model_name
        end
        # Re-resolve client after resume may change effective model
        unless client
          _cli2, _bare2, _entry2 = @host_registry.client_for_model(@effective_model_name)
          @client = _cli2
        end
      end
      @profile        = profile ? ModelProfile.normalize(profile) : ModelProfile.from_model_name(bare_model_for(@effective_model_name))
      @kernel         = KernelLoop.new(client: @client, verbose: verbose, log_file: log_file, profile: @profile, no_interrupt: no_interrupt, reminder_store: Samagotchi::ReminderStore.new)
      @no_default_input = no_default_input
      @non_interactive = non_interactive
      # Toggled by begin/end_interactive_turn so an interrupted-and-continued
      # turn isn't counted as multiple turns.
      @turn_open = false
      @requested_memories = Array(memories)
      @last_recap = nil
      @last_recap_generation = nil
      @pending_reminder_results = []
      @pending_reminder_mutex = Monitor.new
      @muted_reminder_thread = nil
      @pending_reminder_banner_shown = false
      @last_keystroke_at = monotonic_time
      @last_line_buffer = ""
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
        backend: backend,
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
        $stdout.puts result.output
        session.save
        return
      end

      assist_loop(session: session, messages: messages)
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
        $stdout.puts "Resumed session: #{session.id}"
      else
        messages = [system_message]
        $stdout.puts "Session: #{session.id}"
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
      # installs a Reline.pre_input_hook that resets the shared inactivity
      # clock on the first keystroke.
      @engine.start_idle
      with_activity_hook do
        run_assist_loop(session: session, messages: messages)
      ensure
        @engine.stop_idle
      end
    end

    # Interactive REPL loop. Session seed + messages are built by #run and
    # threaded in here (so --prompt / --resume share one code path). The
    # session's conversation is the single working copy: turns go through
    # Engine#run_turn and out-of-turn edits through Engine's messages API.
    # The session is persisted at the end of every turn.
    def run_assist_loop(session:, messages:)
      session.messages = messages
      @engine.session = session
      awaiting_continue = false
      interrupted_turn_checkpoint = nil
      interrupted_turn_context = nil
      # UI-agnostic steering queue. Nothing pushes mid-turn in the TUI yet
      # (typed-during-generation input is intentionally out of scope — the tty
      # render stack is too fragile), but wiring the drain here keeps the
      # interface live and identical to the web/background hosts.
      @pending_input_queue = PendingInputQueue.new

      loop do
        # Drain any pending ask_user_question first — it has priority over reminders and
        # must be rendered on the REPL thread (turn thread is parked on Engine Monitor).
        drain_pending_question?

        # Drain any completed muted reminder turns before handling new
        # synthetic idle turns. This is the send+mute path: generation
        # happened in background while the user was typing, we only
        # render after a 2s pause or after submit. Draining here covers
        # the after-submit case (poll returned) and the case where a
        # background turn finished while we were busy.
        if drain_pending_muted_results?(session)
          # pending drain already emitted/saved and updated the session; a
          # !rollback now would drop that reminder turn too
          interrupted_turn_checkpoint = nil unless awaiting_continue
          next if pending_reminder_results_pending?
          # continue to handle normal input below after draining
        end

        # Check if there are due reminders from the background thread.
        # Idle synthetic turn — only when prompt is empty / truly idle.
        # If a muted background turn is already running, skip sync synthetic
        # and let the muted path finish; its result will be drained above.
        unless muted_reminder_running?
          due_names = @engine.due_reminder_names
          unless due_names.empty?
            # If user is actively typing (line buffer non-empty) we defer
            # to send+mute instead of interrupting. The poll loop will
            # have started the muted thread; here we only run sync when
            # not typing. Check via Reline where possible, fallback to
            # immediate sync for non-TTY / empty buffer.
            if typing_active?
              # Defer — ensure muted thread is started with current snapshot
              start_muted_reminder_generation(session) unless muted_reminder_pending? || muted_reminder_running?
              # Don't consume latch yet — muted thread will consume via collect_due_reminders
              # Just notify once
              notify_pending_reminder_banner(due_names) unless @pending_reminder_banner_shown
              # fall through to poll (don't run sync now)
            else
              @engine.clear_due_reminder_names!
              # If the store was already drained by a normal-turn injection
              # (stale latch), skip the empty synthetic to avoid duplicate
              # generation (user observed 2 identical time outputs).
              next unless @engine.reminders_due?

              result = nil
              begin
                # run_turn injects the due reminders as a tail message.
                result = run_engine_turn(session, nil, continue: true)
                # Clear any pending prompt so we don't re-run
                @prompt = nil
              rescue Client::RetryExhausted
                # Treat retry exhaustion the same as other errors — continue loop
              end
              emit_interactive_turn_duration(canceled: false)
              interrupted_turn_checkpoint = nil unless awaiting_continue
              # Persist the synthetic turn, then loop to check for more.
              if result && !(result.respond_to?(:canceled?) && result.canceled?)
                session.messages = result.conversation if result.respond_to?(:conversation) && result.conversation.is_a?(Array)
                session.model_name = @effective_model_name
                session.save
              end
              # Synthetic turn is activity for the idle detector — reset the
              # inactivity clock so the next reminder waits a full interval
              # instead of firing immediately (observed rapid "Current time is"
              # -> "" -> empty).
              @engine.record_activity
              @pending_reminder_banner_shown = false
              next
            end
          end
        end
        input = @prompt
        @prompt = nil if input
        if input.nil?
          input = poll_input_with_reminder_check(awaiting_continue: awaiting_continue, session: session)
          # poll returns :due if a reminder became due while idle+empty;
          # loop again to run the synthetic turn at the top.
          if input == :due
            next
          end
          # poll returns :pending_due when a muted result was ready and
          # typing paused 2s — we preserved the buffer via prefill, drain
          # will happen at top of next loop; just continue.
          if input == :pending_ready
            next
          end
          # After poll returns a real user line, drain any muted that
          # finished while typing before handling the user turn — so order
          # is [history, tail SYSTEM DUE, model reply, user next] without
          # clobbering the just-typed line.
          if drain_pending_muted_results?(session)
            # The session was updated; the user's input is still in
            # `input` and will be processed next. Don't discard it.
            interrupted_turn_checkpoint = nil unless awaiting_continue
          end
        end
        break if input.nil?
        break if exit_command?(input)
        continue_flow = awaiting_continue

        if awaiting_continue
          decision, reason = continue_decision(input)

          case decision
          when :resume
            # A cancelled continue leaves the conversation as it was before it.
            continue_checkpoint = @engine.messages_checkpoint
            begin
              result = run_engine_turn(session, nil, continue: true)
            rescue Client::RetryExhausted => e
              $stdout.puts "\nmodel> network error after #{e.attempts} attempts; continue prompt preserved"
              awaiting_continue = true
              interrupted_turn_checkpoint = nil unless awaiting_continue
              next
            end
          when :abort
            @engine.rollback_to(interrupted_turn_checkpoint) if interrupted_turn_checkpoint
            interrupted_turn_checkpoint = nil
            interrupted_turn_context = nil
            awaiting_continue = false
            session.model_name = @effective_model_name
            session.save
            $stdout.puts "\nmodel> interrupted turn cancelled; enter your next prompt"
            next
          when :abort_with_reason
            @engine.rollback_to(interrupted_turn_checkpoint) if interrupted_turn_checkpoint
            interrupted_turn_checkpoint = nil
            @engine.append_messages([{
              role: "user",
              content: interrupted_turn_reason_message(reason: reason, context: interrupted_turn_context)
            }])
            interrupted_turn_context = nil
            awaiting_continue = false
            session.model_name = @effective_model_name
            session.save
            $stdout.puts "\nmodel> interrupted turn cancelled; noted your explanation"
            next
          else
            $stdout.puts "\nmodel> answer yes, no, or no, <reason>"
            next
          end
        else
          next if input.empty?

          # Explicit escape hatch after a Ctrl-C: discard the salvaged
          # partial turn and restore the pre-turn checkpoint.
          if input.strip == ROLLBACK_COMMAND
            if interrupted_turn_checkpoint
              @engine.rollback_to(interrupted_turn_checkpoint)
              interrupted_turn_checkpoint = nil
              session.model_name = @effective_model_name
              session.save
              $stdout.puts "\nmodel> salvaged turn discarded; restored pre-turn state"
            else
              $stdout.puts "\nmodel> nothing to rollback"
            end
            next
          end

          if shell_bang_command?(input)
            command = input.delete_prefix(SHELL_BANG_PREFIX).strip
            if command.empty?
              $stdout.puts "\nmodel> !: please provide a shell command after '!'"
              next
            end
            output = Samagotchi::Tools::Execute.call(command)
            $stdout.puts output
            $stdout.puts
            @engine.append_messages([{ role: "user", content: "!(#{command})\n#{output}" }])
            # Rolling back past this would silently drop the command output.
            interrupted_turn_checkpoint = nil
            persist_recent_history(input)
            next
          end

          if continue_request?(input)
            $stdout.puts "\nmodel> nothing to continue"
            next
          end

          if models_command?(input)
            $stdout.puts "\nmodel> #{handle_models_command}"
            next
          end

          if model_command?(input)
            $stdout.puts "\nmodel> #{handle_model_command(input)}"
            next
          end

          if stats_command?(input)
            $stdout.puts "\nmodel> session stats:\n#{format_session_metrics(@engine.metrics.snapshot)}"
            next
          end

          if recap_command?(input)
            $stdout.puts "\nmodel> #{handle_recap_command}"
            next
          end

          interrupted_turn_checkpoint = @engine.messages_checkpoint
          persist_recent_history(input)
          begin
            # Engine#run_turn injects due reminders as a tail message, appends
            # the prompt, and renders through @renderer via on_event.
            result = run_engine_turn(session, normalize_model_input(input))
          rescue Client::RetryExhausted => e
            # Engine closed the turn (:turn_failed); show its duration.
            # Retries were already tallied via generation_retrying events.
            emit_interactive_turn_duration(canceled: false)
            @engine.rollback_to(interrupted_turn_checkpoint) if interrupted_turn_checkpoint
            awaiting_continue = false
            queue_input_prefill(input)
            $stdout.puts "\nmodel> network error after #{e.attempts} attempts; prompt restored for retry"
            interrupted_turn_checkpoint = nil unless awaiting_continue
            next
          end
        end

        if result.respond_to?(:canceled?) && result.canceled?
          if continue_flow
            @engine.rollback_to(continue_checkpoint)
            awaiting_continue = true
          else
            # Ctrl-C on a fresh turn. The kernel salvaged completed tool calls
            # and the partial assistant reply (marked [interrupted]) into
            # result.conversation, so progress is preserved by default — the
            # user's next message continues from it. !rollback restores the
            # pre-turn checkpoint for an explicit full discard.
            emit_interactive_turn_duration(canceled: true)
            if result.respond_to?(:conversation) && result.conversation.is_a?(Array)
              session.model_name = @effective_model_name
              session.save
            else
              @engine.rollback_to(interrupted_turn_checkpoint) if interrupted_turn_checkpoint
            end
            awaiting_continue = false
            # Keep interrupted_turn_checkpoint: it is what !rollback restores,
            # until the next turn or another change to the conversation.
            $stdout.puts "\nmodel> turn cancelled; partial progress kept in context; use !rollback immediately after cancellation to restore the pre-turn checkpoint"
          end
          next
        end

        # The REPL keeps the kernel's conversation as-is (no [No response]
        # placeholder), so /continue resumes from the tool results.
        session.messages = result.conversation
        awaiting_continue = result.resumable?
        interrupted_turn_context = if awaiting_continue
                                     build_interrupted_turn_context(
                                       result: result,
                                       checkpoint: interrupted_turn_checkpoint,
                                       conversation: session.messages
                                     )
                                   else
                                     nil
                                   end
        interrupted_turn_checkpoint = nil unless awaiting_continue

        session.model_name = @effective_model_name
        session.save
      end

      $stdout.puts "\nContinue session: chi --resume #{session.id}"
    end

    def status_server_segment
      # Show per-host info when multi-host is configured
      if @host_registry && @host_registry.entries.size > 1
        active = @host_registry.host_for_model(@effective_model_name)[0] rescue nil
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
      lines = sticky_status_lines
      return if lines.empty?

      lines.each { |line| $stdout.puts line }
    end

    def print_line(text)
      $stdout.puts text
    end

    def reset_turn_feedback
      clear_retry_spinner_status
      reset_thinking_memory_notification
      reset_thinking_memory_names
      reset_thinking_tool_notification
    end

    def generation_feedback_started
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

    def format_tool_activity_line(activity, duration_ms: nil)
      params = activity[:params].to_s.strip
      params_suffix = params.empty? ? "" : " #{paint(params, 90)}"
      status = activity[:status].to_s
      status_color = status == "ok" ? 32 : 31
      elapsed_suffix = duration_ms.nil? ? "" : " (#{format_elapsed_duration(duration_ms)})"
      "#{paint('tool>', 36)} #{activity[:action]} (#{activity[:tool]}#{params_suffix}): #{paint(status, status_color)}#{elapsed_suffix}"
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
      $stdout.puts "#{paint('chi>', 36)} turn #{state} (#{format_elapsed_duration(record[:duration_ms])})"
    end

    def format_elapsed_duration(duration_ms)
      duration_ms = duration_ms.to_f
      return "" if duration_ms.negative?
      return "#{duration_ms.round}ms" if duration_ms < 500

      seconds = duration_ms / 1000
      return "#{seconds.round(1)}s" if seconds < 10
      return "#{seconds.round}s" if seconds < 60

      total_seconds = seconds.round
      "#{total_seconds / 60}m #{format('%02d', total_seconds % 60)}s"
    end

    def paint(text, code)
      return text unless color_output?

      "\e[#{code}m#{text}\e[0m"
    end

    def color_output?
      return false unless $stdout.tty?
      return false if ENV.key?("NO_COLOR")

      ENV.fetch("TERM", "") != "dumb"
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

      # In multiline mode Enter submits, while Meta+Enter/Alt+Enter inserts a
      # newline on terminals that emit that distinct sequence (for example kitty).
      input = with_scoped_at_path_completion do
        with_next_input_prefill do
          Reline.readmultiline(paint("> ", 92), true) { true }
        end
      end
      return nil if input.nil?

      input.gsub(/\r\n?|\n\z/, "\n").strip
    rescue Interrupt
      nil
    end

    # ── Send+mute helpers ──────────────────────────────────────────────────

    def typing_active?
      buf = begin
        Reline.line_buffer.to_s
      rescue StandardError
        ""
      end
      !buf.strip.empty?
    end

    def muted_reminder_running?
      @muted_reminder_thread && @muted_reminder_thread.alive?
    end

    def muted_reminder_pending?
      @pending_reminder_mutex.synchronize { !@pending_reminder_results.empty? }
    end

    def pending_reminder_results_pending?
      muted_reminder_pending?
    end

    def notify_pending_reminder_banner(due_names)
      return if due_names.nil? || due_names.empty?
      # No inline stdout write while Reline is active — that clobbers the
      # current input line (user observed "[reminder pending: ...]" inserted
      # mid-typing). Just set the flag; the muted result will be rendered
      # after 2s pause or submit. A future status-line integration can show
      # a non-intrusive indicator without touching Reline's buffer.
      @pending_reminder_banner_shown = true
    rescue StandardError
      nil
    end

    def start_muted_reminder_generation(session)
      return if muted_reminder_running?
      return if muted_reminder_pending? # already have a pending to drain
      return if @engine.due_reminder_names.empty?

      # Snapshot the current messages; muted thread injects and runs on the
      # copy so the session's conversation is untouched until drain.
      snapshot = clone_messages(session.messages)
      @muted_reminder_thread = Thread.new do
        Thread.current.report_on_exception = false
        @engine.set_turn_running(true)
        begin
          begin_interactive_turn(session)
          # Inject due reminders into the snapshot; this marks them fired
          # atomically in ReminderStore and clears IdleReminders latch.
          # We duplicate snapshot handling inside the thread so the
          # foreground latch isn't cleared prematurely on failure.
          injected = @engine.collect_due_reminders(snapshot)
          if injected.empty?
            # Stale latch — clear and exit quietly
            @pending_reminder_mutex.synchronize { @pending_reminder_banner_shown = false }
          else
            result = run_kernel_muted(snapshot)
            @pending_reminder_mutex.synchronize do
              @pending_reminder_results << result
            end
          end
        rescue StandardError => e
          warn "[reminder muted] generation failed: #{e.class}: #{e.message}"
        ensure
          begin
            end_interactive_turn(canceled: false, announce: false)
          rescue StandardError
            nil
          end
          @engine.set_turn_running(false)
          # Clear the banner flag so next due can notify again after drain
        end
      end
    end

    def run_kernel_muted(messages, max_iterations: 100)
      # Muted background turn on a snapshot: no spinner, no tool-activity
      # streaming to stdout, and not through Engine#run_turn (it must not
      # overwrite the session from this thread). Still forwards to
      # Engine.metrics so /stats stays correct.
      cancellation_controller = Client::CancellationController.new
      @active_cancel_controller = cancellation_controller
      muted_handler = proc do |event|
        begin
          @engine.metrics.call(event)
        rescue StandardError
          nil
        end
        # intentionally suppress spinner/tool rendering
      end
      result = run_selected_backend(
        messages,
        max_iterations: max_iterations,
        on_stream_event: muted_handler,
        cancel_controller: cancellation_controller
      )
      result
    rescue Interrupt
      cancellation_controller&.cancel!(:ctrl_c)
      cancelled_result_from(messages, reason: :ctrl_c)
    ensure
      @active_cancel_controller = nil
      finish_thinking_spinner
    end

    def drain_pending_muted_results?(session)
      pending = nil
      @pending_reminder_mutex.synchronize do
        pending = @pending_reminder_results.dup
        @pending_reminder_results.clear if pending.any?
      end
      return false if pending.empty?

      pending.each do |result|
        next if result.nil?
        if result.respond_to?(:canceled?) && result.canceled?
          next
        end
        # result.conversation already contains the injected SYSTEM DUE +
        # model reply. Replace the session's conversation with it.
        if result.respond_to?(:conversation) && result.conversation.is_a?(Array)
          session.messages = Array(result.conversation).map(&:dup)
        end
        emit_result(result)
        session.model_name = @effective_model_name
        session.save
        @engine.metrics.persist
        @engine.record_activity
      end
      @pending_reminder_banner_shown = false
      true
    end

    # Poll for input while also checking for due reminders. We must show
    # the prompt/prefill immediately (via Reline) *and* poll for due.
    # Send+mute: while the user is typing we never kill Reline. Instead we
    # start a muted background generation on the first due tick, show a
    # lightweight banner, and either (a) render after a 2s typing pause
    # (kill+prefill to show pending without losing keystrokes) or (b) after
    # submit at the top of the next loop. When prompt is empty / truly idle
    # we still return :due for the synchronous synthetic path.
    def poll_input_with_reminder_check(awaiting_continue:, session: nil)
      # Check due before any blocking so push-mode fires even in specs/non-TTY.
      return :due unless @engine.due_reminder_names.empty?

      # Non-TTY (specs, pipes) — just block directly; no push needed there.
      unless STDIN.tty? && $stdin.tty?
        return read_input(awaiting_continue: awaiting_continue)
      end

      # TTY: show prompt immediately but still poll for due in background.
      result = nil
      reader = Thread.new do
        Thread.current.report_on_exception = false
        result = read_input(awaiting_continue: awaiting_continue)
      end

      @last_line_buffer = ""
      @last_keystroke_at = monotonic_time
      loop do
        # Reader finished (user submitted or Ctrl-D) — return their input.
        unless reader.alive?
          reader.join
          return result
        end

        # Track typing activity for 2s pause detection (on top of
        # Engine's pre_input_hook which only fires on first keystroke).
        begin
          current_buf = Reline.line_buffer.to_s
        rescue StandardError
          current_buf = ""
        end
        if current_buf != @last_line_buffer
          grew = current_buf.strip.length > @last_line_buffer.strip.length
          @last_line_buffer = current_buf
          @last_keystroke_at = monotonic_time
          @engine.record_activity if grew
        end

        due = @engine.due_reminder_names
        unless due.empty?
          if typing_active?
            # Send+mute: generate in background, don't interrupt typing
            if session && !muted_reminder_running? && !muted_reminder_pending?
              start_muted_reminder_generation(session)
            elsif session.nil?
              # Fallback when poll was called without snapshot (e.g. /continue)
              # still notify, drain will happen after submit via top-of-loop
            end
            notify_pending_reminder_banner(due) unless @pending_reminder_banner_shown
          else
            # Truly idle with empty prompt — keep synchronous synthetic path
            begin
              reader.raise(Interrupt)
            rescue StandardError
              nil
            end
            reader.join(0.3)
            if reader.alive?
              reader.kill
              reader.join(0.3)
            end
            begin
              STDIN.cooked! if STDIN.respond_to?(:cooked!) && STDIN.tty?
            rescue StandardError
              nil
            end
            begin
              $stdout.puts if $stdout.tty?
            rescue StandardError
              nil
            end
            return :due
          end
        end

        # If a muted generation finished while typing and user has paused
        # 2s, render now without losing the current buffer (preserve via
        # prefill and kill reader so top-of-loop can drain). Clear the
        # current input line first to avoid the duplicated-line artifact
        # user observed (original typing left on screen + new prefilled
        # prompt showing same text).
        if muted_reminder_pending? && !muted_reminder_running?
          if (monotonic_time - @last_keystroke_at) >= REMINDER_TYPING_PAUSE_SECONDS
            saved = begin
              Reline.line_buffer.to_s
            rescue StandardError
              ""
            end
            # Preserve typed buffer across the interrupt
            queue_input_prefill(saved) unless saved.strip.empty?
            # Clear the in-progress Reline line before interrupting so the
            # next prompt's prefill is the only visible copy (avoids the
            # "line is copied" duplication).
            begin
              $stdout.print("\r\e[2K") if $stdout.tty?
              $stdout.flush if $stdout.tty?
            rescue StandardError
              nil
            end
            begin
              reader.raise(Interrupt)
            rescue StandardError
              nil
            end
            reader.join(0.3)
            if reader.alive?
              reader.kill
              reader.join(0.3)
            end
            begin
              STDIN.cooked! if STDIN.respond_to?(:cooked!) && STDIN.tty?
            rescue StandardError
              nil
            end
            # No extra puts — drain will emit the reminder output next
            return :pending_ready
          end
        end

        sleep REMINDER_PENDING_POLL_INTERVAL
      end
    end

    def with_scoped_at_path_completion
      previous_completion_proc = Reline.completion_proc
      previous_autocompletion = Reline.autocompletion
      Reline.autocompletion = true
      Reline.completion_proc = method(:assist_path_completion_candidates).to_proc
      yield
    ensure
      Reline.completion_proc = previous_completion_proc
      Reline.autocompletion = previous_autocompletion
    end

    def assist_path_completion_candidates(word)
      token = word.to_s
      return [] if token.empty?

      if token.start_with?("/")
        return build_slash_completion_candidates(token)
      end

      if token.start_with?(AT_PATH_COMPLETION_PREFIX)
        path_fragment = token.delete_prefix(AT_PATH_COMPLETION_PREFIX)
        return build_project_path_completion_candidates(path_fragment)
      end

      if token.start_with?(MEMORY_COMPLETION_PREFIX)
        memory_fragment = token.delete_prefix(MEMORY_COMPLETION_PREFIX)
        return build_memory_completion_candidates(memory_fragment)
      end

      []
    end

    def build_slash_completion_candidates(slash_fragment)
      fragment = slash_fragment.to_s.strip
      return [] unless fragment.start_with?("/")

      begin
        buf = Reline.line_buffer.to_s
        unless buf.empty?
          return [] unless buf.lstrip.start_with?("/")
        end
      rescue StandardError
        nil
      end

      lowered = fragment.downcase
      return SLASH_COMMANDS.dup if lowered == "/"

      SLASH_COMMANDS.select { |cmd| cmd.start_with?(lowered) }
    rescue StandardError
      []
    end

    def build_project_path_completion_candidates(path_fragment)
      fragment = path_fragment.to_s.tr("\\", "/")
      return [] if fragment.start_with?("/")
      return [] if fragment.split("/").include?("..")

      dir_part = ""
      entry_prefix = fragment

      if fragment.include?("/")
        dir_part = fragment.sub(%r{[^/]*\z}, "")
        entry_prefix = fragment.split("/").last.to_s
      end

      base_dir = dir_part.empty? ? Dir.pwd : File.expand_path(dir_part, Dir.pwd)
      return [] unless path_within_cwd?(base_dir)
      return [] unless File.directory?(base_dir)

      entries = Dir.children(base_dir).sort
      entries.reject! { |entry| entry.start_with?(".") } unless entry_prefix.start_with?(".")
      matches = entries.select { |entry| entry.start_with?(entry_prefix) }

      matches.first(AT_PATH_COMPLETION_MAX_CANDIDATES).map do |entry|
        relative_path = "#{dir_part}#{entry}".tr("\\", "/")
        absolute_path = File.join(base_dir, entry)
        relative_path = "#{relative_path}/" if File.directory?(absolute_path)
        "#{AT_PATH_COMPLETION_PREFIX}#{relative_path}"
      end
    rescue StandardError
      []
    end

    def path_within_cwd?(path)
      expanded = File.expand_path(path)
      cwd = Dir.pwd
      expanded == cwd || expanded.start_with?("#{cwd}#{File::SEPARATOR}")
    end

    def build_memory_completion_candidates(memory_fragment)
      fragment = memory_fragment.to_s.strip.tr("\\", "/")
      candidates = memory_completion_entries
      return candidates.map { |entry| entry[:token] } if fragment.empty?

      candidates.filter_map do |entry|
        entry[:token] if entry[:token].delete_prefix(MEMORY_COMPLETION_PREFIX).start_with?(fragment)
      end
    end

    def memory_completion_entries
      grouped = Hash.new { |hash, key| hash[key] = [] }

      each_memory_completion_entry do |scope, name|
        grouped[name] << scope unless grouped[name].include?(scope)
      end

      grouped.sort_by do |name, scopes|
        [memory_scope_sort_key(scopes.min_by { |scope| memory_scope_sort_key(scope) }), name]
      end.flat_map do |name, scopes|
        scopes = scopes.sort_by { |scope| [memory_scope_sort_key(scope), scope] }
        if scopes.length == 1
          [{ token: "#{MEMORY_COMPLETION_PREFIX}#{name}", scope: scopes.first, name: name }]
        else
          scopes.map do |scope|
            { token: "#{MEMORY_COMPLETION_PREFIX}#{scope}/#{name}", scope: scope, name: name }
          end
        end
      end
    end

    def memory_scope_sort_key(scope)
      scope == "project" ? 0 : 1
    end

    def each_memory_completion_entry
      memory_completion_dirs.each do |scope, dir|
        next unless File.directory?(dir)

        Dir.glob(File.join(dir, "*.md")).sort.each do |path|
          name = File.basename(path, ".md")
          next if name.empty? || name == Tools::MEMORY_INDEX

          yield scope, name
        end
      end
    rescue StandardError
      []
    end

    def memory_completion_dirs
      {
        "project" => File.expand_path(Tools::PROJECT_MEMORIES_DIR, Dir.pwd),
        "system" => File.expand_path(Tools::SYSTEM_MEMORIES_DIR)
      }
    end

    def normalize_model_input(input)
      input.to_s.gsub(/(^|[^\w\/])#((?:project|system)\/)?([a-zA-Z0-9][a-zA-Z0-9_-]*)/) do
        prefix = Regexp.last_match(1)
        scoped = Regexp.last_match(2).to_s
        name = Regexp.last_match(3)
        scope = scoped.delete_suffix("/")
        normalized = if scope.empty?
                       "memory \"#{name}\""
                     else
                       "memory \"#{name}\" in #{scope} scope"
                     end
        "#{prefix}#{normalized}"
      end
    end

    def history_file_path
      explicit = ENV[PROMPT_HISTORY_ENV].to_s.strip
      return explicit unless explicit.empty?

      File.join(xdg_state_home, PROMPT_HISTORY_STATE_DIR, PROMPT_HISTORY_FILE)
    end

    def xdg_state_home
      configured = ENV[XDG_STATE_HOME_ENV].to_s.strip
      return configured unless configured.empty?

      File.join(Dir.home, ".local", "state")
    end

    def load_persistent_history
      entries = load_history_entries_from_disk
      entries.last(PROMPT_HISTORY_LIMIT).each { |entry| Reline::HISTORY << entry }
    rescue StandardError
      nil
    end

    def persist_recent_history(input)
      entries = normalize_history_entries(load_history_entries_from_disk)
      entries << input
      trimmed_entries = entries.last(PROMPT_HISTORY_LIMIT)
      path = history_file_path
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(trimmed_entries) + "\n")
    rescue StandardError
      nil
    end

    def load_history_entries_from_disk
      path = history_file_path
      return [] unless File.file?(path)

      raw = File.read(path)
      parsed = JSON.parse(raw)
      normalize_history_entries(parsed)
    rescue JSON::ParserError
      normalize_history_entries(raw.to_s.lines.map(&:chomp))
    rescue StandardError
      []
    end

    def normalize_history_entries(entries)
      Array(entries).map { |entry| entry.to_s.gsub(/\r\n?/, "\n").strip }.reject(&:empty?)
    end

    def continue_request?(input)
      input == CONTINUE_COMMAND
    end

    def model_command?(input)
      input.to_s.strip.match?(/\A\/model(?:\s+.*)?\z/)
    end

    def shell_bang_command?(input)
      input.to_s.match?(/\A!\s*\S/)
    end

    def models_command?(input)
      input.to_s.strip == MODELS_COMMAND
    end

    def stats_command?(input)
      input.to_s.strip == STATS_COMMAND
    end

    def recap_command?(input)
      input.to_s.strip == RECAP_COMMAND
    end

    # Render the analytics snapshot as a compact, user-facing report. Raw event
    # logs (debug-only) are intentionally excluded; this surface is for the REPL.
    def format_session_metrics(snapshot)
      return "(no metrics yet)" unless snapshot.is_a?(Hash)

      token_src = snapshot[:token_source]
      token_src_label = case token_src
                        when :server then "server-reported"
                        when :estimate then "estimated (chars/4)"
                        else "n/a"
                        end

      lines = []
      lines << "turns:            #{snapshot[:turns]}"
      lines << "tool calls:       #{snapshot[:tool_calls_total]} (#{snapshot[:tool_errors]} errors)"
      unless snapshot[:tool_calls_by_tool].to_a.empty?
        by_tool = snapshot[:tool_calls_by_tool].sort_by { |_k, v| -v }
        lines << "  by tool:        #{by_tool.map { |k, v| "#{k}=#{v}" }.join(", ")}"
      end
      lines << "iterations:       #{snapshot[:iterations_total]}"
      lines << "tokens in/out:    #{snapshot[:tokens_in]}/#{snapshot[:tokens_out]} (total #{snapshot[:tokens_total]}, #{token_src_label})"
      lines << "gen latency (ms): #{snapshot[:gen_latency_ms]}"
      lines << "cancellations:    #{snapshot[:cancellations]}"
      lines << "retries:          #{snapshot[:retries]}"
      lines.join("\n")
    end

    def handle_model_command(input)
      suffix = input.to_s.strip.delete_prefix(MODEL_COMMAND).strip
      if suffix.empty?
        if @effective_model_name == @default_model_name
          return "runtime model: #{current_model_label} (profile=#{@profile.name})"
        else
          return "runtime model: #{current_model_label} (default: #{@default_model_name}, profile=#{@profile.name})"
        end
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
          if alias_seen
            return "multiple --alias flags are not supported: usage /model <model> --alias <name> [--default]"
          end
          alias_seen = true
          nxt = tokens[i + 1]
          if nxt.nil? || nxt.strip.empty? || nxt.start_with?("-")
            return "--alias requires a name: usage /model <model> --alias <name> [--default]"
          end
          alias_name = nxt.strip
          i += 2
        elsif tok.start_with?("--alias=")
          if alias_seen
            return "multiple --alias flags are not supported: usage /model <model> --alias <name> [--default]"
          end
          alias_seen = true
          val = tok.delete_prefix("--alias=").strip
          if val.empty? || val.start_with?("-")
            return "--alias requires a name: usage /model <model> --alias <name> [--default]"
          end
          alias_name = val
          i += 1
        else
          model_parts << tok
          i += 1
        end
      end

      arg = model_parts.join(" ").strip

      if alias_name
        if arg.empty?
          return "--alias requires a model name: usage /model <model> --alias <name> [--default]"
        end
        lowered_arg = arg.downcase
        if ["clear", "default", "none", "off"].include?(lowered_arg)
          return "--alias cannot be combined with clear/default/none/off"
        end
        # Pre-validate alias name before switching runtime (so invalid alias doesn't change model)
        begin
          # Reuse ConfigFile validation without IO by attempting a dry-run via the writer's checks
          # Inline quick checks mirroring ConfigFile.write_model_alias! to avoid switching on invalid name
          ak = alias_name.strip
          raise ArgumentError, "alias name is required" if ak.empty?
          lk = ak.downcase
          if %w[clear default none off].include?(lk)
            raise ArgumentError, "alias name '#{ak}' is reserved"
          end
          raise ArgumentError, "alias name must not contain whitespace" if ak.match?(/\s/)
          raise ArgumentError, "alias name must not start with '-'" if ak.start_with?("-")
          raise ArgumentError, "alias name must not contain '/'" if ak.include?("/")
          unless ak.match?(/\A[a-z0-9][a-z0-9._-]*\z/i)
            raise ArgumentError, "alias name must match /[a-z0-9][a-z0-9._-]*/i (got '#{ak}')"
          end
          raise ArgumentError, "alias must not point to itself" if lk == arg.strip.downcase
        rescue ArgumentError => e
          return "invalid alias: #{e.message}"
        end

        apply_runtime_model!(arg, persist_default: !!persist_default)
        persist_session_model

        begin
          previous = ConfigFile.write_model_alias!(alias_name, @effective_model_name)
        rescue ArgumentError => e
          return "invalid alias: #{e.message} (runtime model set to #{@effective_model_name} (profile=#{@profile.name}))"
        rescue StandardError => e
          return "runtime model set to #{@effective_model_name} (profile=#{@profile.name}) but failed to persist alias: #{e.message}"
        end

        key = alias_name.strip.downcase
        warn_prefix = previous ? "warning: overwriting alias '#{key}' (#{previous} -> #{@effective_model_name}); " : ""
        base = persist_default ? "runtime model set to #{@effective_model_name} (profile=#{@profile.name}) and default updated" : "runtime model set to #{@effective_model_name} (profile=#{@profile.name})"
        "#{warn_prefix}#{base}; alias '#{key}' -> '#{@effective_model_name}' persisted"
      else
        if arg.empty?
          return "--default requires a model name: usage /model --default <name> or /model <name> [--default]"
        end

        lowered = arg.downcase
        if ["clear", "default", "none", "off"].include?(lowered)
          if persist_default
            return "--default cannot be combined with clear/default/none/off"
          end
          apply_runtime_model!(@default_model_name)
          persist_session_model
          return "runtime model reset to #{@effective_model_name} (profile=#{@profile.name})"
        end

        apply_runtime_model!(arg, persist_default: !!persist_default)
        persist_session_model
        if persist_default
          "runtime model set to #{@effective_model_name} (profile=#{@profile.name}) and default updated"
        else
          "runtime model set to #{@effective_model_name} (profile=#{@profile.name})"
        end
      end
    end

    def current_model_label
      @effective_model_name
    end

    def persist_session_model
      # If engine has an active session, keep it in sync immediately
      sess = @engine.session if @engine.respond_to?(:session)
      sess ||= @resume_session
      if sess && sess.respond_to?(:model_name=)
        sess.model_name = @effective_model_name
        begin
          sess.save
        rescue StandardError
          nil
        end
      end
    end

    def handle_models_command
      # Aggregate across all hosts (lazy discovery, skip-on-error)
      results = @host_registry.list_all_models
      if results.nil? || results.empty?
        return "no hosts configured"
      end
      aliases = ConfigFile.model_aliases
      by_model = Hash.new { |h, k| h[k] = [] }
      aliases.each do |alias_name, model_id|
        # normalize bare comparison for orphan detection (strip host prefix if present)
        _, bare = @host_registry.parse_qualified_model(model_id)
        key = (bare.empty? ? model_id : bare).to_s.downcase
        by_model[key] << alias_name
        # also index full ref for exact alias display
        by_model[model_id.downcase] << alias_name unless key == model_id.downcase
      end
      by_model.each_value { |v| v.uniq!; v.sort! }

      seen = Set.new
      lines = []
      # Sort hosts for deterministic output
      results.keys.sort.each do |hname|
        data = results[hname]
        host_label = "#{hname} (#{data[:host]}:#{data[:port]})"
        if data[:error]
          lines << "#{host_label} — unreachable: #{data[:error]}"
          next
        end
        models = Array(data[:models])
        if models.empty?
          lines << "#{host_label} — no models discovered"
          next
        end
        lines << "#{host_label}:"
        models.each do |entry|
          identifier = entry["id"] || entry[:id] || "unknown"
          raw_status = entry["status"] || entry[:status]
          status = raw_status.is_a?(Hash) ? (raw_status["value"] || raw_status[:value] || raw_status["status"] || raw_status[:status]) : raw_status
          seen << identifier.to_s.downcase
          # also track host-qualified seen for orphan logic
          seen << "#{hname}:#{identifier}".downcase
          seen << "#{hname}/#{identifier}".downcase
          base = status.to_s.empty? ? "  #{identifier}" : "  #{identifier} (#{status})"
          alias_list = (by_model[identifier.to_s.downcase] || []) + (by_model["#{hname}:#{identifier}".downcase] || [])
          alias_list.uniq!
          lines << (alias_list.empty? ? base : "#{base} (alias: #{alias_list.join(", ")})")
        end
      end
      # Warnings for unreachable hosts are already in lines; no failover
      orphans = aliases.reject { |_, model_id| seen.include?(model_id.downcase) || seen.include?(bare_model_for(model_id).downcase) }
      unless orphans.empty?
        lines << ""
        lines << "orphan aliases (target not discovered):"
        orphans.sort.each { |alias_name, model_id| lines << "  #{alias_name} -> #{model_id}" }
      end
      lines = ["no models discovered"] if lines.empty?
      lines.join("\n")
    rescue StandardError => e
      "unable to list models: #{e.message}"
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

    # Engine owns the switch (alias resolution, profile, kernel, client and the
    # optional default persist); the UI mirrors the result for its status line.
    def apply_runtime_model!(model_name, persist_default: false)
      resolved_model_name = @engine.switch_model!(model_name, persist_default: persist_default)
      @effective_model_name = @engine.effective_model_name
      @default_model_name = @engine.default_model_name
      @profile = @engine.profile
      resolved_model_name
    end

    def exit_command?(input)
      normalized = input.to_s.strip.downcase
      normalized == "exit" || normalized == "/exit"
    end

    def continue_decision(input)
      normalized = input.to_s.strip
      return [:resume, nil] if normalized.empty?

      lowered = normalized.downcase
      return [:resume, nil] if lowered == CONTINUE_COMMAND || lowered == "yes" || lowered == "y"
      return [:abort, nil] if lowered == "no" || lowered == "n"

      reason_match = normalized.match(/\A(?:no|n)\s*[,:\-]\s*(.+)\z/i)
      if reason_match
        reason = reason_match[1].to_s.strip
        return [:abort, nil] if reason.empty?

        return [:abort_with_reason, reason]
      end

      [:invalid, nil]
    end

    def clone_messages(messages)
      Array(messages).map(&:dup)
    end

    def build_interrupted_turn_context(result:, checkpoint:, conversation:)
      interrupted_messages = extract_interrupted_turn_messages(checkpoint: checkpoint, conversation: conversation)
      {
        original_prompt: summarized_interrupted_prompt(interrupted_messages),
        tool_trace: summarized_interrupted_tool_trace(result),
        last_model_intent: summarized_interrupted_model_excerpt(interrupted_messages)
      }
    end

    def extract_interrupted_turn_messages(checkpoint:, conversation:)
      checkpoint_messages = Array(checkpoint)
      conversation_messages = Array(conversation)
      return [] if checkpoint_messages.empty? || conversation_messages.length < checkpoint_messages.length
      return [] unless conversation_messages.first(checkpoint_messages.length) == checkpoint_messages

      conversation_messages[checkpoint_messages.length..] || []
    end

    def summarized_interrupted_prompt(messages)
      prompt = Array(messages).find { |message| message[:role] == "user" }
      preview_text(prompt && prompt[:content], INTERRUPTED_SUMMARY_PROMPT_LIMIT)
    end

    def summarized_interrupted_tool_trace(result)
      activities = if result.respond_to?(:tool_activity)
                     Array(result.tool_activity)
                   else
                     []
                   end
      return [] if activities.empty?

      activities.last(INTERRUPTED_SUMMARY_TOOLS_LIMIT).map do |activity|
        tool = activity[:tool].to_s.strip
        status = activity[:status].to_s.strip
        params = preview_text(activity[:params], INTERRUPTED_SUMMARY_PARAMS_LIMIT)
        parts = [tool]
        parts << "status=#{status}" unless status.empty?
        parts << "params=#{params}" unless params.empty?
        parts.join(" ")
      end
    end

    def summarized_interrupted_model_excerpt(messages)
      model_message = Array(messages).reverse.find { |message| message[:role] == "model" }
      preview_text(model_message && model_message[:content], INTERRUPTED_SUMMARY_MODEL_LIMIT)
    end

    def interrupted_turn_reason_message(reason:, context:)
      lines = ["I chose not to continue the interrupted turn because: #{reason}"]
      lines << ""
      lines << "Interrupted turn summary:"
      original_prompt = context && context[:original_prompt]
      lines << "- original_prompt: #{original_prompt.to_s.empty? ? "(unavailable)" : original_prompt}"

      tool_trace = context ? Array(context[:tool_trace]) : []
      if tool_trace.empty?
        lines << "- interrupted_tools: (none)"
      else
        lines << "- interrupted_tools: #{tool_trace.join("; ")}"
      end

      model_intent = context && context[:last_model_intent]
      lines << "- last_model_intent: #{model_intent.to_s.empty? ? "(unavailable)" : model_intent}"
      lines << ""
      lines << "Please keep the original prompt context. If my next message does not provide a clear replacement request, ask what we should do instead."
      lines.join("\n")
    end

    def preview_text(text, limit)
      normalized = text.to_s.gsub(/\s+/, " ").strip
      return "" if normalized.empty?
      return normalized if normalized.length <= limit

      normalized[0, limit].rstrip + "..."
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
      cancellation_controller = Client::CancellationController.new
      @active_cancel_controller = cancellation_controller
      @renderer.begin_turn
      # Build the (memoized) prompt now so --memory activations show in this
      # turn's status lines, including after /model rebuilt it.
      seed_system_prompt
      # A new turn invalidates any in-flight recap.
      @engine.recap&.invalidate!
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

    def run_selected_backend(messages, max_iterations:, on_stream_event:, cancel_controller:, pending_input: nil)
      backend = @engine.backend
      return @kernel.run(
        messages,
        max_iterations: max_iterations,
        on_stream_event: on_stream_event,
        cancel_controller: cancel_controller,
        model_name: @effective_model_name,
        pending_input: pending_input
      ) unless backend

      backend.complete(
        messages: messages,
        max_iterations: max_iterations,
        on_stream_event: on_stream_event,
        cancel_controller: cancel_controller,
        model_name: bare_model_for(@effective_model_name),
        pending_input: pending_input
      )
    end

    # Turn lifecycle for the muted background reminder run.
    #
    # That run drives KernelLoop directly on a snapshot (see
    # #start_muted_reminder_generation), bypassing Engine#run_turn, so it never
    # emits the :turn_started / :turn_completed / :turn_canceled events the
    # SessionMetrics collector needs to tally a turn. begin/end_interactive_turn
    # feed the same shared collector the Engine observer feeds for every
    # run_turn, so /stats reports real numbers.
    #
    # The flag is idempotent (guard on @turn_open) and every terminal path
    # calls end so the turn never leaks open.
    def begin_interactive_turn(session)
      return if @turn_open

      @turn_open = true
      @engine.session = session
      @engine.metrics.session_id = session.id if session.respond_to?(:id)
      # A new turn invalidates any in-flight recap; the running flag stops
      # the idle detector from firing while a turn is in progress.
      @engine.set_turn_running(true)
      @engine.recap&.invalidate!
      @engine.metrics.call(type: :turn_started, session_id: session.id.to_s, prompt: nil)
    end

    def end_interactive_turn(canceled:, announce: true)
      return unless @turn_open

      @turn_open = false
      @engine.set_turn_running(false)
      if canceled
        @engine.metrics.call(type: :turn_canceled, cancellation_reason: :interrupt)
      else
        @engine.metrics.call(type: :turn_completed, result: nil)
      end
      emit_interactive_turn_duration(canceled: canceled) if announce
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
      $stdout.puts "\nmodel> request cancelled#{label.empty? ? "" : " (#{label})"}"
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

    def finish_thinking_spinner
      return unless @thinking_spinner_rendered

      line_count = @thinking_spinner_lines_rendered.to_i
      line_count = 1 if line_count <= 0

      if line_count > 1
        $stdout.print("\e[#{line_count - 1}A")
      end
      $stdout.print("\r")
      line_count.times do |index|
        $stdout.print("\e[0K")
        $stdout.print("\n") if index < line_count - 1
      end
      if line_count > 1
        $stdout.print("\e[#{line_count - 1}A")
      end
      $stdout.print("\r")
      $stdout.flush
      @thinking_spinner_rendered = false
      @thinking_spinner_active = false
      @thinking_spinner_lines_rendered = 0
      @thinking_spinner_last_render_at = nil
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = false
    end

    private

    def move_to_thinking_spinner_origin
      return unless @thinking_spinner_rendered

      line_count = @thinking_spinner_lines_rendered.to_i
      if line_count > 1
        $stdout.print("\e[#{line_count - 1}A")
      end
      $stdout.print("\r")
    end

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

    def thinking_tail_preview_lines
      line_count = thinking_preview_lines_count
      prefix = "model> … "
      continuation = " " * prefix.length
      preview_width = thinking_preview_width
      first_width = [preview_width - prefix.length, 1].max
      continuation_width = [preview_width - continuation.length, 1].max

      text = thinking_tail_preview_text
      text = text[-thinking_tail_preview_capacity, thinking_tail_preview_capacity] || text
      chunks = [text.slice(0, first_width).to_s]
      offset = first_width
      (line_count - 1).times do
        chunks << text.slice(offset, continuation_width).to_s
        offset += continuation_width
      end

      lines = [cap_preview_line("#{prefix}#{chunks[0]}")]
      chunks.drop(1).each do |chunk|
        lines << cap_preview_line("#{continuation}#{chunk}")
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

    def retry_spinner_status_line(frame)
      data = @retry_spinner_status || {}
      attempt = data[:attempt].to_i
      max_retries = data[:max_retries].to_i
      total_attempts = max_retries + 1
      delay = format("%.1f", data[:next_delay].to_f)
      error_class = data[:error_class].to_s
      message = "model> network error: retrying (#{attempt}/#{total_attempts} in #{delay}s) #{frame}"
      message += " #{error_class}" unless error_class.empty?
      capped = cap_preview_line(message)
      color_output? ? paint(capped, NETWORK_RETRY_SPINNER_COLOR) : capped
    end

    def cap_preview_line(text)
      cap_preview_text(text, thinking_preview_width)
    end

    def thinking_preview_width
      width = status_effective_width
      return THINKING_PREVIEW_WIDTH if width <= 0

      [width, THINKING_PREVIEW_WIDTH].min
    end

    def cap_preview_text(text, width)
      return "" if width <= 0

      value = text.to_s
      value.length > width ? value[0, width] : value
    end

    def thinking_preview_lines_count
      raw = ENV.fetch(THINKING_PREVIEW_LINES_ENV, THINKING_PREVIEW_LINES_DEFAULT.to_s).to_s.strip
      value = Integer(raw)
      value = THINKING_PREVIEW_LINES_DEFAULT unless value.positive?
      [[value, 1].max, THINKING_PREVIEW_LINES_MAX].min
    rescue ArgumentError
      THINKING_PREVIEW_LINES_DEFAULT
    end

    def thinking_tail_preview_capacity
      prefix_length = "model> … ".length
      preview_width = thinking_preview_width
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
      normalized = ContextUsage.normalize(payload)
      return unless normalized

      @latest_server_context_status = normalized
    end

    def status_line_enabled?
      value = ENV.fetch(STATUS_LINE_ENV, STATUS_LINE_ON).to_s.strip.downcase
      !(value.empty? || value == STATUS_LINE_OFF || value == "0" || value == "false")
    end

    def emit_idle_status_line
      return unless status_line_enabled?

      lines = idle_status_lines
      return if lines.empty?

      lines.each { |line| $stdout.puts line }
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
      _, bare = @host_registry.parse_qualified_model(full_ref)
      bare.to_s.strip.empty? ? full_ref.to_s.strip : bare
    end

    def spinner_status_line
      return "" unless status_line_enabled?

      lines = spinner_status_lines
      lines.empty? ? "" : lines.first
    end

    def spinner_status_lines
      return [] unless status_line_enabled?

      build_status_lines(scope: :spinner)
    end

    def sticky_status_line
      return "" unless status_line_enabled?

      lines = sticky_status_lines
      lines.empty? ? "" : lines.first
    end

    def sticky_status_lines
      return [] unless status_line_enabled?

      build_status_lines(scope: :sticky)
    end

    def idle_status_line
      return "" unless status_line_enabled?

      lines = idle_status_lines
      lines.empty? ? "" : lines.first
    end

    def idle_status_lines
      return [] unless status_line_enabled?

      build_status_lines(scope: :idle)
    end

    def build_status_line(scope:)
      lines = build_status_lines(scope: scope)
      lines.empty? ? "" : lines.first
    end

    def build_status_lines(scope:)
      segments = status_segments(scope)
      return [] if segments.empty?

      body = "status> #{segments.join(' | ')}"
      lines = status_body_lines(body)
      if color_output?
        lines.map { |line| paint(line, 90) }
      else
        lines
      end
    end

    def status_body_lines(body)
      width = status_effective_width
      return [] if width <= 0

      [cap_preview_text(body, width)]
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
      if @effective_model_name == @default_model_name
        "model=#{@effective_model_name}"
      else
        "model=#{@effective_model_name} (default: #{@default_model_name})"
      end
    end

    def status_context_segment
      server_status = @latest_server_context_status
      return format_server_context_segment(server_status) if server_status.is_a?(Hash)

      status = @latest_context_status
      return "" unless status.is_a?(Hash)

      pct = format("%.1f", status[:est_pct].to_f)
      bucket = status[:bucket].to_s
      return "ctx=#{pct}%" if bucket.empty?

      "ctx=#{pct}% (#{bucket})"
    end

    def format_server_context_segment(status)
      pct = status[:ctx_pct]
      base = pct ? "ctx=#{format('%.1f', pct)}%" : "ctx=srv"

      tokens = []
      prompt_tokens = status[:prompt_tokens]
      completion_tokens = status[:completion_tokens]
      total_tokens = status[:total_tokens]
      tokens << "p=#{prompt_tokens}" if prompt_tokens
      tokens << "c=#{completion_tokens}" if completion_tokens
      tokens << "t=#{total_tokens}" if total_tokens

      return base if tokens.empty?

      "#{base} (#{tokens.join(' ')})"
    end

    def status_memory_segment(scope)
      names, limit = case scope
                     when :spinner
                       [Array(@thinking_memory_names), MEMORY_SPINNER_PREVIEW_LIMIT]
                     else
                       [Array(@session_memory_names), MEMORY_STICKY_PREVIEW_LIMIT]
                     end
      return "" if names.empty?

      visible = names.first(limit)
      suffix = names.length > visible.length ? ", +#{names.length - visible.length}" : ""
      "mem: #{visible.join(', ')}#{suffix}"
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

    def queue_input_prefill(text)
      normalized = text.to_s.strip
      return if normalized.empty?

      @next_input_prefill = normalized
    end

    def queue_default_input
      return if @resume_session
      return if @no_default_input

      default = ENV.fetch(DEFAULT_INPUT_ENV, nil)
      return if default.nil? || default.strip.empty?

      queue_input_prefill(default)
    end

    def consume_input_prefill
      value = @next_input_prefill
      @next_input_prefill = nil
      value
    end

    def with_next_input_prefill
      prefill = consume_input_prefill
      return yield if prefill.nil? || prefill.empty?

      previous_hook = Reline.pre_input_hook
      inserted = false
      Reline.pre_input_hook = proc do
        unless inserted
          Reline.insert_text(prefill)
          inserted = true
        end
        previous_hook.call if previous_hook
      end
      begin
        yield
      ensure
        # Restore only what we replaced: a method-level ensure also ran on the
        # no-prefill early return and reset the hook to nil, dropping the
        # Engine activity hook (with_activity_hook) after the first prompt.
        Reline.pre_input_hook = previous_hook
      end
    end

    # Install a Reline.pre_input_hook that resets the Engine's shared inactivity
    # clock on the first keystroke of each input (not on submit). This is the
    # single seam the Engine-owned idle recap detector reads, so the idle clock
    # is identical for the REPL and any other Engine-backed UI. Chains onto any
    # previously-installed hook (e.g. the input prefill hook).
    def with_activity_hook
      previous_hook = Reline.pre_input_hook
      Reline.pre_input_hook = proc do
        @engine.record_activity
        previous_hook.call if previous_hook
      end
      yield
    ensure
      Reline.pre_input_hook = previous_hook
    end

    def render_thinking_spinner
      frame = THINKING_SPINNER_FRAMES[@thinking_spinner_index % THINKING_SPINNER_FRAMES.length]
      spinner_lines = thinking_spinner_status_lines(frame)
      preview_lines, preview_has_content = turn_preamble_enabled? ? [[], false] : thinking_tail_preview_lines
      if color_output?
        preview_lines = preview_lines.map { |text| paint(text, 90) }
      end
      lines = spinner_lines + preview_lines
      status_lines = spinner_status_lines
      lines.concat(status_lines) unless status_lines.empty?

      move_to_thinking_spinner_origin
      previous_line_count = @thinking_spinner_lines_rendered.to_i
      render_line_count = [previous_line_count, lines.length].max
      padded_lines = lines + Array.new(render_line_count - lines.length, "")
      $stdout.print(padded_lines.map { |text| "#{text}\e[0K" }.join("\n"))
      $stdout.flush
      @thinking_spinner_rendered = true
      @thinking_spinner_lines_rendered = render_line_count
      @thinking_spinner_last_render_at = monotonic_time
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = preview_has_content
    end

    def thinking_spinner_status_line(frame)
      lines = thinking_spinner_status_lines(frame)
      lines.empty? ? "" : lines.first
    end

    def thinking_spinner_status_lines(frame)
      if retry_spinner_status_active?
        return [retry_spinner_status_line(frame)]
      end

      preamble_active = turn_preamble_status_base(frame)
      base = preamble_active || "model> thinking... #{frame}"
      available_for_notification = [status_effective_width - base.length, 0].max
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
      id = (pending[:id] || pending["id"]).to_s
      question = (pending[:question] || pending["question"]).to_s
      options = pending[:options] || pending["options"] || []
      options = Array(options).map { |v| v.to_s.strip }.reject(&:empty?)
      header = (pending[:header] || pending["header"]).to_s.strip
      header = nil if header.empty?
      multi = !!(pending[:multi_select] || pending["multi_select"])
      free = !!(pending[:allow_freeform] || pending["allow_freeform"])

      # Ensure spinner cleared and terminal in known state (same as reminder mute handling)
      finish_thinking_spinner rescue nil

      # Print widget (uses $stdout directly, not Reline buffer)
      $stdout.puts "" if $stdout.tty?
      if header && !header.empty?
        line = header
        line = paint(line, 1) if color_output?
        $stdout.puts line
      end
      q_line = "? #{question}"
      q_line = paint(q_line, 94) if color_output?
      $stdout.puts q_line
      options.each_with_index do |opt, idx|
        num = idx + 1
        opt_str = "  #{num}) #{opt}"
        opt_str = paint(opt_str, 92) if color_output?
        $stdout.puts opt_str
      end
      hint = []
      hint << (multi ? "Select one or more (e.g. 1,3)" : "Select one (e.g. 2)")
      hint << "add '; freeform text' when Other/freeform needed" if free
      $stdout.puts paint("  [#{hint.join('; ')}]", 90) if color_output?
      $stdout.puts "  Enter empty to cancel." if !free # still allow cancel

      # Loop until valid selection or cancel
      loop do
        prompt = color_output? ? paint("choice> ", 33) : "choice> "
        raw = nil
        begin
          # Use plain Reline.readline when tty, else $stdin.gets for non-tty/specs
          if $stdin.tty? && $stdout.tty?
            raw = Reline.readline(prompt, true)
          else
            $stdout.print(prompt)
            $stdout.flush
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
          $stdout.puts "(cancelled)" if $stdout.tty?
          return false
        end

        # Split freeform: "1,3; my text" or "1; text" — first ';' separates selection vs freeform
        sel_part, free_part = raw.split(";", 2).map { |s| s.to_s.strip } if raw.include?(";")
        sel_part ||= raw
        free_part = free_part ? free_part.strip : nil
        free_part = nil if free_part && free_part.empty?
        # Validate freeform allowed — dumb-model tolerant: accept freeform even if not flagged, just warn
        if free_part && !free
          $stdout.puts "(note: freeform not flagged but accepting '#{free_part}')"
        end

        # Parse selection indices: comma/space separated numbers or values
        tokens = sel_part.split(/[,\s]+/).map(&:strip).reject(&:empty?)
        # Also handle "1 3" etc
        indices = []
        labels = []
        valid = true
        tokens.each do |tok|
          if tok.match?(/\A\d+\z/)
            idx = tok.to_i - 1
            if idx < 0 || idx >= options.size
              $stdout.puts "Invalid choice '#{tok}': pick 1-#{options.size}"
              valid = false
              break
            end
            indices << idx
            labels << options[idx]
          else
            # Allow value/label substring match (case-insensitive)
            found = options.index { |o| o.downcase == tok.downcase || o.downcase.include?(tok.downcase) }
            if found.nil?
              $stdout.puts "Unknown option '#{tok}'. Use numbers 1-#{options.size} or exact labels."
              valid = false
              break
            end
            indices << found
            labels << options[found]
          end
        end
        next unless valid

        labels.uniq!
        indices = labels.map { |l| options.index(l) }.compact

        if labels.empty? && free_part.nil?
          $stdout.puts "No selection. Try again."
          next
        end
        if !multi && labels.size > 1
          $stdout.puts "This is single-select (pick one). Try again."
          next
        end
        # Require freeform when 'Other' selected? Not enforced generically — harness accepts any.

        # Deduplicate + preserve order
        uniq_labels = []
        seen = {}
        labels.each { |l| unless seen[l]; uniq_labels << l; seen[l]=true; end }

        begin
          @engine.answer_question(id: id, selected: uniq_labels, freeform: free_part)
          return true
        rescue ArgumentError => e
          $stdout.puts "Invalid: #{e.message}. Try again."
          next
        rescue StandardError => e
          $stdout.puts "Error: #{e.message}"
          return false
        end
      end
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
