# frozen_string_literal: true

require "set"
require_relative "event_renderer"
require_relative "formatting"
require_relative "attached_view"
require_relative "input_support"
require_relative "image_input"
require_relative "line_reader"
require_relative "question_prompt"
require_relative "reline_seam"
require_relative "../bridge_client"
require_relative "../log"
require_relative "../context_note"
require_relative "../model_profile"
require_relative "../output_formatter"
require_relative "../session_commands"
require_relative "../session_manager"

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

      STATS_COMMAND = "/stats"
      RECAP_COMMAND = "/recap"
      PROMPT = "> "
      # Detach and leave the worker up.
      DETACH_COMMANDS = %w[/detach].freeze
      # Detach and ask the worker to exit (bare `exit` too, as in the REPL).
      EXIT_COMMANDS = %w[/exit /quit].freeze
      # After an exit command: delete the session once the worker has gone.
      DELETE_FLAG = "--delete"
      # How long /exit --delete waits for the worker to let go.
      DELETE_WAIT = 10
      # A second Ctrl-C at an empty idle prompt within this many seconds detaches.
      DETACH_WINDOW = 2.0
      DETACH_HINT = "Ctrl-D to detach, /exit stops the worker"
      # Why the worker stayed up after /exit, by the reason it gave.
      HELD_REASONS = {
        "turn_running" => "a turn is running", "input_queued" => "prompts are queued",
        "continue_offered" => "a continue offer is pending", "client_connected" => "another UI is attached",
        "reminders" => "reminders are set", "starting" => "the worker is still starting"
      }.freeze
      ROLLBACK_HINT = "partial progress kept in context; !rollback restores the pre-turn state"
      # How much of the last answer a join shows.
      JOIN_ANSWER_LINES = 12
      JOIN_ANSWER_CHARS = 1200

      # Prompt labels by the sender's client_id prefix.
      CLIENT_LABELS = { "web" => "web", "tui" => "tui", "system" => "reminder" }.freeze

      attr_reader :client_id

      # @return [String, nil] the model the worker's turns run on, as the
      #   last command said
      attr_reader :model_name

      # @return [QuestionPrompt, nil] the question waiting for an answer
      attr_reader :question

      # @param client [BridgeClient]
      # @param screen [Surface] with #synchronize and #columns (a Screen, or a
      #   PlainSurface when the terminal can't show a live region)
      # @param client_id [String] this UI's id in the events ("tui:<pid>")
      # @param first_prompt [String, nil] sent once joined (`chi -p`)
      # @param first_command [String, nil] run before the first prompt
      #   (`--model` on a resumed session: "/model X"); if it doesn't go
      #   through, the launch stops
      # @param no_interrupt [Boolean] post every turn with no_interrupt
      # @param default_input [Boolean] type SAMAGOTCHI_DEFAULT_INPUT into
      #   the first read (a new session with no -p, as the REPL)
      # @param clock [#call] monotonic seconds (the Ctrl-C detach window)
      # @param delete_session [#call] session id -> deletes it (/exit --delete)
      def initialize(client:, screen:, client_id:, first_prompt: nil, first_command: nil, no_interrupt: false,
                     default_input: false, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     delete_session: ->(id) { SessionManager.delete_session(id, stop: true, wait: DELETE_WAIT) })
        @client = client
        @delete_session = delete_session
        @screen = screen
        @client_id = client_id
        @view = AttachedView.new(screen)
        @renderer = EventRenderer.new(@view)
        @shown_enqueued = Set.new
        @running = false
        @joined_mid_turn = false
        @attached = false
        @question = nil
        @answered_ids = Set.new
        @reader = nil
        @first_prompt = first_prompt
        @first_command = first_command
        @first_command_id = nil
        @no_interrupt = no_interrupt
        @no_default_input = !default_input
        @clock = clock
        @last_idle_interrupt_at = nil
        @next_input_prefill = nil
        # Prompts this run sent, by enqueued_id: only those come back into
        # the input when their turn fails (a replayed event must not).
        @sent_ids = Set.new
        # A continue offer is pending: the prompt asks for the answer.
        @continue_offer = nil
        @model_name = nil
        @turn_continues = false
        # The idle status line's data (the REPL's segments).
        @memory_names = []
        @context_estimate = nil
        @status_rows = nil
      end

      def running? = @running

      # Follow the session and read input until Ctrl-D, /detach, /exit or
      # the worker goes away. The worker keeps running after a detach; /exit
      # asks it to exit too, and it does unless something still needs it.
      # @return [Symbol] :detached, :closed when the worker went away, or
      #   :failed when the first command (--model) didn't go through
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
        stream = @client.follow(client_id: @client_id) { |event| queue << [:event, event] }
        @reader = LineReader.new(queue, prompt: method(:prompt_text), read: input || method(:read_input_line),
                                        prefill: default_input_text).start
        loop do
          kind, payload = next_item(queue)
          case kind
          when :event
            ended = safely_handle(payload)
            return ended if ended == :closed || ended == :failed
          when :line then return :detached if submit(payload) == :detach
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
        when :turn_started then start_turn(event)
        when :turn_completed then complete_turn(event)
        when :turn_canceled
          continued = @turn_continues
          end_turn("turn cancelled (#{event[:cancellation_reason]})")
          # A cancelled continue is back where it started; a prompt turn's
          # partial progress stays, as in the REPL.
          @screen.commit(ROLLBACK_HINT) unless continued
        when :turn_failed
          end_turn("turn failed: #{event[:summary] || "#{event[:message]} (#{event[:error_class]})"}")
        when :prompt_restored then restore_prompt(event)
        when :context_status
          @context_estimate = { est_pct: event.dig(:usage, :estimated_pct), bucket: event[:bucket] }
          refresh_status
        when :used_memories_updated
          @memory_names = Array(event[:used_memory_names])
          refresh_status
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
        when :input_merged then nil
        when :question_requested then ask(event[:pending_question])
        when :question_answered then question_answered(event)
        when :question_cancelled
          close_question("(question cancelled)") if @question
        # Written while the session sat idle: shown at the open prompt. One
        # collected just as a turn started describes the chat before it.
        when :recap_ready then @screen.commit(recap_block(event[:recap])) unless @running || event[:recap].to_s.strip.empty?
        when :guardrail_warning then @screen.commit("guardrails> #{event[:message]}")
        when :generation_completed
          take_served_model(event[:served_model], event[:requested_model])
          @renderer.call(event)
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
        return answer_question(text) if @question
        # Before the continue offer: neither is an answer to it.
        return submit(nil) if DETACH_COMMANDS.include?(text.downcase)
        return exit_worker if exit_command?(text)
        return exit_and_delete if exit_command?(text.delete_suffix(DELETE_FLAG).rstrip) && text.end_with?(" #{DELETE_FLAG}")
        command = text.split(/\s+/, 2).first
        if @continue_offer
          return answer_continue(text) unless SessionCommands.command?(text) || [STATS_COMMAND, RECAP_COMMAND].include?(command)

          # Not an answer: the read left no echo, so show what ran.
          echo_answer(text)
        end
        return if text.empty?

        if command == STATS_COMMAND
          show_stats
        elsif command == RECAP_COMMAND
          show_recap
        elsif SessionCommands.command?(text)
          # The history keeps !cmds, as the REPL's does (prompts: #send_prompt).
          persist_recent_history(text) if shell_line?(text)
          send_command(text)
        else
          send_prompt(text)
        end
        nil
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

      def exit_command?(text) = EXIT_COMMANDS.include?(text.downcase) || text.casecmp?("exit")

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
        @delete_session.call(id) unless discards?(reply)
        detach("Detached; deleted session #{id}.")
      rescue SystemCallError, IOError => e
        detach("#{exit_failed_line(e.message)} Not deleted.")
      rescue SessionManager::DeleteRefused, SessionManager::OwnedByTUI, ArgumentError => e
        detach("Detached; the worker is stopping, but session #{id} was not deleted (#{e.message}): chi sessions delete #{id}")
      end

      def exit_line(reply)
        id = @client.session_id
        error = reply.json&.fetch("error", nil)
        case reply.status
        when 200
          # Said as the worker agreed to leave; a note coming in before it
          # does keeps the session after all (rare, left as is).
          return "Detached; the session was empty, so it is discarded." if discards?(reply)

          "Detached; the session's worker is stopping. Resume with: chi --resume #{id}"
        when 409
          reason = reply.json&.fetch("reason", nil).to_s
          "Detached; the session keeps running (#{HELD_REASONS.fetch(reason, reason)}). Re-attach with: chi --attach #{id}"
        when 0 then exit_failed_line("no reply")
        else
          # A worker from before the route answers the Bridge's plain 404.
          return "Detached; this worker runs an older chi and can't be stopped from here: chi sessions stop #{id}" if error == "not_found"

          exit_failed_line([reply.status, reply.json&.fetch("detail", nil) || error].compact.join(" "))
        end
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
        reply = @client.post_command(line: line, client_id: @client_id)
        return if reply.status == 202
        return @screen.commit(stale_worker("run commands")) if reply.status == 404

        detail = reply.json&.fetch("detail", nil) || reply.json&.fetch("error", nil)
        @screen.commit("could not run the command (#{[reply.status, detail].compact.join(" ")})")
      end

      def command_ran(event)
        @screen.commit(prompt_line(event[:client_id], event[:line])) unless own?(event[:client_id])
        output = event[:output].to_s
        if output.empty?
          nil
        elsif event[:status] == "busy" || shell_line?(event[:line])
          @screen.commit(output)
          put_back_busy_command(event) if event[:status] == "busy"
        else
          @screen.commit("#{paint("model>", 36)} #{output}")
        end
        return unless event[:model_name]

        # After the output, so the status row changes with the line saying why.
        @served_model = nil if @model_name != event[:model_name]
        @model_name = event[:model_name]
        refresh_status
      end

      # Our command the worker couldn't run yet goes back into the prompt, for
      # Enter once the turn ends (not the launch's --model: that ends the launch).
      def put_back_busy_command(event)
        return unless own?(event[:client_id]) && event[:command_id] != @first_command_id

        @screen.commit("(the command is in the input history: ↑)") unless @reader&.prefill(event[:line].to_s)
      end

      def shell_line?(line)
        line.to_s.start_with?(SessionCommands::SHELL_BANG_PREFIX) && line.to_s.strip != SessionCommands::ROLLBACK_COMMAND
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
        sync_continue_slot
        who = event[:client_id] ? CLIENT_LABELS.fetch(event[:client_id].to_s.split(":", 2).first, "another UI") : "another UI"
        outcome = if event[:decision] == "dropped"
                    "(dropped: #{own?(event[:client_id]) ? "you" : who} sent a new prompt)"
                  elsif own?(event[:client_id])
                    @continue_answer || CONTINUE_DECISIONS.fetch(event[:decision].to_s, event[:decision].to_s)
                  end
        @continue_answer = nil
        @screen.commit(QuestionSlot.continue_summary(outcome, paint: method(:paint))) if outcome
        sync_prompt
      end

      # The notes slot shows the offer's choices while it waits (a question
      # has the slot while it is open).
      def sync_continue_slot
        return if @question

        if @continue_offer
          @screen.set_slot(:notes, QuestionSlot.continue_offer(@continue_offer[:context], paint: method(:paint)))
        else
          @screen.clear_slot(:notes)
        end
      end

      def send_prompt(text)
        persist_recent_history(text)
        # #memory shorthand becomes words the model reads, as in the REPL.
        prompt = normalize_model_input(text)
        images = attach_images(text)
        return if images.nil?

        options = { prompt: prompt, client_id: @client_id }
        options[:no_interrupt] = true if @no_interrupt
        options[:images] = images unless images.empty?
        reply = @client.post_turn(**options)
        if reply.status == 202
          enqueued_id = reply.json&.fetch("enqueued_id", nil)
          @sent_ids << enqueued_id if enqueued_id
          return
        end

        detail = reply.json&.fetch("error", nil)
        explained = reply.json&.fetch("detail", nil) if detail == "images_unsupported"
        @screen.commit("could not send the prompt (#{[reply.status, detail].compact.join(" ")})#{": #{explained}" if explained}")
      end

      # The prompt's `@path` images, stored in the session's images/ here
      # (this machine, the worker's state dir) and sent as refs: the Bridge
      # never takes a path. nil (after a line saying why) when one can't be.
      def attach_images(text)
        paths = ImageInput.extract(text)
        return [] if paths.empty?

        session_dir = Session.session_dir(@client.session_id)
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
      def slash_commands = (InputSupport::SLASH_COMMANDS + EXIT_COMMANDS + DETACH_COMMANDS).uniq.sort

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
        @set_aside = @reader&.typed_text unless @question
        @question = QuestionPrompt.new(pending)
        # The prompt first, so the choices never show under the typed text.
        sync_prompt(keep_text: false)
        @screen.set_slot(:notes, @question.slot(paint: method(:paint)))
      end

      def answer_question(text)
        return dismiss_question if text.empty?

        answer = @question.parse(text)
        @screen.commit(answer.note) if answer.note
        unless answer.ok?
          echo_answer(text)
          return @screen.commit(answer.error)
        end

        reply = @client.answer(id: @question.id, selected: answer.selected, freeform: answer.freeform)
        case reply.status
        when 200
          @answered_ids << @question.id
          close_question(@question.answer_text(answer))
        when 409 then close_question("(already answered in another UI)")
        else
          detail = reply.json&.fetch("detail", nil) || reply.json&.fetch("error", nil)
          @screen.commit("could not answer (#{[reply.status, detail].compact.join(" ")})")
        end
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
        else
          # The question stays open (after a 404 too).
          detail = reply.json&.fetch("error", nil)
          @screen.commit("could not dismiss the question (#{[reply.status, detail].compact.join(" ")}); Ctrl-C cancels the turn")
        end
        nil
      end

      # A line read at ? that isn't a (valid) answer: the read left no echo,
      # so it shows above what it got.
      def echo_answer(text) = @screen.commit("#{paint(QUESTION_PROMPT, 33)}#{text}")

      def stale_worker(cant)
        BridgeClient.stale_worker_message(@client.session_id, cant: cant)
      end

      # The worker rolled a failed turn back and handed its prompt back: ours
      # goes back into the input, as the REPL restores it for a retry.
      def restore_prompt(event)
        origin = event[:origin] || {}
        return unless own?(origin[:client_id]) && @sent_ids.include?(origin[:enqueued_id])

        if @reader&.prefill(event[:prompt].to_s)
          @screen.commit("(prompt restored for retry)")
        else
          @screen.commit("(the failed prompt is in the input history: ↑)")
        end
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
        set_aside = @set_aside
        @set_aside = nil
        sync_prompt(keep_text: false, prefill: set_aside)
        sync_continue_slot if @continue_offer
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
          @client.cancel(reason: "ctrl_c")
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
        if @attached
          @screen.commit("(resynced with the session)") if reset
        else
          @attached = true
          # The recap first: what the session was about, then where it stopped.
          saved = snapshot[:saved_recap]
          @screen.commit(recap_block(saved[:text], turns_since: saved[:turns_since])) if saved && !saved[:text].to_s.strip.empty?
          render_join_header(Array(snapshot[:messages]))
          @screen.commit("guardrails> #{snapshot[:guardrail_warning]}") if snapshot[:guardrail_warning]
        end
        offer = snapshot[:continue_offer]
        had_offer = !@continue_offer.nil?
        @continue_offer = offer && { context: offer[:context], no_interrupt: offer[:no_interrupt] }
        if had_offer != !@continue_offer.nil?
          sync_prompt
          sync_continue_slot
        end
        render_current_turn(snapshot[:current_turn])
        Array(snapshot[:queued]).each do |entry|
          next if own?(entry[:client_id])

          @shown_enqueued << entry[:enqueued_id]
          @screen.commit("queued #{prompt_line(entry[:client_id], entry[:prompt])}")
        end
        return send_first_command if @first_command

        send_first_prompt
        nil
      end

      # --model on a resumed session: switch its worker before the first
      # prompt goes; its :command_ran decides (#first_command_ran).
      # @return [Symbol, nil] :failed when the worker didn't take it
      def send_first_command
        line = @first_command
        @first_command = nil
        reply = @client.post_command(line: line, client_id: @client_id)
        if reply.status == 202
          @first_command_id = reply.json&.fetch("command_id", nil)
          return nil if @first_command_id
        end

        why = reply.status == 404 ? stale_worker("run commands") : "the worker answered #{reply.status}"
        @screen.commit("could not switch to the --model: #{why}")
        :failed
      end

      # @return [Symbol, nil] :failed unless the switch went through
      def first_command_ran(event)
        @first_command_id = nil
        if event[:status] == "ok"
          send_first_prompt
          return nil
        end

        @screen.commit("could not switch to the --model: #{event[:output]}")
        :failed
      end

      # After the join, so it lands below what the session already had. Our
      # own prompts are never echoed from events (a typed one stays on screen),
      # so it is shown here as if typed.
      def send_first_prompt
        text = @first_prompt.to_s.strip
        @first_prompt = nil
        return if text.empty?

        @screen.commit("#{paint(PROMPT, 92)}#{text}")
        send_prompt(text)
      end

      def render_join_header(messages)
        exchange = messages.select { |m| %w[user model assistant].include?(m[:role].to_s) }
        # The id stays findable: the detach line and chi sessions list show it.
        Log.session_id = @client.session_id
        Log.info(:attached, "joined", session: @client.session_id, messages: exchange.size)
        last_user = exchange.rindex { |m| m[:role].to_s == "user" }
        render_join_notes(messages)
        return unless last_user

        @screen.commit(prompt_line(nil, exchange[last_user][:content]))
        Array(exchange[last_user][:images]).each { |ref| @screen.commit(format_image_line(ref)) }
        # The saved answer is raw: the latest keeps its thinking, and one may
        # be only a tool call.
        answer = exchange[(last_user + 1)..].reverse_each
                                           .map { |m| OutputFormatter.strip_markup(m[:content]) }
                                           .find { |text| !text.empty? }
        @screen.commit(last_lines(answer)) if answer
        render_join_notes(messages, after_exchange: true)
      end

      # The context notes that came since the last prompt (all of them in a
      # session with none), after the exchange the header shows.
      def render_join_notes(messages, after_exchange: false)
        last_user = messages.rindex { |m| m[:role].to_s == "user" }
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

      def render_current_turn(turn)
        @running = !turn.nil?
        @joined_mid_turn = @running
        return unless turn

        @turn_continues = turn[:prompt].nil?
        unless @turn_continues && reminder_origin?(turn[:origin] || {})
          @screen.commit(prompt_line(turn.dig(:origin, :client_id), turn[:prompt] || "(continuing)"))
        end
        Array(turn[:images]).each { |ref| @screen.commit(format_image_line(ref)) }
        tail = nil
        running_tool = nil
        Array(turn[:parts]).each do |part|
          case part[:kind]
          when "text" then tail = part[:text]
          when "tool"
            if part[:status] == "running"
              running_tool = part[:tool]
            else
              @screen.commit(snapshot_tool_line(part))
            end
          when "input" then @screen.commit("input> #{part[:text]}")
          when "reminder" then @screen.commit(reminder_line(part[:reminders]))
          end
        end
        @view.resume(tail: tail, tool: running_tool)
        ask(turn[:pending_question]) if turn[:pending_question]
      end

      def show_enqueued(event)
        return if own?(event[:client_id])

        @shown_enqueued << event[:enqueued_id]
        @screen.commit(prompt_line(event[:client_id], event[:prompt]))
      end

      def start_turn(event)
        @running = true
        @joined_mid_turn = false
        @turn_continues = event[:prompt].nil?
        origin = event[:origin] || {}
        if @turn_continues
          # A continue turn (after the offer's yes) has no prompt to show; a
          # reminder turn shows its reminders (:reminder_injected).
          @screen.commit(prompt_line(origin[:client_id], "(continuing)")) unless reminder_origin?(origin)
        elsif !(own?(origin[:client_id]) || @shown_enqueued.include?(origin[:enqueued_id]))
          @screen.commit(prompt_line(origin[:client_id], event[:prompt]))
        end
        @renderer.call(event)
      end

      def complete_turn(event)
        # Tools from before the join were shown from the snapshot; the ones
        # after it streamed. Either way the summary must not list them again.
        if @joined_mid_turn && event[:turn_summary]
          event = event.merge(turn_summary: event[:turn_summary].merge(tool_activity: []))
        end
        @renderer.call(event)
        # The turn's summary carries its last context estimate.
        @context_estimate = @view.context_status if @view.context_status
        refresh_status
        @running = false
        @joined_mid_turn = false
        close_question("(the turn ended)") if @question
      end

      def end_turn(message)
        @view.finish_thinking_spinner
        @screen.commit(message)
        @running = false
        @joined_mid_turn = false
        close_question("(the turn ended)") if @question
      end

      def own?(client_id) = !client_id.nil? && client_id == @client_id

      # The joining snapshot's session state: the worker's model and the
      # memories the session used.
      def take_session_state(state)
        @model_name = state[:model_name] if state[:model_name]
        @served_model = nil
        take_served_model(state[:served_model], state[:served_model_for], refresh: false)
        @memory_names = Array(state[:used_memory_names]) if state.key?(:used_memory_names)
        refresh_status
      end

      # The REPL's idle status line (model · ctx · memories) in the status
      # row, redrawn when its text changes.
      def refresh_status
        return unless status_line_enabled?

        served, served_for = @served_model
        segments = [@model_name ? status_model_text(@model_name, default_model_name, served: served, served_for: served_for) : "",
                    status_context_text(estimate: @context_estimate),
                    status_memory_text(@memory_names, MEMORY_STICKY_PREVIEW_LIMIT)].reject(&:empty?)
        rows = status_rows(segments, @screen.columns - 1)
        return if rows == @status_rows

        @status_rows = rows
        rows.empty? ? @screen.clear_slot(:status) : @screen.set_slot(:status, rows)
      end

      # What the worker's server said it served for a name (a generation, or
      # the join's session state); dropped when /model switches.
      def take_served_model(served, served_for, refresh: true)
        return unless served

        @served_model = [served, served_for]
        refresh_status if refresh
      end

      # The config's default model, as the worker's /model names it.
      def default_model_name
        @default_model_name ||= ModelProfile.required_model_name(nil)
      rescue StandardError
        nil
      end

      def reminder_origin?(origin) = origin[:client_id].to_s.start_with?("system:")

      CONTEXT_NOTE_PREVIEW = 60

      # "note from slack: <first line>", cut to one line.
      def context_note_line(label, text)
        lines = text.to_s.strip.split("\n")
        first = lines.first.to_s
        if first.length > CONTEXT_NOTE_PREVIEW
          first = "#{first[0, CONTEXT_NOTE_PREVIEW - 1]}…"
        elsif lines.size > 1
          first += " …"
        end
        paint("note from #{label || "?"}: #{first}", 2)
      end

      def reminder_line(reminders)
        names = Array(reminders).filter_map { |r| r.is_a?(Hash) ? r[:name] : r }
        names.empty? ? "reminder" : "reminder: #{names.join(", ")}"
      end

      def prompt_line(client_id, prompt)
        label = client_id ? CLIENT_LABELS.fetch(client_id.to_s.split(":", 2).first, "user") : "user"
        "#{paint("#{label}>", 35)} #{prompt}"
      end

      # A tool call from the snapshot: it has no action text, only the tool.
      def snapshot_tool_line(part)
        params = part[:params].to_s.strip
        params_suffix = params.empty? ? "" : " #{paint(params, 90)}"
        status = part[:status].to_s
        "#{paint('tool>', 36)} #{part[:tool]}#{params_suffix}: #{paint(status, status == "ok" ? 32 : 31)}" \
          "#{format_tool_image_suffix(part[:images])}"
      end
    end
  end
end
