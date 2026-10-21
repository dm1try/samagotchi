# frozen_string_literal: true

require_relative "../client_id"
require_relative "../composer_route"
require_relative "event_renderer"
require_relative "formatting"
require_relative "../prompt_history"
require_relative "../session_inbox"
require_relative "attached_view"
require_relative "status_row"
require_relative "input_support"
require_relative "image_input"
require_relative "line_reader"
require_relative "question_prompt"
require_relative "reline_seam"
require_relative "version_lines"
require_relative "../bridge/turn_accumulator"
require_relative "../bridge_client"
require_relative "../delivery"
require_relative "../log"
require_relative "../context_note"
require_relative "../steer"
require_relative "../model_profile"
require_relative "../output_formatter"
require_relative "../session_commands"
require_relative "../session_manager"
require_relative "../session_metrics"
require_relative "../children_status"
require_relative "../guardrails/parent_approvals"
require_relative "../tool_activity"
require_relative "../tool_view"
require_relative "../message_parts"

module Samagotchi
  class TerminalUI
    # The TUI attached to a session that a worker owns (`chi --attach`):
    # a thin Bridge client, with no Engine and no OwnerLock of its own.
    #
    # #handle_event turns the worker's event stream into terminal output:
    # the snapshot a join starts with (the last exchange, queued prompts,
    # the turn so far), prompts other clients sent, and each turn through the
    # same EventRenderer the local REPL uses, drawn by an AttachedView.
    class AttachedLoop
      include Formatting
      include InputSupport

      PROMPT = "> "
      # How long /exit --delete waits for the worker to let go.
      DELETE_WAIT = 10
      # A second Ctrl-C at an empty idle prompt within this many seconds detaches.
      DETACH_WINDOW = 2.0
      DETACH_HINT = "Ctrl-D to detach, /exit stops the worker"
      # Why a request the Bridge read after its deadline didn't go through.
      LATE = "worker not answering in time"
      # An exit the worker agreed to in an empty session. Said before it has
      # left: it checks again once it lets go, and a note or prompt arriving
      # first keeps the session (SessionManager.discard_left_session).
      EMPTY_EXIT = "Detached; the session is empty: it will be discarded if nothing arrives before its worker stops."
      # Why the worker stayed up after /exit, by the reason it gave.
      HELD_REASONS = {
        "turn_running" => "a turn is running", "input_queued" => "prompts are queued",
        "continue_offered" => "a continue offer is pending", "client_connected" => "another UI is attached",
        "reminders" => "reminders are set", "starting" => "the worker is still starting",
        "background_tasks" => "background tasks it started are still running"
      }.freeze
      # How to end a background task that holds the worker up (an older
      # worker's 409 has no hint of its own).
      TASK_STOP_HINT = "stop one with the web's stop-task button or by asking for task_stop"
      # How much of the last answer a join shows.
      JOIN_ANSWER_LINES = 12
      JOIN_ANSWER_CHARS = 1200

      attr_reader :client_id

      # @return [String, nil] the model the worker's turns run on, as the
      #   last command said
      # @return [String, nil] the worker's model
      def model_name = @status[:model]

      # @return [QuestionPrompt, nil] the question waiting for an answer
      attr_reader :question

      # @return [Hash, nil] the pending question (symbol keys) #run left
      #   waiting when it ended :unanswered
      attr_reader :unanswered

      # @param client [BridgeClient]
      # @param screen [Surface] with #synchronize and #columns (a Screen, or a
      #   PlainSurface when the terminal can't show a live region)
      # @param client_id [String] this UI's id in the events ("tui:<pid>")
      # @param first_prompt [String, nil] sent once joined (`chi -p`)
      # @param first_command [String, Array<String>, nil] run before the
      #   first prompt, in order (`--model` on a resumed session: "/model X";
      #   --llm-context: "/llm-context strategy …"; --thinking: "/thinking X
      #   --yes"); if one doesn't go
      #   through, the launch stops
      # @param no_interrupt [Boolean] post every turn with no_interrupt
      # @param default_input [Boolean] type SAMAGOTCHI_DEFAULT_INPUT into
      #   the first read (a new session with no -p, as the REPL)
      # @param clock [#call] monotonic seconds (the Ctrl-C detach window)
      # @param delete_session [#call] session id -> deletes it (/exit --delete)
      # @param archive_session [#call] session id -> archives it (/archive);
      #   SessionManager.archive_session's result
      # @param wait_at_eof [Boolean] lines come from a pipe or a file (`chi -p
      #   X </dev/null`): at their end, detach only once this run's prompts
      #   (the -p one too) have had their turns; if one failed, #run says so
      # @param children_counts [#call] session id -> its delegates'
      #   ChildrenStatus::Counts, the status row's children segment
      # @param state_dir [String] the state dir the worker was found in: its
      #   session folder (@path images, saved records) is under it
      def initialize(client:, screen:, client_id:, first_prompt: nil, first_command: nil, no_interrupt: false,
                     default_input: false, wait_at_eof: false, as_parent: false,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     delete_session: ->(id) { SessionManager.delete_session(id, stop: true, wait: DELETE_WAIT) },
                     archive_session: ->(id) { SessionManager.archive_session(id, wait: DELETE_WAIT) },
                     installed_version: -> { InstalledVersions.new.newest },
                     state_dir: Session.default_state_dir,
                     children_counts: ->(id) { ChildrenStatus.counts(id, state_dir: state_dir) })
        @client = client
        @state_dir = state_dir
        @installed_version = installed_version
        @delete_session = delete_session
        @archive_session = archive_session
        @screen = screen
        @client_id = client_id
        # A parent agent drives this attach (AttachLauncher:
        # ParentApprovals.parent_process?): its answers go as chi answer's,
        # so the worker holds them to Guardrails::ParentPolicy.
        @as_parent = as_parent
        @view = AttachedView.new(screen)
        @renderer = EventRenderer.new(@view)
        @shown_enqueued = Set.new
        @running = false
        @joined_mid_turn = false
        @attached = false
        # The stream moved to a new worker; its snapshot resyncs (#switch_worker).
        @worker_changed = false
        @early_lines = []
        @question = nil
        @answered_ids = Set.new
        # Commands queued for after the running turn, any UI's: a /archive
        # typed during the turn waits for them too (#archive_due?).
        @queued_ids = Set.new
        @archive_after_turn = false
        @reader = nil
        @first_prompt = first_prompt
        @first_commands = Array(first_command)
        @first_command_id = nil
        @no_interrupt = no_interrupt
        @no_default_input = !default_input
        @clock = clock
        @last_idle_interrupt_at = nil
        @next_input_prefill = nil
        # Prompts this run sent, by enqueued_id: only those come back into
        # the input when their turn fails (a replayed event must not).
        @sent_ids = Set.new
        # This run's prompts queued for after the running turn (their ack
        # said queue), oldest first, until their turn starts or they are
        # removed: /unqueue takes back the newest.
        @my_queued = []
        @wait_at_eof = wait_at_eof
        # Sent and not ended yet (by enqueued_id), the ones merged into the
        # running turn, whether the input has ended, and whether one of this
        # run's prompts failed (wait_at_eof only).
        @open_ids = Set.new
        @merged_ids = Set.new
        @input_ended = false
        @own_failed = false
        # A continue offer is pending: the prompt asks for the answer.
        @continue_offer = nil
        # The status row: the worker's model, ctx, the session's memories.
        @status = StatusRow.new(screen)
        @children_counts = children_counts
      end

      def running? = @running

      # Follow the session and read input until Ctrl-D, /detach, /exit or
      # the worker goes away. The worker keeps running after a detach; /exit
      # asks it to exit too, and it does unless something still needs it.
      # @return [Symbol] :detached, :closed when the worker went away,
      #   :failed when the first command (--model) didn't go through, or
      #   (wait_at_eof) :turn_failed when one of this run's prompts failed,
      #   :empty_answer when one ended with no answer, and :unanswered when
      #   a question came after the input ended
      # @param input [#call, nil] prompt -> line (nil = Ctrl-D, raising
      #   Interrupt = Ctrl-C); defaults to Reline
      def run(input: nil)
        queue = @queue = Thread::Queue.new
        load_persistent_history
        # Reline's seam asks this on Ctrl-C while the typed text is still
        # there; declining lets the read end with Interrupt as before.
        previous_interrupt_handler = RelineSeam.interrupt_handler
        RelineSeam.interrupt_handler = method(:note_interrupted_line)
        # Tagged, so the worker doesn't count this stream as another UI
        # when this UI asks it to exit.
        # A new worker (a restart) is followed, not lost: its sidecar is
        # looked for whenever the stream drops.
        stream = @client.follow(client_id: @client_id, rediscover: method(:live_worker),
                                reconnect_delays: BridgeClient::EventStream::REDISCOVER_DELAYS) do |event|
          queue << [:event, event]
        end
        @reader = LineReader.new(queue, prompt: method(:prompt_text), read: input || method(:read_input_line),
                                        prefill: default_input_text).start
        loop do
          kind, payload = next_item(queue)
          case kind
          when :event
            ended = safely_handle(payload)
            return ended if %i[closed failed unanswered].include?(ended)
            return archive_now if archive_due?

            ended = take_early_lines
            return ended if ended
            return end_of_input if @input_ended && !own_turns_pending?
          when :line
            # A pipe is read at once: its lines wait for the joining
            # snapshot, which may bring the question they answer.
            next @early_lines << payload if @wait_at_eof && !@attached

            ended = take_line(payload)
            return ended if ended
          when :interrupt then return :detached if interrupt(payload) == :detach
          end
        end
      ensure
        RelineSeam.interrupt_handler = previous_interrupt_handler
        # The loop is over: end the read the reader still has open. Not under
        # the screen's lock: the reader may be waiting for it to draw. The
        # read takes its prompt away as it ends; clearing the editor slot
        # covers a reader that had to be killed.
        @reader&.stop
        @view.stop
        @screen.clear_slot(:editor)
        stream&.close
      end

      # One input line (nil: the input ended).
      # @return [Symbol, nil] how the run ends, or nil to go on
      def take_line(line)
        if line.nil? && @wait_at_eof && own_turns_pending?
          # The pipe's end: this run's turns first. An open question
          # has nothing left to answer it.
          return unanswered_question(@question_pending) if @question

          @input_ended = true
          return nil
        end
        end_of_input if submit(line) == :detach
      end

      # The lines read before the snapshot came, once it has.
      # @return [Symbol, nil] how the run ends, or nil to go on
      def take_early_lines
        until !@attached || @early_lines.empty?
          ended = take_line(@early_lines.shift)
          return ended if ended
        end
        nil
      end

      # Render one Bridge event (string keys).
      # @return [Symbol, nil] :closed when the stream ended, :failed when the
      #   launch's first command didn't go through
      def handle_event(event)
        event = EventRenderer.symbolize(event)
        case event[:type]
        when :snapshot, :reset
          take_session_state(event[:session_state_snapshot] || {})
          return render_snapshot(event[:snapshot] || {}, reset: event[:type] == :reset)
        when :turn_enqueued then show_enqueued(event)
        when :turn_dequeued then turn_dequeued(event)
        when :turn_started
          @status.take_event(event)
          start_turn(event)
        when :turn_completed
          @status.take_event(event)
          complete_turn(event)
          refresh_children
          own_turn_ended(event)
        # The renderer says how it ended (the REPL's words too).
        when :turn_canceled, :turn_failed
          @status.take_event(event)
          @renderer.call(event)
          end_turn
          refresh_children
          own_turn_ended(event)
        when :prompt_restored then restore_prompt(event)
        # The after_turn hooks are done (their notices came before it).
        when :answer_display then @display_pending = false
        when :context_status, :used_memories_updated then @status.take_event(event)
        # Another client's anytime command: its line now, before the cards
        # it shows (its command_ran comes when it's done). One queued for
        # after the turn says so now.
        when :command_queued
          @screen.commit(prompt_line(event[:client_id], event[:line])) if event[:anytime] && !own?(event[:client_id]) && !event[:card]
          command_waits(event) if event[:waits] && !event[:card]
        when :command_ran
          command_ran(event)
          return first_command_ran(event) if @first_command_id && event[:command_id] == @first_command_id
        when :reminder_injected then @screen.commit(reminder_line(event[:reminders]))
        # A context note joined the conversation (between turns). One dim
        # line in the scrollback; the notes slot is for question choices.
        when :context_added then @screen.commit(context_note_line(event[:label], event[:text]))
        when :continue_offered then offer_continue(event)
        when :continue_resolved then continue_resolved(event)
        # The note comes with the kernel's :pending_input_merged (EventRenderer),
        # after the answer the merge follows.
        when :input_merged
          merged_own_prompts(event)
          # A delegate's report: a child's state changed.
          refresh_children if Array(event[:origins]).any? { |origin| report_origin?(origin) }
        when :question_requested
          # Nothing is left to answer it with.
          return unanswered_question(event[:pending_question]) if @input_ended

          ask(event[:pending_question])
        when :question_answered then question_answered(event)
        when :question_cancelled
          close_question(@question.closed_text(event[:reason])) if @question
        # Relayed to the parent's card, or no longer: the widget says so.
        when :question_relay then question_relayed(event)
        # Written while the session sat idle: shown at the open prompt. One
        # collected just as a turn started describes the chat before it.
        when :recap_ready then @screen.commit(recap_block(event[:recap])) unless @running || event[:recap].to_s.strip.empty?
        when :guardrail_warning then @screen.commit(EventRenderer.load_warning_line(event))
        # A plugin's slow setup: the activity row turns while it runs; a
        # line when it is done (a failure is a warn card).
        when :plugin_init_started then @view.init_started(event)
        when :plugin_init_finished
          @view.init_finished(event)
          line = EventRenderer.init_line(event)
          @screen.commit(line) if line
        when :generation_completed
          @status.take_event(event)
          @renderer.call(event)
        when :worker_changed then switch_worker(event)
        when :stream_closed
          @view.finish_thinking_spinner
          @screen.commit("Lost the session's worker (#{event[:reason]}). " \
                             "Resume it with: chi --shared --resume #{@client.session_id}")
          return :closed
        else @renderer.call(event)
        end
        nil
      end

      private

      # The newest chi installed, looked at once, at the join.
      def installed_version
        @installed_version.call
      rescue StandardError
        nil
      end

      # The session's live worker for the stream to follow (EventStream's
      # rediscover): nil while there is none yet, :gone once the session was
      # stopped (no worker is coming).
      def live_worker
        id = @client.session_id
        return :gone if Session.stopped_marker?(id)

        BridgeClient.discover(id, session_dir: Session.session_dir(id, state_dir: @state_dir), host: @client.host)
      end

      # The stream moved to a new worker (a restart): requests go there too.
      def switch_worker(event)
        @client = BridgeClient.new(session_id: @client.session_id, port: event[:port], host: @client.host)
        @worker_changed = true
        @view.finish_thinking_spinner
        Log.info(:attached, "worker_changed", port: event[:port])
        nil
      end

      def next_item(queue)
        queue.pop
      rescue Interrupt
        # Ctrl-C while no prompt is open (between two reads).
        [:interrupt]
      end

      # A rendering bug must not end the session's UI.
      def safely_handle(event)
        handle_event(event)
      rescue StandardError => e
        @screen.commit("(could not render #{event["type"] || event[:type]}: #{e.class}: #{e.message})")
        nil
      end

      # @return [Symbol, nil] :detach to end the loop
      def submit(line)
        return detach("Detached; the session keeps running. Re-attach with: chi --attach #{@client.session_id}") if line.nil?

        text = line.strip
        if @question
          # /detach leaves the question open, as Ctrl-D does; any other
          # line (/exit too) is read as the answer.
          return submit(nil) if command_registry.lookup_local(text)&.id == :detach

          return answer_question(text)
        end

        # /cut TEXT and /queue TEXT are this UI's own deliveries, read before
        # every command check (ComposerRoute; SessionCommands registers them
        # for Tab and /help only). A plain line sends no delivery: it goes in
        # at the running turn's next step, and never cuts.
        route = ComposerRoute.call(text, running: @running, registry: command_registry)
        return submit_delivery(route) if route.choice

        # The terminal's own commands (SessionCommands registers them, the
        # REPL reads the same words). Before the continue offer: the
        # leaving ones are no answer to it.
        local = route.local
        return submit(nil) if local == :detach
        return SessionCommands.delete_on_exit?(text) ? exit_and_delete : exit_worker if local == :exit
        return archive_after_turn if local == :archive && (@running || !@queued_ids.empty?)
        return exit_and_archive if local == :archive

        if @continue_offer
          return answer_continue(text) unless local || route.kind == :command

          # Not an answer: the read left no echo, so show what ran.
          echo_answer(text)
        end
        return if route.kind == :empty

        if local == :stats
          show_stats
        elsif local == :recap
          show_recap
        elsif local == :unqueue
          unqueue_newest
        elsif route.kind == :command
          # The history keeps !cmds, as the REPL's does (prompts: #send_prompt).
          persist_recent_history(text) if PromptHistory.shell_line?(text)
          send_command(text)
        elsif route.kind == :typo
          # A typo of a command (/modle) is not a prompt: say so, send nothing.
          @screen.commit(route.reply)
        else
          send_prompt(text)
        end
        nil
      end

      # /cut TEXT and /queue TEXT (+route+ has a choice). During a turn the
      # text goes with its delivery: a cut, or queued to run as a turn of
      # its own after this one. A worker that doesn't queue (its sidecar
      # names no "delivery" feature) would steer a queue, so it is not sent.
      # At the prompt both send the text as typed, a normal turn: no local
      # word or typo check (the worker's Bridge runs a session command as
      # the command).
      # @param route [ComposerRoute::Route]
      # @return [nil]
      def submit_delivery(route)
        return @screen.commit(STEER_CHOICE_USAGE) if route.kind == :usage
        return @screen.commit(QUEUE_NEEDS_NEWER_WORKER) if Delivery.queue?(route.delivery) && !worker_queues?

        # To an idle session it is an ordinary prompt: no delivery to send.
        send_prompt(route.text, delivery: route.delivery)
        nil
      end

      # Whether the attached worker runs delivery: queue (its sidecar names
      # Delivery::QUEUE_FEATURE). No sidecar to read: true, its Bridge
      # answers (a P0-P2 worker refuses a queue: #send_prompt).
      def worker_queues?
        sidecar = WorkerSidecar.read(Session.session_dir(@client.session_id, state_dir: @state_dir))
        sidecar.nil? || sidecar.features.include?(Delivery::QUEUE_FEATURE)
      end

      # @return [Symbol] :detach
      def detach(line)
        @view.finish_thinking_spinner
        @screen.commit(line)
        :detach
      end

      # Detach, and ask the worker to exit now. The worker decides: it stays
      # up while anything still needs it (a turn, queued input, a continue
      # offer, another UI, reminders), and the line says which.
      # @return [Symbol] :detach
      def exit_worker
        detach(exit_line(@client.request_exit(client_id: @client_id)))
      rescue SystemCallError, IOError => e
        detach(exit_failed_line(e.message))
      end

      # /exit --delete: the worker exits as for /exit, then the session is
      # deleted. When the worker stays up (another UI, queued input, ...),
      # nothing is deleted.
      def exit_and_delete
        reply = @client.request_exit(client_id: @client_id, delete: true)
        id = @client.session_id
        unless reply.status == 200
          line = exit_line(reply)
          return detach(line.sub("Detached; the session keeps running", "Detached; not deleted: the session keeps running")) if reply.status == 409

          return detach("#{line} Not deleted.")
        end
        # An empty session: the worker deletes it as it leaves.
        return detach(EMPTY_EXIT) if discards?(reply)

        @delete_session.call(id)
        detach("Detached; deleted session #{id}.")
      rescue SystemCallError, IOError => e
        detach("#{exit_failed_line(e.message)} Not deleted.")
      rescue SessionManager::DeleteRefused, SessionManager::OwnedByTUI, ArgumentError => e
        detach("Detached; the worker is stopping, but session #{id} was not deleted (#{e.message}): chi sessions delete #{id}")
      end

      # /archive during a turn (D2): it waits for the turn's end and the
      # commands queued behind it (#archive_due?), then runs.
      # @return [nil]
      def archive_after_turn
        @archive_after_turn = true
        @screen.commit("(archives after this turn)")
        nil
      end

      def archive_due? = @archive_after_turn && !@running && @queued_ids.empty?

      # @return [Symbol] :detached
      def archive_now
        @archive_after_turn = false
        exit_and_archive
        :detached
      end

      # /archive: the worker is asked to exit as for /exit, then the session
      # is archived. A worker staying up for another UI (or reminders) is
      # stopped by the archive, as the web's archive stops it; a turn
      # running, a queued prompt or an open continue offer refuses it
      # (SessionManager.archive_session). An empty session: the worker
      # deletes it as it leaves.
      def exit_and_archive
        reply = @client.request_exit(client_id: @client_id)
        id = @client.session_id
        return detach(EMPTY_EXIT) if reply.status == 200 && discards?(reply)
        return detach("#{exit_line(reply)} Not archived.") unless [200, 409].include?(reply.status)

        result = @archive_session.call(id)
        return detach("Detached; the session was empty, so it is discarded.") if result[:discarded].include?(id)

        detach("Detached; archived session #{id}. chi sessions list --archived finds it.")
      rescue SystemCallError, IOError => e
        detach("#{exit_failed_line(e.message)} Not archived.")
      rescue SessionManager::ArchiveRefused, SessionManager::OwnedByTUI, ArgumentError => e
        detach("Detached; session #{id} was not archived (#{e.message}). Re-attach with: chi --attach #{id}")
      end

      def exit_line(reply)
        id = @client.session_id
        error = reply.json&.fetch("error", nil)
        case reply.status
        when 200
          return EMPTY_EXIT if discards?(reply)

          "Detached; the session's worker is stopping. Resume with: chi --resume #{id}"
        when 409
          reason = reply.json&.fetch("reason", nil).to_s
          "Detached; the session keeps running (#{held_words(reason, reply.json&.fetch("tasks", nil))}). " \
            "Re-attach with: chi --attach #{id}"
        when 0 then exit_failed_line("no reply")
        when 408 then exit_failed_line(LATE)
        else
          # A worker from before the route answers the Bridge's plain 404.
          return "Detached; this worker runs an older chi and can't be stopped from here: chi sessions stop #{id}" if error == "not_found"

          exit_failed_line([reply.status, reply.json&.fetch("detail", nil) || error].compact.join(" "))
        end
      end

      # Why the worker stayed up; the background tasks it waits for by
      # their short id and command (a finish wake's, D3), and how to stop one.
      def held_words(reason, tasks)
        words = HELD_REASONS.fetch(reason, reason)
        listed = Array(tasks).filter_map { |t| "#{Tools::TaskRecord.short_id(t["id"])} (#{t["command"]})" if t.is_a?(Hash) }
        listed.empty? ? words : "#{words}: #{listed.join(", ")}; #{TASK_STOP_HINT}"
      end

      # An older worker leaves the field out.
      def discards?(reply) = reply.json&.fetch("discard", nil) == true

      def exit_failed_line(why)
        "Detached (could not ask the worker to stop: #{why}). Re-attach with: chi --attach #{@client.session_id}"
      end

      # The worker says what became of it (:continue_resolved); an invalid
      # answer gets its error and the offer stays.
      def answer_continue(text)
        echo_answer(text) if TurnFlow.continue_decision(text).first == :invalid
        @continue_answer = text.empty? ? "yes" : text
        send_command(continue_line(text))
        nil
      end

      # A bare answer at the continue prompt, as the REPL reads it (an empty
      # one is yes).
      def continue_line(text)
        text.empty? ? SessionCommands::CONTINUE_COMMAND : "#{SessionCommands::CONTINUE_COMMAND} #{text}"
      end

      # The worker runs it and every UI renders its :command_ran, this one
      # too, so nothing waits here.
      def send_command(line)
        reply = @client.post_command(line: line, client_id: client_id_for(line))
        if reply.status == 202
          # Input from a pipe ends once its output is in (#command_ran).
          command_id = reply.json&.fetch("command_id", nil)
          @open_ids << command_id if command_id && @wait_at_eof
          return
        end
        return @screen.commit(stale_worker("run commands")) if reply.status == 404

        name = older_worker_command(reply, line)
        return @screen.commit(stale_worker("run #{name}")) if name
        return @screen.commit("could not run the command (#{LATE})") if too_late?(reply)

        detail = reply.json&.fetch("detail", nil) || reply.json&.fetch("error", nil)
        @screen.commit("could not run the command (#{[reply.status, detail].compact.join(" ")})")
      rescue SystemCallError, IOError => e
        @screen.commit("could not run the command (#{worker_down(e)})")
      end

      # A request the Bridge read after its deadline and dropped
      # (BridgeClient::DEADLINE_SHARE): it didn't go through.
      def too_late?(reply) = reply.status == 408 && reply.json&.fetch("error", nil) == "deadline_passed"

      # Why a Bridge request raised, for the line that says what didn't go
      # through: a stopped (or wedged) worker times out, a gone one refuses.
      def worker_down(error)
        head, detail = error.message.split(" - ", 2)
        return "worker not answering: #{(detail || head).sub(/\Abridge \S+: /, "")}" if error.is_a?(Errno::ETIMEDOUT)

        "worker unreachable: #{head.downcase}"
      end

      QUEUED_NOTE = "(queued: runs after this turn)"
      QUEUE_RUNS_NOW = "(the turn had ended: runs as the next turn)"
      # /queue to a worker from before queueing, which would steer it.
      QUEUE_NEEDS_NEWER_WORKER = "(/queue needs a newer worker: restart it with chi sessions restart, then send again)"
      UNQUEUE_NEEDS_NEWER_WORKER = "(/unqueue needs a newer worker: restart it with chi sessions restart)"
      NOTHING_QUEUED = "(nothing queued: /queue TEXT queues a message for after the running turn)"
      UNQUEUE_REFUSED = { "already_started" => "(not removed: it already started)",
                          "unknown_enqueued_id" => "(not removed: it is already gone)",
                          "not_queued" => "(not removed: it goes in at the next step)" }.freeze

      # /unqueue: take back the newest prompt this run queued for after the
      # turn, before it runs (POST turn/dequeue). Its :turn_dequeued comes
      # to every UI; here the reply says what became of it. A worker whose
      # sidecar lacks "unqueue" is not asked.
      def unqueue_newest
        return @screen.commit(UNQUEUE_NEEDS_NEWER_WORKER) unless worker_unqueues?

        id = @my_queued.last
        return @screen.commit(NOTHING_QUEUED) unless id

        reply = @client.dequeue(enqueued_id: id, client_id: @client_id)
        error = reply.json&.fetch("error", nil)
        return @screen.commit(UNQUEUE_NEEDS_NEWER_WORKER) if reply.status == 404 && error == "not_found"

        # Removed, started or gone: no longer this run's to take back.
        @my_queued.delete(id) if [200, 404, 409].include?(reply.status)
        return unqueued(reply.json&.fetch("prompt", nil).to_s) if reply.status == 200

        @screen.commit(UNQUEUE_REFUSED[error] || "could not remove the queued message (#{[reply.status, error].compact.join(" ")})")
      rescue SystemCallError, IOError => e
        @screen.commit("could not remove the queued message (#{worker_down(e)})")
      end

      # The removal's line, and its text back in the input to change and
      # send again (as a failed turn's prompt comes back, #restore_prompt):
      # not over typed text, and not for lines from a pipe. Its images are
      # not put back.
      def unqueued(prompt)
        @screen.commit("removed: #{first_line_clip(prompt)}")
        return if @wait_at_eof || prompt.strip.empty?

        @screen.commit("(the removed message is in the input history: ↑)") unless @reader&.prefill(prompt)
      end

      def first_line_clip(text, max = 60)
        line = text.to_s.strip.lines.first.to_s.strip
        line.length > max ? "#{line[0, max]}…" : line
      end

      # Whether the attached worker takes queued messages back (its sidecar
      # names SessionInbox::UNQUEUE_FEATURE). No sidecar to read: true, its Bridge
      # answers (an older one's 404 not_found says so).
      def worker_unqueues?
        sidecar = WorkerSidecar.read(Session.session_dir(@client.session_id, state_dir: @state_dir))
        sidecar.nil? || sidecar.features.include?(SessionInbox::UNQUEUE_FEATURE)
      end

      # A command queued for after the running turn (command_queued with
      # waits): its line now (another client's) and a note; its command_ran
      # has no line again (queued: true).
      def command_waits(event)
        @queued_ids << event[:command_id]
        if own?(event[:client_id])
          first = event[:command_id] == @first_command_id
          return @screen.commit(first ? first_command_queued : QUEUED_NOTE)
        end

        @screen.commit("#{prompt_line(event[:client_id], event[:line])} #{QUEUED_NOTE}")
      end

      def first_command_queued
        "(#{first_command_flag} queued: applies after the running turn)"
      end

      def command_ran(event)
        @open_ids.delete(event[:command_id])
        @queued_ids.delete(event[:command_id])
        unless own?(event[:client_id]) || event[:anytime] || event[:card] || event[:queued]
          @screen.commit(prompt_line(event[:client_id], event[:line]))
        end
        output = event[:output].to_s
        if output.empty?
          nil
        elsif %w[busy dropped].include?(event[:status]) || PromptHistory.shell_line?(event[:line])
          @screen.commit(output)
          put_back_busy_command(event) if event[:status] == "busy"
        else
          @screen.commit("#{paint("model>", 36)} #{output}")
        end
        prefill_confirm(event)
        # /title from any client: the row's title follows.
        @status.update(title: event[:title]) if Array(event[:changed]).include?("title")
        return unless event[:model_name]

        # After the output, so the status row changes with the line saying why.
        served = @status[:model] == event[:model_name] ? @status[:served] : nil
        @status.update(model: event[:model_name], default_model: default_model_name, served: served)
      end

      # Our change that asks first (CacheConfirm) puts its --yes line in the
      # input: Enter applies it. Another client's question is its own.
      def prefill_confirm(event)
        return unless own?(event[:client_id])

        confirm = event[:confirm]
        line = confirm.is_a?(Hash) ? confirm[:line] || confirm["line"] : nil
        @reader&.prefill(line.to_s) if line
      end

      # Our command the worker couldn't run yet goes back into the prompt, for
      # Enter once the turn ends (not the launch's --model: that ends the launch).
      def put_back_busy_command(event)
        return unless own?(event[:client_id]) && event[:command_id] != @first_command_id

        @screen.commit("(the command is in the input history: ↑)") unless @reader&.prefill(event[:line].to_s)
      end

      def offer_continue(event)
        @continue_offer = { context: event[:context], no_interrupt: event[:no_interrupt] }
        sync_prompt
        sync_continue_slot
      end

      CONTINUE_DECISIONS = { "resume" => "yes", "abort" => "no", "abort_with_reason" => "no, with a reason" }.freeze

      # The offer's choices go; one line says what became of it. Another
      # UI's answer shows as its command line (web> /continue yes) instead.
      def continue_resolved(event)
        @continue_offer = nil
        # Asked as the step-limit question: its line says what became of it.
        asked = @offer_asked
        @offer_asked = false
        sync_continue_slot
        who = client_label(event[:client_id], "another UI")
        outcome = if event[:decision] == "dropped"
                    "(dropped: #{own?(event[:client_id]) ? "you" : who} sent a new prompt)"
                  elsif own?(event[:client_id])
                    @continue_answer || CONTINUE_DECISIONS.fetch(event[:decision].to_s, event[:decision].to_s)
                  end
        @continue_answer = nil
        @screen.commit(QuestionSlot.continue_summary(outcome, paint: method(:paint))) if outcome && !asked
        # Back to the > prompt: with the text a question set aside meanwhile
        # (#close_question), else what the ? read holds.
        set_aside = @set_aside
        @set_aside = nil
        set_aside ? sync_prompt(keep_text: false, prefill: set_aside) : sync_prompt
      end

      # The notes slot shows the offer's choices while it waits (a question
      # has the slot while it is open).
      def sync_continue_slot
        return if @question || @offer_asked

        if @continue_offer
          @screen.set_slot(:notes, QuestionSlot.continue_offer(@continue_offer[:context], paint: method(:paint)))
        else
          @screen.clear_slot(:notes)
        end
      end

      # What a prompt's 202 says became of it, or nil when there is nothing
      # to say: the dim line both TUIs print for a delivery. A plain line
      # for a running turn goes in at its next step; a cut's outcome comes
      # from the ack (the worker knows whether cutting is on for its model);
      # a queued one waits for the turn's end (the ack says queue).
      # An idle session's prompt simply runs, and a prompt with images runs
      # as its own next turn (never merging mid-turn), so nothing is said.
      # @param ack [Hash, nil] the Bridge's 202 body
      # @param delivery [String, nil] what was asked for
      # @return [String, nil]
      def sent_note(ack, delivery: nil, images: [], running: false)
        return nil unless running && ack.is_a?(Hash)
        # The Bridge acks queue only while a turn ran at enqueue; a /queue
        # it acks next_step found the turn over: it is the next turn.
        return QUEUED_NOTE if ack["delivery"] == Delivery::QUEUE
        return QUEUE_RUNS_NOW if Delivery.queue?(delivery)
        return nil unless images.empty?

        return NEXT_STEP_NOTE unless delivery == Delivery::CUT

        steer_cut_note(ack["cut"].to_s.to_sym, ack["cut_after"])
      end

      # The client id +line+ goes with, as a command (#send_command) or as a
      # message the Bridge may run as one (#send_prompt: /cut and /queue
      # text). A parent agent's /continue yes and /parent-answers go as chi
      # answer's: the worker holds the first to guardrails.parent_answers and
      # never takes the second as a user's loosening. The command is the
      # registry's own match (the worker's), not a pattern of ours.
      def client_id_for(line)
        return @client_id unless @as_parent
        return ClientId::CLI_ANSWER if TurnFlow.continue_yes?(line)
        return ClientId::CLI_ANSWER if command_registry.lookup(line)&.id == :parent_answers

        @client_id
      end

      def send_prompt(text, delivery: nil)
        persist_recent_history(text)
        images = attach_images(text)
        return own_prompt_failed if images.nil?

        running = @running
        options = { prompt: text, client_id: client_id_for(text) }
        options[:no_interrupt] = true if @no_interrupt
        options[:images] = images unless images.empty?
        options[:delivery] = delivery if delivery
        reply = @client.post_turn(**options)
        if reply.status == 202
          enqueued_id = reply.json&.fetch("enqueued_id", nil)
          @sent_ids << enqueued_id if enqueued_id
          @open_ids << enqueued_id if enqueued_id && @wait_at_eof
          @my_queued << enqueued_id if enqueued_id && reply.json&.fetch("delivery", nil) == Delivery::QUEUE
          note = sent_note(reply.json, delivery: delivery, images: images, running: running)
          @screen.commit(note) if note
          return
        end

        own_prompt_failed

        detail = reply.json&.fetch("error", nil)
        # Read after its deadline and dropped (BridgeClient::DEADLINE_SHARE).
        return @screen.commit("could not send the prompt (#{LATE})") if detail == "deadline_passed"
        # A worker from 0.51 to 0.63 refuses a queue (nothing was sent).
        return @screen.commit(QUEUE_NEEDS_NEWER_WORKER) if detail == "delivery_unavailable"

        @screen.commit("could not send the prompt (#{[reply.status, detail].compact.join(" ")})")
      rescue SystemCallError, IOError => e
        own_prompt_failed
        @screen.commit("could not send the prompt (#{worker_down(e)})")
      end

      # Whether the input's end must wait: the -p prompt isn't sent yet, a
      # prompt this run sent hasn't had its turn, or its turn's after_turn
      # hooks still run (their notices, source-links' sources:, come next).
      def own_turns_pending? = !@first_prompt.to_s.strip.empty? || !@open_ids.empty? || @display_pending == true

      # A turn ended: this run's prompt (and ours merged into it) had its turn.
      def own_turn_ended(event)
        return unless @wait_at_eof

        id = (event[:origin] || {})[:enqueued_id]
        ours = @open_ids.include?(id) || !@merged_ids.empty?
        @own_failed = true if ours && event[:type] == :turn_failed
        @own_empty = true if ours && event[:type] == :turn_completed && event.dig(:turn_summary, :empty_answer)
        # The worker sends answer_display once its after_turn hooks ran.
        @display_pending = true if ours && event[:type] == :turn_completed && event[:display_pending]
        @open_ids.delete(id)
        @open_ids.subtract(@merged_ids)
        @merged_ids.clear
      end

      # Ours merged into the running turn: they end with it.
      def merged_own_prompts(event)
        Array(event[:origins]).each do |origin|
          id = origin[:enqueued_id]
          @merged_ids << id if own?(origin[:client_id]) && @open_ids.include?(id)
        end
        nil
      end

      def own_prompt_failed
        @own_failed = true if @wait_at_eof
        nil
      end

      # The input ended and nothing of ours is left to wait for.
      def end_of_input
        detach("Detached; the session keeps running. Re-attach with: chi --attach #{@client.session_id}") if @input_ended
        return :turn_failed if @own_failed

        @own_empty ? :empty_answer : :detached
      end

      def unanswered_question(pending)
        @unanswered = pending
        detach("A question waits for an answer: chi --attach #{@client.session_id}")
        :unanswered
      end

      # The prompt's `@path` images, stored in the session's images/ here
      # (this machine, the worker's state dir) and sent as refs: the Bridge
      # never takes a path. nil (after a line saying why) when one can't be.
      def attach_images(text)
        paths = ImageInput.extract(text)
        return [] if paths.empty?

        session_dir = Session.session_dir(@client.session_id, state_dir: @state_dir)
        paths.map do |image|
          ref = ImageStore.ingest(session_dir, path: image[:path])
          { file: ref[:file], name: ref[:name] }
        end
      rescue ImageStore::Error => e
        @screen.commit("could not attach the image: #{e.message}")
        nil
      end

      def show_stats
        # A worker from before the stats route answers only /state.
        metrics = @client.get_json("stats")&.dig("metrics") || @client.get_json("state")&.dig("session_state_snapshot", "metrics")
        @screen.commit(metrics ? format_session_metrics(EventRenderer.deep_symbolize_keys(metrics)) : "(no metrics: the worker did not answer)")
      end

      # One read on the reader thread: the REPL's multiline read with Tab
      # completion at the main prompt, a plain line for a question's choice
      # or the continue offer's answer.
      def read_input_line(prompt, prefill)
        return $stdin.gets&.chomp unless $stdin.tty?
        # A question's answer leaves only its summary line.
        return RelineSeam.without_echo { Reline.readline(prompt, true) } if @question || @continue_offer

        queue_input_prefill(prefill) if prefill
        read_prompt_line(prompt)
      end

      # The attached TUI's commands, for Tab.
      def slash_commands = command_registry.completions(:attached)

      # The session's commands as its worker's snapshot names them (its
      # plugins' too); the built-ins until one arrives, or from a worker too
      # old to name them. An unknown /foo is a prompt, as in the REPL.
      def command_registry = @command_registry || SessionCommands.builtin_registry

      # The saved recap, and a new one asked for at once (it arrives as
      # :recap_ready), with the REPL's words.
      def show_recap
        reply = @client.request_recap
        answer = reply.status == 200 ? reply.json : nil
        return @screen.commit("(no recap: the worker did not answer)") unless answer

        @screen.commit(recap_command_text(enabled: answer["enabled"], saved: answer["saved"],
                                          request: answer["request"], min_user_turns: answer["min_user_turns"]))
      rescue SystemCallError, IOError
        @screen.commit("(no recap: the worker did not answer)")
      end

      def prompt_text
        return paint(QUESTION_PROMPT, 33) if @question || @continue_offer

        paint(PROMPT, 92)
      end

      # Switch the open prompt to ? for the answer and show the choices in
      # the notes slot, fitted to the terminal. Once the question closes,
      # one line (the question and what became of it) stays.
      def ask(pending)
        return unless pending

        @view.finish_thinking_spinner
        # What was typed at the prompt waits for the question to close.
        # Not over text already set aside (a question that closed while a
        # continue offer waits): the ? read holds an answer then, if anything.
        @set_aside = @reader&.typed_text.to_s.then { |typed| typed.empty? ? nil : typed } unless @question || @set_aside
        @question = QuestionPrompt.new(pending)
        @question_pending = pending
        # The step-limit question stands for the continue offer's own slot
        # until the offer is resolved.
        @offer_asked = true if @question.continue?
        # An edit's diff goes above, into the scrollback, once per question
        # (a join gets it from the snapshot and may get the event too).
        unless @previewed_id == @question.id
          @previewed_id = @question.id
          preview = @question.preview_lines(paint: method(:paint))
          @screen.commit(preview.join("\n")) unless preview.empty?
        end
        # The prompt first, so the choices never show under the typed text.
        sync_prompt(keep_text: false)
        @screen.set_slot(:notes, @question.slot(paint: method(:paint)))
      end

      def answer_question(text)
        # Enter alone at the step-limit question continues (it can't be
        # dismissed), as at the continue prompt.
        return dismiss_question if text.empty? && !@question.continue?

        answer = @question.parse(text)
        @screen.commit(answer.note) if answer.note
        unless answer.ok?
          echo_answer(text)
          return @screen.commit(answer.error)
        end

        parent = @as_parent ? { client_id: ClientId::CLI_ANSWER } : {}
        reply = @client.answer(id: @question.id, selected: answer.selected, freeform: answer.freeform, **parent)
        case reply.status
        when 200
          @answered_ids << @question.id
          close_question(@question.answer_text(answer))
        when 409 then close_question("(already answered in another UI)")
        when 408 then @screen.commit("could not answer (#{LATE})")
        else
          detail = reply.json&.fetch("detail", nil) || reply.json&.fetch("error", nil)
          @screen.commit("could not answer (#{[reply.status, detail].compact.join(" ")})")
        end
        nil
      rescue SystemCallError, IOError => e
        @screen.commit("could not answer (#{worker_down(e)})")
        nil
      end

      # An empty answer dismisses the question, as in the REPL: the tool
      # returns unanswered (an approval: denied) and the turn goes on. The
      # :question_cancelled every UI gets finds it already closed here.
      def dismiss_question
        reply = @client.dismiss_question(id: @question.id)
        case reply.status
        when 200 then close_question(@question.approval? ? "(denied)" : "(cancelled)")
        when 409 then close_question("(question already closed in another UI)")
        when 404 then @screen.commit("#{stale_worker("dismiss questions")}; Ctrl-C cancels the turn")
        when 408 then @screen.commit("could not dismiss the question (#{LATE}); Ctrl-C cancels the turn")
        else
          # The question stays open (after a 404 too).
          detail = reply.json&.fetch("error", nil)
          @screen.commit("could not dismiss the question (#{[reply.status, detail].compact.join(" ")}); Ctrl-C cancels the turn")
        end
        nil
      rescue SystemCallError, IOError => e
        @screen.commit("could not dismiss the question (#{worker_down(e)}); Ctrl-C cancels the turn")
        nil
      end

      # A line read at ? that isn't a (valid) answer: the read left no echo,
      # so it shows above what it got.
      def echo_answer(text) = @screen.commit("#{paint(QUESTION_PROMPT, 33)}#{text}")

      # The name of this chi's own command +line+ when the worker answered it
      # unknown_command (it runs an older chi without it), else nil.
      def older_worker_command(reply, line)
        return nil unless reply.status == 400 && reply.json&.fetch("error", nil) == "unknown_command"

        SessionCommands.builtin_name(line)
      end

      def stale_worker(cant)
        BridgeClient.stale_worker_message(@client.session_id, cant: cant)
      end

      # The worker rolled a failed turn back and handed its prompt back: ours
      # goes back into the input, as the REPL restores it for a retry.
      def restore_prompt(event)
        origin = event[:origin] || {}
        return unless own?(origin[:client_id]) && @sent_ids.include?(origin[:enqueued_id])
        # Lines from a pipe: nobody to retry it (the REPL's rule).
        return if @wait_at_eof

        if @reader&.prefill(event[:prompt].to_s)
          @screen.commit(turn_end_hint("prompt restored for retry"))
        else
          @screen.commit(turn_end_hint("the failed prompt is in the input history (↑)"))
        end
      end

      def question_relayed(event)
        return unless @question && @question.id == event[:id].to_s

        @question.relayed_to = event[:relayed_to]
        @screen.set_slot(:notes, @question.slot(paint: method(:paint)))
      end

      def question_answered(event)
        return unless @question
        return close_question(nil) if @answered_ids.include?(event[:id])

        answer = event[:answer] || {}
        picked = [*Array(answer[:selected]), answer[:freeform]].compact.join(", ")
        close_question("#{picked.empty? ? "(answered)" : picked} (in another UI)")
      end

      # @param outcome [String, nil] what became of it, for the line that
      #   stays in the scrollback (nil: none, it was closed already)
      def close_question(outcome)
        @screen.clear_slot(:notes)
        @screen.commit(@question.summary(outcome, paint: method(:paint))) if outcome
        @question = nil
        # A continue offer still waiting keeps the ? prompt (the step-limit
        # question closes before its offer resolves): the text set aside
        # waits for the > prompt (#continue_resolved).
        return sync_continue_slot if @continue_offer

        set_aside = @set_aside
        @set_aside = nil
        sync_prompt(keep_text: false, prefill: set_aside)
      end

      # Restart the open read when its prompt no longer fits (a question or a
      # continue offer opened or closed), first erasing the prompt Reline drew.
      # What is typed there goes along (+keep_text+), or +prefill+ goes in.
      def sync_prompt(keep_text: true, prefill: nil)
        return unless @reader

        @screen.synchronize do
          next if @reader.current == prompt_text

          @screen.clear_slot(:editor)
          @reader.reprompt(keep_text: keep_text, prefill: prefill)
        end
      end

      # Ctrl-C cancels the running turn (whoever started it). At an idle
      # prompt it clears the line; on an empty one it says how to detach, and
      # a second press within DETACH_WINDOW detaches (D4).
      # @param pressed [Hash, nil] {text:, at:} from the read the press ended
      #   (nil: pressed with no read open)
      # @return [Symbol, nil] :detach
      def interrupt(pressed = nil)
        typed = pressed&.fetch(:text, nil).to_s
        if @running
          begin
            @client.cancel(reason: "ctrl_c")
          rescue SystemCallError, IOError => e
            @screen.commit("could not cancel the turn (#{worker_down(e)})")
          end
          return nil
        end
        unless typed.strip.empty?
          @last_idle_interrupt_at = nil
          return nil
        end

        now = pressed&.fetch(:at, nil) || @clock.call
        return submit(nil) if @last_idle_interrupt_at && now - @last_idle_interrupt_at <= DETACH_WINDOW

        @last_idle_interrupt_at = now
        @screen.commit(DETACH_HINT)
        nil
      end

      # On the reader thread, from Reline's Ctrl-C: what the line held, and
      # when. During a turn the press goes to the loop (it cancels the turn)
      # and the read goes on with the typed text still in it, as in the REPL;
      # otherwise it is noted for the Interrupt the LineReader queues next.
      # @return [Boolean] true: handled, the read goes on; false: Reline ends
      #   the read with Interrupt
      def note_interrupted_line
        pressed = { text: Reline.line_buffer.to_s, at: @clock.call }
        if @running
          @queue << [:interrupt, pressed]
          return true
        end

        Thread.current[:interrupted_line] = pressed
        false
      rescue StandardError
        false
      end

      def render_snapshot(snapshot, reset:)
        @view.finish_thinking_spinner
        queued = Array(snapshot[:queued])
        known_queued = @my_queued.to_set
        @my_queued = queued.filter_map do |entry|
          id = entry[:enqueued_id]
          id if id && (known_queued.include?(id) || (entry.key?(:client_id) && own?(entry[:client_id])))
        end
        # A new worker's first snapshot is the session as it now stands.
        moved = @worker_changed
        reset ||= moved
        @worker_changed = false
        if @attached
          @screen.commit("(resynced with the session)") if reset && !moved
          @screen.commit(paint(VersionLines.restarted(snapshot[:chi_version]), 2)) if moved
        else
          @attached = true
          # The recap first: what the session was about, then where it stopped.
          saved = snapshot[:saved_recap]
          @screen.commit(recap_block(saved[:text], turns_since: saved[:turns_since])) if saved && !saved[:text].to_s.strip.empty?
          render_join_header(Array(snapshot[:messages]))
          @screen.commit("guardrails> #{snapshot[:guardrail_warning]}") if snapshot[:guardrail_warning]
          @screen.commit("plugins> #{snapshot[:plugin_warning]}") if snapshot[:plugin_warning]
          version_line = VersionLines.at_attach(worker: snapshot[:chi_version], installed: installed_version,
                                                session_id: @client.session_id)
          @screen.commit(paint(version_line, 2)) if version_line
        end
        if snapshot[:commands]
          @command_registry = Commands::Registry.from_listing(snapshot[:commands], base: SessionCommands.builtin_registry)
        end
        Array(snapshot[:init_tasks]).each { |task| @view.init_started(task) }
        cards = Array(snapshot[:cards])
        render_snapshot_cards(cards.reject { |card| card[:current] }, joining: !reset)
        offer = snapshot[:continue_offer]
        had_offer = !@continue_offer.nil?
        @continue_offer = offer && { context: offer[:context], no_interrupt: offer[:no_interrupt] }
        if had_offer != !@continue_offer.nil?
          sync_prompt
          sync_continue_slot
        end
        render_current_turn(snapshot[:current_turn])
        # A question between turns (the step-limit one) belongs to no turn.
        ask(snapshot[:pending_question]) if snapshot[:current_turn].nil? && snapshot[:pending_question]
        render_snapshot_cards(cards.select { |card| card[:current] }, joining: !reset)
        queued.each do |entry|
          next if own?(entry[:client_id])

          @shown_enqueued << entry[:enqueued_id]
          @screen.commit("queued #{prompt_line(entry[:client_id], entry[:prompt])}")
        end
        # Commands waiting for the turn's end (their command_ran prints no
        # line); a resync prints only the ones it hadn't shown.
        shown = @queued_ids.dup
        @queued_ids.clear
        Array(snapshot[:queued_commands]).each do |entry|
          @queued_ids << entry[:command_id]
          @screen.commit("queued #{prompt_line(entry[:client_id], entry[:line])}") unless shown.include?(entry[:command_id])
        end
        return send_first_command unless @first_commands.empty?

        send_first_prompt
        nil
      end

      # --model (or --llm-context, --thinking) on a resumed session: run it in its
      # worker before the first prompt goes; its :command_ran decides
      # (#first_command_ran), and sends the next one.
      # @return [Symbol, nil] :failed when the worker didn't take it
      def send_first_command
        line = @first_commands.shift
        @first_command_line = line
        reply = @client.post_command(line: line, client_id: @client_id)
        if reply.status == 202
          @first_command_id = reply.json&.fetch("command_id", nil)
          return nil if @first_command_id
        end

        why =
          if reply.status == 404 then stale_worker("run commands")
          elsif (name = older_worker_command(reply, line)) then stale_worker("run #{name}")
          elsif too_late?(reply) then LATE
          else "the worker answered #{reply.status}"
          end
        @screen.commit("#{first_command_failed}: #{why}")
        :failed
      rescue SystemCallError, IOError => e
        @screen.commit("#{first_command_failed}: #{worker_down(e)}")
        :failed
      end

      # @return [Symbol, nil] :failed unless the command went through
      def first_command_ran(event)
        @first_command_id = nil
        if event[:status] == "ok"
          return send_first_command unless @first_commands.empty?

          send_first_prompt
          return nil
        end

        @screen.commit("#{first_command_failed}: #{event[:output]}")
        :failed
      end

      def first_command_failed
        flag = first_command_flag
        flag == "--model" ? "could not switch to the --model" : "could not set the #{flag}"
      end

      # The launch flag the first command came from: "/model X" is --model,
      # "/llm-context …" --llm-context, "/thinking X --yes" --thinking.
      def first_command_flag
        "--#{@first_command_line.to_s[%r{\A/([\w-]+)}, 1]}"
      end

      # After the join, so it lands below what the session already had. Our
      # own prompts are never echoed from events (a typed one stays on screen),
      # so it is shown here as if typed.
      def send_first_prompt
        text = @first_prompt.to_s.strip
        @first_prompt = nil
        return if text.empty?

        @screen.commit("#{paint(PROMPT, 92)}#{text}")
        # As if typed: a session command runs as the command; a typo of one
        # gets the hint, not a turn.
        if command_registry.command?(text)
          send_command(text)
        elsif (hint = command_registry.unknown_command_hint(text))
          @screen.commit(hint)
        else
          send_prompt(text)
        end
      end

      def render_join_header(messages)
        exchange = messages.select { |m| %w[user model assistant].include?(m[:role].to_s) }
        # The id stays findable: the detach line and chi sessions list show it.
        Log.session_id = @client.session_id
        Log.info(:attached, "joined", session: @client.session_id, messages: exchange.size,
                                      notes: messages.count { |m| ContextNote.note?(m) })
        last_user = exchange.rindex { |m| Steer.prompt?(m) }
        render_join_notes(messages)
        return unless last_user

        @screen.commit(join_prompt_line(exchange[last_user]))
        # An image-only turn's text names its images already.
        unless ImageRef.placeholder_only?(exchange[last_user][:content])
          Array(exchange[last_user][:images]).each { |ref| @screen.commit(format_image_line(ref)) }
        end
        from = messages.index { |m| m.equal?(exchange[last_user]) }
        render_join_steps(messages, from, durations: join_tool_records(exchange[last_user]))
        failed = join_failed_record(exchange[last_user])
        # A turn that ended with no answer: its notice, as live.
        empty = messages.drop(from + 1).filter_map { |m| TurnNote.empty_answer(m) }.last
        if empty
          @screen.commit(format_empty_answer_line(empty[:retries] || empty["retries"], empty[:refusal] || empty["refusal"]))
        elsif failed
          # A failed turn whose steps stayed: the line the live view left,
          # and no step text as if it were the answer (the web keeps a
          # failed turn's texts as steps too).
          failure = failed["failure"]
          @screen.commit(@view.turn_failed_line(failure["summary"] || failure["message"], failed["duration_ms"]))
          @screen.commit(@view.turn_end_hint(ROLLBACK_HINT)) if failure["kept_steps"]
        else
          # The saved answer is raw: the latest keeps its thinking, and one may
          # be only a tool call.
          answer = exchange[(last_user + 1)..].reverse_each
                                             .map { |m| OutputFormatter.strip_markup(m[:content]) }
                                             .find { |text| !text.empty? }
          @screen.commit(last_lines(answer)) if answer
        end
        render_join_notes(messages, after_exchange: true)
      end

      # What the last exchange did, as the live turn drew it: each saved
      # call's tool row (action, params, status from its result, and its
      # duration from +durations+, the turn's saved tool records) and a
      # plugin's steer where it came. The step texts stay out, as live (the
      # ticker's).
      def render_join_steps(messages, from, durations: [])
        records = durations.dup
        messages.each_with_index.drop(from + 1).each do |m, i|
          if Steer.steer?(m)
            @screen.commit(format_steer_line(source: m[:source], text: m[:content]))
          elsif %w[model assistant].include?(m[:role].to_s)
            responses = messages.drop(i + 1).take_while { |r| r[:role].to_s == "tool_response" }
            Array(MessageParts.for_message(m, responses)&.dig(:tools)).each do |part|
              record = join_record(records, part)
              duration = record&.dig("duration_ms")
              @screen.commit(join_tool_line(part, duration_ms: duration.is_a?(Numeric) ? duration : nil,
                                                  saved_status: record&.dig("status")))
            end
          end
        end
      end

      # The prompt's turn's saved tool records (SessionMetrics, in this
      # machine's state dir, as #attach_images): none for a prompt with no
      # turn id (an older session) or a session with no analytics.
      def join_tool_records(prompt)
        SessionMetrics.saved_tool_records(Session.session_dir(@client.session_id, state_dir: @state_dir), prompt[:turn_id] || prompt["turn_id"])
      rescue Session::InvalidId
        []
      end

      # The turn's saved record when it failed with the fields its line is
      # made of (SessionMetrics#failure_fields), else nil: a completed,
      # canceled or older turn — or one saved before the failure field —
      # draws its answer as before.
      def join_failed_record(prompt)
        record = SessionMetrics.saved_turn_record(Session.session_dir(@client.session_id, state_dir: @state_dir),
                                                  prompt[:turn_id] || prompt["turn_id"])
        return nil unless record && record["status"] == "failed" && record["failure"].is_a?(Hash)

        failure = record["failure"]
        return nil if failure["summary"].to_s.empty? && failure["message"].to_s.empty?

        record
      rescue Session::InvalidId
        nil
      end

      # The saved record of +part+'s call (its duration and status): the
      # next record of its tool, in call order, consumed with the ones it
      # skipped. By tool and order, not by iteration: an empty retry spends
      # an iteration that left no message (as the web's timing.js
      # takeRecord). nil for a call that left none: it never finished, or a
      # worker before turn ids saved it.
      def join_record(records, part)
        return nil if part[:output].nil?

        at = records.index { |r| r["tool"].to_s == part[:tool].to_s }
        return nil unless at

        records.shift(at + 1).last
      end

      # A saved call's row; "no result" for a call the turn never answered
      # (it ended first). Its status is the saved record's, as live and the
      # web's reload (a guardrail's "blocked" is no error), else read from
      # its result.
      def join_tool_line(part, duration_ms: nil, saved_status: nil)
        output = part[:output]
        command = part.dig(:view, :truncated) ? nil : part.dig(:view, :command)
        status = if output.nil?
                   "no result"
                 elsif !saved_status.to_s.empty?
                   saved_status.to_s
                 else
                   ToolActivity.tool_activity_status(ToolActivity.saved_result_text(output), part[:tool],
                                                     command: command)
                 end
        activity = { action: part[:label] || ToolActivity.tool_activity_action(part[:tool]), tool: part[:tool],
                     params: part[:params], status: status,
                     description: ToolView.description_title(part[:view] || {}) }
        "#{format_tool_activity_line(activity, duration_ms: duration_ms)}" \
          "#{format_tool_image_suffix(part[:images])}#{format_tool_diff_suffix(part[:diff])}#{format_tool_cut_suffix(part[:output_truncated])}"
      end

      # The context notes that came since the last prompt (all of them in a
      # session with none), after the exchange the header shows.
      def render_join_notes(messages, after_exchange: false)
        last_user = messages.rindex { |m| Steer.prompt?(m) }
        return if after_exchange != !last_user.nil?

        messages[(last_user ? last_user + 1 : 0)..].select { |m| ContextNote.note?(m) }.each do |m|
          @screen.commit(context_note_line(ContextNote.label_of(m), ContextNote.text_of(m)))
        end
      end

      # The end of a long answer; the whole of it is in the session.
      def last_lines(text)
        lines = text.split("\n", -1)
        if lines.size > JOIN_ANSWER_LINES
          text = "(… #{lines.size - JOIN_ANSWER_LINES} earlier lines)\n#{lines.last(JOIN_ANSWER_LINES).join("\n")}"
        end
        return text if text.length <= JOIN_ANSWER_CHARS

        "(… earlier text)\n…#{text[-JOIN_ANSWER_CHARS..]}"
      end

      # The snapshot's cards and between-turns notices (Bridge CardStore):
      # on join the ones since the last turn (and the running turn's), as
      # the join header shows the last exchange; on a resync only cards not
      # shown here yet, and not the ones an earlier worker saved (a resync
      # onto a new worker: earlier turns, not news). A turn's own rows (notices, retries) are left out:
      # the running turn's come with its parts, and the join shows no older
      # turn's steps.
      def render_snapshot_cards(entries, joining:)
        entries.each do |entry|
          case entry[:type].to_s
          when "hook_notice"
            next if entry[:in_turn]

            @screen.commit(EventRenderer.hook_notice_line(entry)) if joining && entry[:turns_since].to_i.zero?
          when "card"
            next unless joining ? entry[:turns_since].to_i.zero? : !entry[:earlier] && !@renderer.card_shown?(entry[:id])

            @renderer.render_card(entry, updated: entry[:updated] == true)
          end
        end
      end

      def render_current_turn(turn)
        @running = !turn.nil?
        @joined_mid_turn = @running
        # A turn running at the join: the status row's steer hint.
        @status.update(running: @running)
        return unless turn

        continues = turn[:prompt].nil?
        unless continues && reminder_origin?(turn[:origin] || {})
          @screen.commit(prompt_line(turn.dig(:origin, :client_id), turn[:prompt] || continuing_text(turn[:origin] || {})))
        end
        tail = nil
        lane = :writing
        running_tool = nil
        Bridge::TurnAccumulator.replay_events(turn).each do |event|
          case event[:type]
          # A new step starts its line over, as live (a join during a hold).
          when :generation_started then tail = nil
                                        lane = :writing
          when :generation_chunk
            tail, lane = event[:thinking].to_s.empty? ? [event[:text], :writing] : [event[:thinking], :thinking]
          when :tool_call_started
            running_tool = event[:tool]
            @renderer.call(event)
          when :tool_call_completed
            running_tool = nil
            replay_tool_completed(event)
          when :merged_input then @screen.commit("input> #{event[:content]}")
          when :reminder_injected then @screen.commit(reminder_line(event[:reminders]))
          # The turn's start (its images), a plugin's steer, and its rows (a
          # hook's notice, a retry's line), as they were drawn live.
          # Questions are left out: the pending one is asked after the
          # replay, answered ones showed no line.
          when :turn_started then @renderer.call(without_named_images(event, turn[:prompt]))
          when :pending_input_merged, :hook_notice, :empty_answer_retry, :steer_cut, :llm_context_edited
            @renderer.call(event)
          end
        end
        @view.resume(tail: tail, lane: lane, tool: running_tool, parts: turn[:parts])
        ask(turn[:pending_question]) if turn[:pending_question]
      end

      # A finished tool call of the joined turn: the live row (action,
      # duration). A snapshot from an older worker has no action: its row
      # names the tool only.
      def replay_tool_completed(event)
        return @renderer.call({ duration_ms: nil }.merge(event)) if event.dig(:activity, :action)

        activity = EventRenderer.described(event) || {}
        @screen.commit(snapshot_tool_line({ tool: event[:tool], params: activity[:params], status: activity[:status],
                                            description: activity[:description], output_truncated: event[:output_truncated],
                                            images: event[:images], diff: event[:diff] }))
      end

      def show_enqueued(event)
        return if own?(event[:client_id])

        @shown_enqueued << event[:enqueued_id]
        line = prompt_line(event[:client_id], event[:prompt])
        @screen.commit(event[:delivery] == Delivery::QUEUE ? "#{line} #{QUEUED_NOTE}" : line)
      end

      # A queued prompt was taken back before it ran (the web's ×, /unqueue
      # in a terminal). One of this run's (wait_at_eof) will have no turn:
      # it ends the wait, as a failed one does. Another client's shown
      # line says so.
      def turn_dequeued(event)
        id = event[:enqueued_id]
        @my_queued.delete(id)
        if @open_ids.delete?(id)
          if own?(event[:client_id])
            @own_empty = true
            @screen.commit("(removed before it ran)")
          else
            @own_failed = true
            @screen.commit("(your queued message was removed before it ran)")
          end
        elsif @shown_enqueued.delete?(id)
          @screen.commit("(a queued message was removed)")
        end
      end

      def start_turn(event)
        @running = true
        @joined_mid_turn = false
        origin = event[:origin] || {}
        @my_queued.delete(origin[:enqueued_id])
        if event[:prompt].nil?
          # A continue turn (after the offer's yes) has no prompt to show; a
          # reminder turn shows its reminders (:reminder_injected).
          # A turn run for delegate reports shows them as they merge; one
          # an attached context change started, its label (the note is above).
          @screen.commit(prompt_line(origin[:client_id], continuing_text(origin))) unless reminder_origin?(origin) || report_origin?(origin)
        elsif !(own?(origin[:client_id]) || @shown_enqueued.include?(origin[:enqueued_id]))
          @screen.commit(prompt_line(origin[:client_id], event[:prompt]))
        end
        # The own-send echo already names an image-only prompt; another
        # client's prompt line does too, here or at its enqueue.
        @renderer.call(without_named_images(event, event[:prompt]))
      end

      # The turn's start without its image lines when the shown prompt is
      # the image-only "[image: name]" placeholder: that line names them.
      def without_named_images(event, shown_prompt)
        ImageRef.placeholder_only?(shown_prompt) ? event.except(:images) : event
      end

      def complete_turn(event)
        # Tools from before the join were shown from the snapshot; the ones
        # after it streamed. Either way the summary must not list them again.
        if @joined_mid_turn && event[:turn_summary]
          event = event.merge(turn_summary: event[:turn_summary].merge(tool_activity: []))
        end
        @renderer.call(event)
        # The turn's summary carries its last context estimate.
        @status.update(context: @view.context_status) if @view.context_status
        @running = false
        @joined_mid_turn = false
        close_question("(the turn ended)") if @question
      end

      def end_turn
        @running = false
        @joined_mid_turn = false
        close_question("(the turn ended)") if @question
      end

      def own?(client_id) = !client_id.nil? && client_id == @client_id

      # The joining snapshot's session state: the worker's model and the
      # memories the session used.
      def take_session_state(state)
        @status.take_state(state, default_model: (default_model_name if state[:model_name]))
        refresh_children
      end

      # The status row's children segment: the delegates' counts, read from
      # their files here (ChildrenStatus.counts) at the join, when a turn
      # ends and when a report merges; the worker sends nothing for it.
      # Not read with status.line off; a failed read keeps the row.
      def refresh_children
        return unless @status.enabled?

        @status.update(children: @children_counts.call(@client.session_id))
      rescue StandardError => e
        Log.debug(:attached, "children_counts_failed", error: e.class.name)
      end

      # The config's default model, as the worker's /model names it.
      def default_model_name
        @default_model_name ||= ModelProfile.default_model_name
      end

      def reminder_origin?(origin) = origin[:client_id].to_s.start_with?(ClientId::SYSTEM_PREFIX)
      def report_origin?(origin) = ClientId.origin(origin[:client_id]) == "delegate_report"
      def context_origin?(origin) = ClientId.origin(origin[:client_id]) == "context"
      def task_origin?(origin) = ClientId.origin(origin[:client_id]) == "task"
      # A turn with no prompt: "(continuing)"; a context wake's or a task
      # finish wake's label alone.
      def continuing_text(origin) = context_origin?(origin) || task_origin?(origin) ? nil : "(continuing)"
    end
  end
end
