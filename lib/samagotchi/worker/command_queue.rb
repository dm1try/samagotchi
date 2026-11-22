# frozen_string_literal: true

require_relative "../client_id"
require_relative "../command_intake"
require_relative "../log"
require_relative "../session_commands"
require_relative "../session_inbox"
require_relative "../session_setting"
require_relative "../turn_checkpoint"

module Samagotchi
  class Worker
    # Session commands between turns: the loop runs what #run_queued_commands
    # finds in @command_queue (/model, !rollback, !cmd, /continue ...) before
    # any queued prompt, and refuses or drops what arrives mid-turn. Includes
    # the "what waits" predicates #input_pending?, #held_for_offer? and
    # #nothing_queued?. LOCK RULE: the queue is touched with the event log held
    # (@event_log.synchronize): #on_command on a Bridge thread, the pops
    # and re-pushes in #next_ready_command, #refuse_queued_commands and
    # #drop_queued_commands. The `empty?` peeks (those, #input_pending?,
    # #nothing_queued?, #start's next_turn_waiting lambda) are benign by
    # design. Writes @command_queue's contents (created in #initialize).
    # Reads @engine, @event_log, @turn_state, @session_dir, @commands (built in #start),
    # @continue_offer, @turn_end_seq, @turn_end_type (#start's observer),
    # @turn_flow and @waker.
    module CommandQueuePart
      # How much of a command's output goes into its :command_ran, in chars.
      # Room for a real listing (/guardrails with a bundle's rules, /models):
      # the event lives only in the Bridge's ring (256 events, in memory) and
      # on the streams, a session file doesn't hold it.
      COMMAND_OUTPUT_LIMIT = 64 * 1024
      BUSY_OUTPUT = "busy: wait for the turn to end"
      # !rollback mid-turn would mean "the turn I'm in".
      ROLLBACK_BUSY_OUTPUT = "busy: Ctrl-C the turn first, then !rollback"

      private

      # Whether a command or an input file waits to run (WorkerIdleExit's
      # :input_queued). A participant's file held for the Continue offer
      # (#held_for_offer?) doesn't count: what waits is the owner's answer,
      # the policy's :continue_offered.
      def input_pending?
        !@command_queue.empty? || SessionInbox.find_new_input_files(@session_dir).any? { |file| !held_for_offer?(file) }
      end

      # Whether +input_file+ waits for the owner's answer to the Continue
      # offer that stands (#run_input_files).
      def held_for_offer?(input_file) = @turn_flow&.awaiting_continue? && SessionInbox.participant_input?(input_file)

      # No input file or queued command waits: the loop would go idle.
      def nothing_queued? = @command_queue.empty? && SessionInbox.find_new_input_files(@session_dir).empty?

      # The queued commands that may run now, in order, up to one whose
      # after_file (D1) still waits in the inbox: it and those behind it stay
      # queued.
      # @return [Boolean] whether any command ran
      def run_queued_commands
        ran = false
        # A signalled worker runs no more (a /continue would start a turn).
        while !signalled? && (command = next_ready_command)
          run_command(command)
          ran = true
        end
        ran
      end

      # Pops the first queued command if it may run now (its after_file is
      # taken), else none: one behind it waits too, in arrival order (an idle
      # /model Y that came just after the turn ended stays behind a /model X
      # still waiting for a prompt sent before it). With the event log held,
      # as the Bridge queues.
      def next_ready_command
        return nil if @command_queue.empty?

        @event_log.synchronize do
          commands = drain_commands
          first = commands.first
          ready = first && ready_command?(first) ? commands.shift : nil
          commands.each { |command| @command_queue << command }
          ready
        end
      end

      # A participant's file held for the Continue offer (#run_input_files)
      # doesn't hold a command back: that command may be the owner's answer.
      def ready_command?(command)
        return true if command.after_file.nil?

        SessionInbox.find_new_input_files(@session_dir).none? do |path|
          File.basename(path) <= command.after_file && !held_for_offer?(path)
        end
      end

      def drain_commands
        commands = []
        while (command = next_command)
          commands << command
        end
        commands
      end

      # A command a turn refuses (:refuse while it ran, S1) is answered busy:
      # at the turn's iteration boundaries (mid_turn: all of them), and when
      # it ends (the ones queued before its end event; later ones run next).
      # A queued one (:queue) stays for after the turn, but a !cmd after a
      # canceled or failed turn (D4): running it would close the rollback
      # window the turn left, so it is dropped. With the event log held, so
      # a command the Bridge queues meanwhile stays behind the ones kept, in
      # arrival order. One that comes after the empty look is the next
      # boundary's (or end's), as it would be.
      def refuse_queued_commands(mid_turn: false)
        return if @command_queue.empty?

        @event_log.synchronize do
          drain_commands.each do |command|
            during = mid_turn || command.after_seq.to_i < @turn_end_seq
            case (during ? turn_answer(command, ended: !mid_turn) : :keep)
            when :refuse then announce_command(command, status: "busy", output: busy_output(command), changed: [])
            when :drop then drop_command(waiting_for_turn_end(command), "turn #{@turn_end_type == :turn_failed ? "failed" : "canceled"}: " \
                                                                        "#{command.line} not run; send it again")
            else @command_queue << (during ? waiting_for_turn_end(command) : command)
            end
          end
        end
      end

      # What a turn does with +command+, queued while it ran: :refuse, :drop
      # (D4, once it +ended+) or :keep. One queued idle just as the turn
      # began (:loop) goes by its line's policy (a show form waits too).
      def turn_answer(command, ended:)
        policy = command.mid_turn
        policy = @engine.command_registry.mid_turn(command.line) if policy == :loop
        return :refuse if policy == :refuse
        return :drop if ended && policy == :queue && shell_command?(command) &&
                        %i[turn_canceled turn_failed].include?(@turn_end_type)

        :keep
      end

      # +command+, kept for after the turn. One queued idle just as the turn
      # began (:loop) whose line waits for a turn's end (/model X, !cmd) is
      # marked as one queued mid-turn: its command_queued (waits) tells the
      # UIs now, and its command_ran says queued.
      def waiting_for_turn_end(command)
        return command unless command.mid_turn == :loop && @engine.command_registry.mid_turn(command.line) == :queue

        @event_log.announce(type: :command_queued, **command.event_fields, waits: "turn_end")
        command.with(mid_turn: :queue)
      end

      def shell_command?(command) = @engine.command_registry.lookup(command.line)&.id == :shell

      def busy_output(command)
        @engine.command_registry.lookup(command.line)&.id == :rollback ? ROLLBACK_BUSY_OUTPUT : BUSY_OUTPUT
      end

      # +command+ won't run: its sender (a UI's queued bubble) is told.
      def drop_command(command, output)
        announce_command(command, status: "dropped", output: output, changed: [])
      end

      # The worker leaves with commands still queued (a stop, a crash): each
      # one's sender is told it won't run, so no UI shows it waiting for good.
      def drop_queued_commands
        return if @command_queue.nil? || @command_queue.empty? || @engine.nil?

        @event_log.synchronize do
          drain_commands.each { |command| drop_command(command, "dropped: the session's worker stopped before it ran") }
        end
      rescue StandardError => e
        Log.warn(:worker, "drop_commands_failed", error: e.class.name, msg: e.message)
      end

      def next_command
        @command_queue.pop(true)
      rescue ThreadError
        nil
      end

      def run_command(command)
        awaiting = @continue_offer.awaiting?
        result, shown = run_command_line(command)
        resolved = @continue_offer.resolved?(awaiting, result)
        @event_log.synchronize do
          @continue_offer.announce_resolved(result, command) if resolved
          announce_command(command, status: result.status.to_s, output: result.output, changed: Array(result.changed),
                                    confirm: result.confirm)
          shown.each { |event| @event_log.announce(event) }
        end
        save_or_log(:command) { save_session } unless Array(result.changed).empty?
        user_input(command.client_id) if resolved
        @continue_offer.after_command(result, resolved: resolved)
        @continue_offer.run_continue_turn(command) if result.resume
      end

      # @return [Array(SessionCommands::Result, Array<Hash>)] the result, and
      #   the cards and notices it showed, held: they follow its command_ran,
      #   as its output
      def run_command_line(command)
        @engine.holding_announcements do
          command_result(command) do
            @commands.run(command.run_line, confirm: confirm?(command), as_parent: as_parent?(command), user_ui: user_ui?(command))
          end
        end
      end

      # A shell line from a sender that may not run one (CommandIntake: a
      # delegate's task, a schedule's prompt, a plugin's message): not run,
      # its command_ran an error with the one refusal text.
      def shell_refused(command)
        Log.warn(:worker, "shell_line_refused", client_id: command.client_id)
        SessionCommands::Result.new(status: :error, output: CommandIntake::REFUSED, changed: [])
      end

      # Whether +command+ asks before a costly /thinking or /reasoning-history
      # change (CacheConfirm): only a person at a web tab or a TUI sees the
      # question; chi send, a delegate, a plugin and a card's action apply it.
      def confirm?(command) = ClientId.interactive?(command.client_id) && !command.card

      # Whether +command+ is a parent agent's (chi answer's marker, which chi
      # send and a parent's attach give a /continue yes too, or an agent's
      # id that reached the worker unmapped): held to
      # guardrails.parent_answers (SessionCommands#continue_answer).
      def as_parent?(command)
        command.client_id.to_s == ClientId::CLI_ANSWER || ClientId.agent?(command.client_id)
      end

      # Whether +command+ is a user's at a UI (a web tab, a chi TUI, a card's
      # click), not a parent agent's: only such a line loosens
      # /parent-answers. chi send, a delegate's follow-up, a plugin and an
      # input with no client never do (ParentAnswersCommand).
      def user_ui?(command) = ClientId.interactive?(command.client_id) && !as_parent?(command)

      # The block's Result for +command+; one that raised, or found no
      # command for the line, is an error Result saying so.
      # @return [SessionCommands::Result]
      def command_result(command)
        return shell_refused(command) if CommandIntake.refused?(command.line, command.client_id)

        yield || SessionCommands::Result.new(status: :error, output: "not a session command", changed: [])
      rescue StandardError => e
        SessionCommands::Result.new(status: :error, output: "#{command.line.split.first}: #{e.message}", changed: [])
      end

      # A session command from the Bridge, called with the event log held:
      # an anytime one starts now, any other is queued for the loop (and
      # refused if a turn runs: #refuse_queued_commands). While a turn runs
      # the line's policy decides (a show form like /model runs now); idle,
      # only an always-anytime command (/help) runs beside the loop, so an
      # idle /model X then /model run in order. A turn starting or ending
      # right now may see the other side: the line is only shown early or
      # run in order.
      #
      # A queued one (:queue) keeps arrival order with the prompts (D1): it
      # runs once every input file written before it is taken (after_file,
      # the newest one now; names compare, not clocks), so a prompt sent
      # before it runs first and one sent after it runs after. One that came
      # in an input file runs once that file is taken (+after_file+).
      # @return [Symbol] the policy it applied (the Bridge marks an anytime
      #   one's command_queued, and a queued one's): :anytime, :queue or
      #   :refuse while a turn runs, :loop idle
      def on_command(command, after_file: nil)
        registry = @engine.command_registry
        policy = if @turn_state.running? then registry.mid_turn(command.line)
                 else registry.anytime?(command.line) ? :anytime : :loop
                 end
        if policy == :anytime
          start_anytime_command(command)
          return policy
        end

        after_file ||= newest_input_file if policy == :queue
        # The count says which turn ends came before it.
        @command_queue << command.with(after_seq: @event_log.event_count, mid_turn: policy, after_file: after_file)
        @waker.wake
        policy
      end

      # @return [String, nil] the newest input file waiting (its basename)
      def newest_input_file
        SessionInbox.find_new_input_files(@session_dir).map { |path| File.basename(path) }.max
      end

      # An anytime command (/help, a plugin's /btw; D8) runs now, on its own
      # thread, never queued behind a turn: it is never busy. The Bridge calls
      # this with the event log held, so its command_ran (announced when it
      # finishes) comes after its command_queued. The cards it shows go out at
      # once (btw's "thinking…" card), after its command_queued, which the
      # UIs draw its line at (Engine#running_anytime). Its handler reads
      # copies (ctx.messages) and shows things through ctx only. One that
      # changed the session (/title, /recap off: fields no turn writes) is
      # saved here, as a queued one is (#run_command), through Session#save,
      # which takes the session's lock and writes a running turn's checkpoint
      # (as WorkerSignals' save off the turn thread does), so the turn's own
      # saves keep it.
      def start_anytime_command(command)
        @engine.spawn_anytime do
          result = command_result(command) do
            @engine.running_anytime do
              @commands.run(command.run_line, confirm: confirm?(command), as_parent: as_parent?(command), user_ui: user_ui?(command))
            end
          end
          # Saved before its command_ran: a client that reads the file on the reply finds it.
          save_or_log(:command) { save_session } unless Array(result.changed).empty?
          announce_command(command, status: result.status.to_s, output: result.output, changed: Array(result.changed),
                                    anytime: true, confirm: result.confirm)
          # It may have left a note (/objectives): an idle loop takes it now, not
          # at the fallback tick. Harmless otherwise: one more pass.
          @waker.wake
        rescue StandardError => e
          Log.warn(:worker, "anytime_command_failed", line: command.line, error: e.class.name, msg: e.message)
        end
      end

      # @param anytime [Boolean] an anytime command's: its line was shown at
      #   its command_queued already
      # @param confirm [CacheConfirm::Confirm, nil] the change asks first: the
      #   line that applies it (the TUI's prefill, the web's Apply button)
      def announce_command(command, status:, output:, changed:, anytime: false, confirm: nil)
        TurnCheckpoint.record_command_outcome(@session_dir, command.enqueued_id, status: status)
        # Any bytes (a !cmd's): one that JSON can't take would end every stream
        # that reaches this event, for as long as the ring holds it.
        text = output.to_s.scrub("?")
        event = { type: :command_ran, **command.event_fields, status: status, output: command_output_shown(text),
                  changed: changed.map(&:to_s), model_name: @engine.effective_model_name }
        event[:anytime] = true if anytime
        # The session's title after /title (nil: cleared), for the TUIs' row.
        event[:title] = @engine.session&.title if changed.include?(:title)
        # Its line was shown at its command_queued (waits: turn_end).
        event[:queued] = true if command.waits_for_turn_end?
        # The chips the command moved (SessionSetting#changed_by): what the next
        # turn runs under now (/llm-context, /thinking, /reasoning-history,
        # /toolkit, and /model for the model's).
        SessionSetting::ALL.each { |setting| event[setting.key] = setting.summary(@engine) if setting.changed_by?(changed) }
        event[:confirm] = confirm.to_h if confirm
        event[:output_truncated] = true if text.length > COMMAND_OUTPUT_LIMIT
        @event_log.announce(event)
      end

      # +text+ as its :command_ran carries it: over the limit, its head to a
      # line's end (one long line is cut where it must be), then a line that
      # says so: every UI prints this text as it is.
      def command_output_shown(text)
        return text if text.length <= COMMAND_OUTPUT_LIMIT

        kept = text[0, COMMAND_OUTPUT_LIMIT]
        line_end = kept.rindex("\n")
        kept = kept[0, line_end] if line_end && line_end > COMMAND_OUTPUT_LIMIT / 2
        "#{kept}\n[cut: #{kept.length} of #{text.length} chars: a command's output stops here]"
      end
    end
  end
end
