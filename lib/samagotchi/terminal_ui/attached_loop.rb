# frozen_string_literal: true

require_relative "../client_id"
require_relative "../bridge_secret"
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
require_relative "join_replay"
require_relative "own_turns"
require_relative "exit_lines"
require_relative "attached_loop/exit_commands"
require_relative "attached_loop/questions"
require_relative "attached_loop/queueing"
require_relative "attached_loop/composer"
require_relative "attached_loop/sending"
require_relative "reline_seam"
require_relative "version_lines"
require_relative "gap_clock"
require_relative "participant_commands"
require_relative "local_link"
require_relative "../bridge/turn_accumulator"
require_relative "../bridge_client"
require_relative "../delivery"
require_relative "../log"
require_relative "../context_note"
require_relative "../steer"
require_relative "../turn_origin"
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
      include ExitCommands
      include Questions
      include Queueing
      include Composer
      include Sending

      PROMPT = "> "
      # A second Ctrl-C at an empty idle prompt within this many seconds detaches.
      DETACH_WINDOW = 2.0
      DETACH_HINT = "Ctrl-D to detach, /exit stops the worker"
      attr_reader :client_id

      # @return [String, nil] the model the worker's turns run on, as the
      #   last snapshot or model change said (the status row's)
      def model_name = @status[:model]

      # @return [QuestionPrompt, nil] the question waiting for an answer
      attr_reader :question

      # @return [Hash, nil] the pending question (symbol keys) #run left
      #   waiting when it ended :unanswered
      attr_reader :unanswered

      # @param client [BridgeClient] the session's on this machine (a
      #   LocalLink is made of it and the keywords below), or nil with +link+
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
      # @param now [#call] the wall clock, a Time (the gap dividers)
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
      # @param link [AttachLink, nil] where the session is, instead of
      #   +client+ and the keywords that make a LocalLink
      def initialize(screen:, client_id:, client: nil, first_prompt: nil, first_command: nil, no_interrupt: false,
                     default_input: false, wait_at_eof: false, as_parent: false,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, now: -> { MessageTime.now },
                     delete_session: ->(id) { SessionManager.delete_session(id, stop: true, wait: LocalLink::DELETE_WAIT) },
                     archive_session: ->(id) { SessionManager.archive_session(id, wait: LocalLink::DELETE_WAIT) },
                     installed_version: -> { InstalledVersions.new.newest },
                     state_dir: Session.default_state_dir,
                     children_counts: ->(id) { ChildrenStatus.counts(id, state_dir: state_dir) }, link: nil)
        @link = link || LocalLink.new(client: client, state_dir: state_dir, delete_session: delete_session,
                                      archive_session: archive_session, installed_version: installed_version,
                                      children_counts: children_counts)
        @client = @link.client
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
        # The session's last activity, for the gap dividers (GapClock).
        @gaps = GapClock.new(now: now)
        @join_replay = JoinReplay.new(screen: @screen, view: @view, link: @link, gaps: @gaps, renderer: @renderer)
        @last_idle_interrupt_at = nil
        @next_input_prefill = nil
        # This run's prompts queued for after the running turn (their ack
        # said queue), oldest first, until their turn starts or they are
        # removed: /unqueue takes back the newest.
        @my_queued = []
        @wait_at_eof = wait_at_eof
        @own_turns = OwnTurns.new(active: wait_at_eof)
        # A continue offer is pending: the prompt asks for the answer.
        @continue_offer = nil
        # The /exit ask is open: the next line is its answer (#answer_exit_ask).
        @exit_ask = nil
        # The status row: the worker's model, ctx, the session's memories.
        @status = StatusRow.new(screen)
        # Participants' names by author ("p:<id>"), from the join's state
        # and :participants_changed: their lines' prefix. One who left
        # keeps theirs.
        @participant_names = {}
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
                                reconnect_delays: @link.reconnect_delays) do |event|
          queue << [:event, event]
        end
        read = input || method(:read_input_line)
        # A command typed after /unqueue's text echoes as the command alone.
        # A typed prompt after a quiet gap has its divider above its echo.
        echoed_read = lambda do |prompt, prefill|
          RelineSeam.echo_as(method(:prefilled_echo)) do
            RelineSeam.echo_above(method(:gap_above_echo)) { read.call(prompt, prefill) }
          end
        end
        @reader = LineReader.new(queue, prompt: method(:prompt_text), read: echoed_read, prefill: default_input_text).start
        loop do
          kind, payload = next_item(queue)
          case kind
          when :event
            ended = safely_handle(payload)
            return ended if %i[closed failed unanswered].include?(ended)
            return archive_now if archive_due?

            ended = take_early_lines
            return ended if ended
            return end_of_input if @own_turns.input_ended? && !own_turns_pending?
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

          @own_turns.end_input
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
          mark_activity
          start_turn(event)
        when :turn_completed
          @status.take_event(event)
          complete_turn(event)
          @gaps.touch
          refresh_children
          own_turn_ended(event)
        # The renderer says how it ended (the REPL's words too).
        when :turn_canceled, :turn_failed
          @status.take_event(event)
          @renderer.call(event)
          end_turn
          @gaps.touch
          refresh_children
          own_turn_ended(event)
        when :prompt_restored then restore_prompt(event)
        # The after_turn hooks are done (their notices came before it).
        when :answer_display then @own_turns.displayed
        when :context_status, :used_memories_updated then @status.take_event(event)
        when :participants_changed then participants_changed(event)
        # Another client's anytime command: its line now, before the cards
        # it shows (its command_ran comes when it's done). One queued for
        # after the turn says so now.
        when :command_queued
          @screen.commit(prompt_line(event[:client_id], event[:line])) if event[:anytime] && !own?(event[:client_id]) && !event[:card]
          command_waits(event) if event[:waits] && !event[:card]
        when :command_ran
          command_ran(event)
          return first_command_ran(event) if @first_command_id && event[:command_id] == @first_command_id
        when :reminder_injected
          mark_activity
          @screen.commit(reminder_line(event[:reminders]))
        # A context note joined the conversation (between turns). One dim
        # line in the scrollback; the notes slot is for question choices.
        when :context_added
          mark_activity
          @screen.commit(context_note_line(event[:label], event[:text]))
        when :continue_offered then offer_continue(event)
        when :continue_resolved then continue_resolved(event)
        # The note comes with the kernel's :pending_input_merged (EventRenderer),
        # after the answer the merge follows.
        when :input_merged
          merged_own_prompts(event)
          # A delegate's report: a child's state changed.
          refresh_children if Array(event[:origins]).any? { |origin| report_origin?(origin_of(origin)) }
        when :question_requested
          # Nothing is left to answer it with.
          return unanswered_question(event[:pending_question]) if @own_turns.input_ended?

          ask(event[:pending_question])
        when :question_answered then question_answered(event)
        when :question_cancelled
          close_question(@question.closed_text(event[:reason])) if @question
        # Relayed to the parent's card, or no longer: the widget says so.
        when :question_relay then question_relayed(event)
        # Written while the session sat idle: shown at the open prompt. One
        # collected just as a turn started describes the chat before it.
        when :recap_ready then show_recap_ready(event) unless @running || event[:recap].to_s.strip.empty?
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
        # A stream through chi web (never a Bridge here): a reconnect failed,
        # and the next frame came.
        when :stream_retrying then @screen.commit("(lost the connection to #{via.remote || "the worker"}; reconnecting…)")
        when :stream_resumed then @screen.commit("(reconnected)")
        when :stream_closed
          @view.finish_thinking_spinner
          @screen.commit(closed_line(event[:reason].to_s))
          return :closed
        else @renderer.call(event)
        end
        nil
      end

      private

      # A recap written while idle, with the time it was written.
      def show_recap_ready(event)
        mark_activity
        @screen.commit(recap_block(event[:recap], at: event[:created_at]))
      end

      # Activity starts now: a gap's divider first when one passed since the
      # last (none while a turn runs: its steps are no gap).
      def mark_activity
        line = @gaps.divider(quiet: @running)
        @screen.commit(gap_divider(line)) if line
      end

      # The newest chi installed, looked at once, at the join.
      def installed_version
        @link.installed_version
      rescue StandardError
        nil
      end

      # How the commands this TUI prints are spelled (AttachLink#via).
      def via = @link.via

      # The session's live worker for the stream to follow (EventStream's
      # rediscover), with its reason (AttachLink#live_worker's pair): the
      # stream's closing event carries the last one (#closed_line).
      def live_worker = @link.live_worker

      # The stream moved to a new worker (a restart): requests go there too.
      def switch_worker(event)
        @client = @link.switched(event) || @client
        @worker_changed = true
        # The new worker's machine may name another default model.
        @default_model_name = nil
        @view.finish_thinking_spinner
        Log.info(:attached, "worker_changed", port: AttachLink.event_port(event), epoch: event[:epoch])
        nil
      end

      # The stream ended for good: why, and what brings the session back.
      def closed_line(reason)
        id = @client.session_id
        # The worker asked for a secret this terminal's chi doesn't send.
        return "Lost the session's worker: #{BridgeSecret.refused(id, via: via)}" if reason == BridgeSecret::ERROR
        return remote_closed_line(reason, id) if via.remote?

        return "Lost the session's worker: #{@link.failure}" if reason == "worker_newer" && @link.failure

        # Here a stopped session has always read as unreachable.
        reason = "unreachable" if reason == "stopped"
        "Lost the session's worker (#{reason}). Resume it with: #{via.command("--shared --resume #{id}")}"
      end

      # Each reason in its own words (the remote's name, its chi web's
      # failure as AttachLink#failure gave it).
      def remote_closed_line(reason, id)
        name = via.remote
        failure = @link.failure
        case reason
        when "stopped" then "The session was stopped on #{name}. Resume it with: #{via.resume(id)}"
        when "auth_failed", "too_old" then "Lost the session: #{failure || reason}"
        when "worker_gone" then "The session's worker on #{name} is gone. Resume it with: #{via.resume(id)}"
        when "unknown_session" then "The session is gone from #{name} (deleted)."
        else
          cause = failure&.sub(/\Aremote \S+ \([^)]*\): /, "")
          "Lost the connection to #{name}#{" (#{cause})" if cause}. Re-attach with: #{via.attach(id)}"
        end
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

      # A request the Bridge read after its deadline and dropped
      # (BridgeClient::DEADLINE_SHARE): it didn't go through.
      def too_late?(reply) = reply.status == 408 && reply.json&.fetch("error", nil) == "deadline_passed"

      # Why a Bridge request raised, for the line that says what didn't go
      # through: a stopped (or wedged) worker times out, a gone one refuses.
      def worker_down(error)
        # Through chi web: the message names the remote and what failed.
        return error.message if via.remote?

        head, detail = error.message.split(" - ", 2)
        return "worker not answering: #{(detail || head).sub(/\Abridge \S+: /, "")}" if error.is_a?(Errno::ETIMEDOUT)

        "worker unreachable: #{head.downcase}"
      end

      # /share and /participants: chi share for this session, where it is.
      def participant_commands
        @participant_commands ||= ParticipantCommands.new(access: @link.session_access, session_id: @client.session_id,
                                                          tty: $stdout.tty?)
      end

      def show_stats
        metrics = @link.stats_metrics
        @screen.commit(metrics ? format_session_metrics(EventRenderer.deep_symbolize_keys(metrics)) : "(no metrics: the worker did not answer)")
      rescue SystemCallError, IOError => e
        # Through chi web: the message names the remote and what failed.
        @screen.commit("(no metrics: #{via.remote? ? e.message : "the worker did not answer"})")
      end

      # The saved recap, and a new one asked for at once (it arrives as
      # :recap_ready), with the REPL's words.
      def show_recap
        reply = @client.request_recap
        answer = reply.status == 200 ? reply.json : nil
        return @screen.commit("(no recap: the worker did not answer)") unless answer

        @screen.commit(recap_command_text(enabled: answer["enabled"], saved: answer["saved"],
                                          request: answer["request"], min_user_turns: answer["min_user_turns"],
                                          session_off: answer["session_off"] == true))
      rescue SystemCallError, IOError => e
        @screen.commit("(no recap: #{via.remote? ? e.message : "the worker did not answer"})")
      end

      # The name of this chi's own command +line+ when the worker answered it
      # unknown_command (it runs an older chi without it), else nil.
      def older_worker_command(reply, line)
        return nil unless reply.status == 400 && reply.json&.fetch("error", nil) == "unknown_command"

        SessionCommands.builtin_name(line)
      end

      def stale_worker(cant)
        BridgeClient.stale_worker_message(@client.session_id, cant: cant, via: via)
      end

      # The worker rolled a failed turn back and handed its prompt back: ours
      # goes back into the input, as the REPL restores it for a retry.
      def restore_prompt(event)
        origin = origin_of(event[:origin])
        return unless own?(origin.client_id) && @own_turns.sent?(origin.enqueued_id)
        # Lines from a pipe: nobody to retry it (the REPL's rule).
        return if @wait_at_eof

        if @reader&.prefill(event[:prompt].to_s)
          @screen.commit(turn_end_hint("prompt restored for retry"))
        else
          @screen.commit(turn_end_hint("the failed prompt is in the input history (↑)"))
        end
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
          @screen.commit(recap_block(saved[:text], turns_since: saved[:turns_since], at: saved[:created_at])) if saved && !saved[:text].to_s.strip.empty?
          @join_replay.render_join(snapshot, saved)
          @screen.commit("guardrails> #{snapshot[:guardrail_warning]}") if snapshot[:guardrail_warning]
          @screen.commit("plugins> #{snapshot[:plugin_warning]}") if snapshot[:plugin_warning]
          version_line = VersionLines.at_attach(worker: snapshot[:chi_version], installed: installed_version,
                                                session_id: @client.session_id, via: via)
          @screen.commit(paint(version_line, 2)) if version_line
        end
        if snapshot[:commands]
          @command_registry = Commands::Registry.from_listing(snapshot[:commands], base: SessionCommands.builtin_registry)
        end
        Array(snapshot[:init_tasks]).each { |task| @view.init_started(task) }
        cards = Array(snapshot[:cards])
        @join_replay.render_snapshot_cards(cards.reject { |card| card[:current] }, joining: !reset)
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
        @join_replay.render_snapshot_cards(cards.select { |card| card[:current] }, joining: !reset)
        queued.each do |entry|
          next if own?(entry[:client_id])

          @shown_enqueued << entry[:enqueued_id]
          @screen.commit("queued #{prompt_line(entry[:client_id], entry[:prompt], **author_of(entry[:author]))}")
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

      def render_current_turn(turn)
        @running = !turn.nil?
        @joined_mid_turn = @running
        # A turn running at the join: the status row's steer hint.
        @status.update(running: @running)
        return unless turn

        continues = turn[:prompt].nil?
        origin = origin_of(turn[:origin])
        unless continues && reminder_origin?(origin)
          @screen.commit(prompt_line(origin.client_id, turn[:prompt] || continuing_text(origin), **author_of(origin.author)))
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

      def start_turn(event)
        @running = true
        @joined_mid_turn = false
        origin = origin_of(event[:origin])
        @my_queued.delete(origin.enqueued_id)
        if event[:prompt].nil?
          # A continue turn (after the offer's yes) has no prompt to show; a
          # reminder turn shows its reminders (:reminder_injected).
          # A turn run for delegate reports shows them as they merge; one
          # an attached context change started, its label (the note is above).
          unless reminder_origin?(origin) || report_origin?(origin)
            @screen.commit(prompt_line(origin.client_id, continuing_text(origin), **author_of(origin.author)))
          end
        elsif !(own?(origin.client_id) || @shown_enqueued.include?(origin.enqueued_id))
          @screen.commit(prompt_line(origin.client_id, event[:prompt], **author_of(origin.author)))
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

      # The joining snapshot's session state: the worker's model, the
      # memories the session used, who is in the review.
      def take_session_state(state)
        @status.take_state(state, default_model: (default_model_name if state[:model_name]))
        learn_participants(state[:participants])
        refresh_children
      end

      # A participant was invited, revoked or expired: a line each, and the
      # status row's count. An invite or a revoke made here by /share or
      # /participants revoke was shown as it ran: not again.
      def participants_changed(event)
        learn_participants(event[:participants])
        learn_participants(event[:joined])
        joined = Array(event[:joined]).reject { |row| own_participant_change?(:joined, row) }
        left = Array(event[:left]).reject { |row| own_participant_change?(:left, row) }
        participants_change_lines(joined, left).each { |line| @screen.commit(line) }
        @status.update(participants: Array(event[:participants]).size)
      end

      def own_participant_change?(kind, row)
        !@participant_commands.nil? && row.is_a?(Hash) && @participant_commands.own_change?(kind, row[:id])
      end

      def learn_participants(rows)
        Array(rows).each { |row| @participant_names[Steer.author_for(row[:id])] = row[:name] if row.is_a?(Hash) && row[:id] }
      end

      # The prompt line's author keywords for the +author+ of an event, an
      # origin or a queued row ("p:<id>"): their name as the worker named
      # them; {} for the owner's.
      def author_of(author)
        author = Steer.sender_author(author) or return {}

        { author: author, author_name: @participant_names[author] }
      end

      # The status row's children segment: the delegates' counts, read from
      # their files here (ChildrenStatus.counts) at the join, when a turn
      # ends and when a report merges; the worker sends nothing for it.
      # Not read with status.line off; a failed read keeps the row.
      def refresh_children
        return unless @status.enabled?

        @status.update(children: @link.children_counts)
      rescue StandardError => e
        Log.debug(:attached, "children_counts_failed", error: e.class.name)
      end

      # The config's default model, as the worker's /model names it.
      def default_model_name
        @default_model_name ||= @link.default_model_name
      end

      # An event's origin (its wire Hash) as a TurnOrigin, NONE for none.
      def origin_of(value) = TurnOrigin.of(value)
      def reminder_origin?(origin) = origin.client_id.to_s.start_with?(ClientId::SYSTEM_PREFIX)
      def report_origin?(origin) = origin.source == "delegate_report"
      def context_origin?(origin) = origin.source == "context"
      def task_origin?(origin) = origin.source == "task"
      # A turn with no prompt: "(continuing)"; a context wake's or a task
      # finish wake's label alone.
      def continuing_text(origin) = context_origin?(origin) || task_origin?(origin) ? nil : "(continuing)"
    end
  end
end
