# frozen_string_literal: true

require "set"
require_relative "event_renderer"
require_relative "formatting"
require_relative "attached_view"
require_relative "question_prompt"
require_relative "../bridge_client"
require_relative "../session_commands"

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

      STATS_COMMAND = "/stats"
      RECAP_COMMAND = "/recap"
      PROMPT = "> "
      DETACH_COMMANDS = %w[/exit /quit].freeze
      STALE_WORKER = "this session's worker runs an older chi and can't run commands; " \
                     "restart it to use them (its turns still work)"
      ROLLBACK_HINT = "partial progress kept in context; !rollback restores the pre-turn state"
      # How much of the last answer a join shows.
      JOIN_ANSWER_LINES = 12
      JOIN_ANSWER_CHARS = 1200

      # Reads input lines on its own thread, so events keep rendering while
      # the user types, and hands each line (nil = Ctrl-D) or Ctrl-C to the
      # loop's queue. #reprompt makes it drop the open read and start again
      # with the current prompt (a question opened or closed); #prefill
      # starts it again with text already typed in (a failed prompt).
      class LineReader
        # Raised into the reader thread; only lands inside a read.
        class Reprompt < StandardError; end
        # Ends the reader from inside its read, so Reline restores the terminal.
        class Stop < StandardError; end

        # @param prompt [#call] -> the prompt for the next read
        # @param read [#call, nil] (prompt, prefill) -> line; defaults to
        #   Reline on a terminal, else $stdin
        def initialize(queue, prompt:, read: nil)
          @queue = queue
          @prompt = prompt
          @read = read || method(:read_line)
          @current = nil
          @prefill = nil
        end

        # @return [String, nil] the prompt of the read in progress
        attr_reader :current

        def start
          # Created masked (threads inherit the mask), so a Reprompt raised
          # before #run is entered waits for the first read too.
          Thread.handle_interrupt(Reprompt => :never, Stop => :never) { @thread = Thread.new { run } }
          @thread.report_on_exception = false
          self
        end

        def reprompt
          @thread&.raise(Reprompt)
        end

        # Start the read again with +text+ in it, unless something is typed
        # there already (that would be lost).
        # @return [Boolean] whether the text went in
        def prefill(text)
          return false unless line_empty?

          @prefill = text
          reprompt
          true
        end

        def stop
          return unless @thread&.alive?

          @thread.raise(Stop)
          @thread.join(0.5) || (@thread.kill && @thread.join(0.5))
        end

        private

        def run
          # A Reprompt may only interrupt the read itself; one that comes
          # while a line is being handed over waits for the next read (and
          # just restarts it). The mask is also inherited from #start.
          Thread.handle_interrupt(Reprompt => :never, Stop => :never) do
            loop do
              @current = @prompt.call
              prefill = @prefill
              @prefill = nil
              line = Thread.handle_interrupt(Reprompt => :immediate, Stop => :immediate) { @read.call(@current, prefill) }
              @queue << [:line, line]
              break if line.nil?
            rescue Reprompt
              next
            rescue Interrupt
              @queue << [:interrupt]
            end
          end
        rescue Stop
          nil
        end

        def read_line(prompt, prefill)
          return $stdin.gets&.chomp unless $stdin.tty?
          return Reline.readline(prompt, true) unless prefill

          previous_hook = Reline.pre_input_hook
          Reline.pre_input_hook = proc do
            Reline.insert_text(prefill)
            Reline.pre_input_hook = previous_hook
            previous_hook&.call
          end
          begin
            Reline.readline(prompt, true)
          ensure
            Reline.pre_input_hook = previous_hook
          end
        end

        def line_empty?
          return true unless $stdin.tty?

          Reline.line_buffer.to_s.strip.empty?
        rescue StandardError
          true
        end
      end

      # Prompt labels by the sender's client_id prefix.
      CLIENT_LABELS = { "web" => "web", "tui" => "tui", "system" => "reminder" }.freeze

      attr_reader :client_id, :recap

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
      def initialize(client:, screen:, client_id:, first_prompt: nil, first_command: nil, no_interrupt: false)
        @client = client
        @screen = screen
        @client_id = client_id
        @view = AttachedView.new(screen)
        @renderer = EventRenderer.new(@view)
        @shown_enqueued = Set.new
        @running = false
        @joined_mid_turn = false
        @attached = false
        @recap = nil
        @question = nil
        @answered_ids = Set.new
        @reader = nil
        @first_prompt = first_prompt
        @first_command = first_command
        @first_command_id = nil
        @no_interrupt = no_interrupt
        # Prompts this run sent, by enqueued_id: only those come back into
        # the input when their turn fails (a replayed event must not).
        @sent_ids = Set.new
        # A continue offer is pending: the prompt asks for the answer.
        @continue_offer = nil
        @model_name = nil
        @turn_continues = false
      end

      def running? = @running

      # Follow the session and read input until Ctrl-D, /exit or the worker
      # goes away. The worker keeps running after a detach.
      # @return [Symbol] :detached, :closed when the worker went away, or
      #   :failed when the first command (--model) didn't go through
      # @param input [#call, nil] prompt -> line (nil = Ctrl-D, raising
      #   Interrupt = Ctrl-C); defaults to Reline
      def run(input: nil)
        queue = Thread::Queue.new
        stream = @client.follow { |event| queue << [:event, event] }
        @reader = LineReader.new(queue, prompt: method(:prompt_text), read: input).start
        loop do
          kind, payload = next_item(queue)
          case kind
          when :event
            ended = safely_handle(payload)
            return ended if ended == :closed || ended == :failed
          when :line then return :detached if submit(payload) == :detach
          when :interrupt then interrupt
          end
        end
      ensure
        # The loop is over: end the read the reader still has open. Not under
        # the screen's lock: the reader may be waiting for it to draw. The
        # read takes its prompt away as it ends; clearing the editor slot
        # covers a reader that had to be killed.
        @reader&.stop
        @screen.clear_slot(:editor)
        stream&.close
      end

      # Render one Bridge event (string keys).
      # @return [Symbol, nil] :closed when the stream ended, :failed when the
      #   launch's first command didn't go through
      def handle_event(event)
        event = EventRenderer.symbolize(event)
        case event[:type]
        when :snapshot, :reset then return render_snapshot(event[:snapshot] || {}, reset: event[:type] == :reset)
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
        when :command_ran
          command_ran(event)
          return first_command_ran(event) if @first_command_id && event[:command_id] == @first_command_id
        when :reminder_injected then @screen.commit(reminder_line(event[:reminders]))
        when :continue_offered then offer_continue(event)
        when :continue_resolved then continue_resolved(event)
        when :input_merged
          count = event[:count].to_i
          @screen.commit("(#{count} message#{"s" unless count == 1} merged into the running turn)")
        when :question_requested then ask(event[:pending_question])
        when :question_answered then question_answered(event)
        when :question_cancelled
          close_question("(question cancelled)") if @question
        when :recap_ready then @recap = event[:recap]
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
        if line.nil?
          @view.finish_thinking_spinner
          @screen.commit("Detached; the session keeps running. Re-attach with: chi --attach #{@client.session_id}")
          return :detach
        end

        text = line.strip
        return answer_question(text) if @question
        return submit(nil) if DETACH_COMMANDS.include?(text)
        return send_command(continue_line(text)) if @continue_offer && !SessionCommands.command?(text)
        return if text.empty?

        command = text.split(/\s+/, 2).first
        if command == STATS_COMMAND
          show_stats
        elsif command == RECAP_COMMAND
          @screen.commit(@recap || "no recap yet: one comes after a quiet stretch, when recap: is configured")
        elsif SessionCommands.command?(text)
          send_command(text)
        else
          send_prompt(text)
        end
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
        return @screen.commit(STALE_WORKER) if reply.status == 404

        detail = reply.json&.fetch("detail", nil) || reply.json&.fetch("error", nil)
        @screen.commit("could not run the command (#{[reply.status, detail].compact.join(" ")})")
      end

      def command_ran(event)
        @model_name = event[:model_name] if event[:model_name]
        @screen.commit(prompt_line(event[:client_id], event[:line])) unless own?(event[:client_id])
        output = event[:output].to_s
        return if output.empty?

        if event[:status] == "busy"
          @screen.commit(output)
        elsif shell_line?(event[:line])
          @screen.commit(output)
        else
          @screen.commit("#{paint("model>", 36)} #{output}")
        end
      end

      def shell_line?(line)
        line.to_s.start_with?(SessionCommands::SHELL_BANG_PREFIX) && line.to_s.strip != SessionCommands::ROLLBACK_COMMAND
      end

      def offer_continue(event)
        @continue_offer = { context: event[:context], no_interrupt: event[:no_interrupt] }
        sync_prompt
      end

      # An answer shows as its command line (web> /continue yes); only a
      # prompt that dropped the offer needs saying.
      def continue_resolved(event)
        @continue_offer = nil
        if event[:decision] == "dropped"
          who = event[:client_id] ? CLIENT_LABELS.fetch(event[:client_id].to_s.split(":", 2).first, "another UI") : "another UI"
          @screen.commit("(the continue offer was dropped: #{own?(event[:client_id]) ? "you" : who} sent a new prompt)")
        end
        sync_prompt
      end

      def send_prompt(text)
        reply = if @no_interrupt
                  @client.post_turn(prompt: text, client_id: @client_id, no_interrupt: true)
                else
                  @client.post_turn(prompt: text, client_id: @client_id)
                end
        if reply.status == 202
          enqueued_id = reply.json&.fetch("enqueued_id", nil)
          @sent_ids << enqueued_id if enqueued_id
          return
        end

        detail = reply.json&.fetch("error", nil)
        @screen.commit("could not send the prompt (#{[reply.status, detail].compact.join(" ")})")
      end

      def show_stats
        metrics = @client.get_json("state")&.dig("session_state_snapshot", "metrics")
        @screen.commit(metrics ? format_session_metrics(EventRenderer.deep_symbolize_keys(metrics)) : "(no metrics: the worker did not answer)")
      end

      def prompt_text
        return paint("choice> ", 33) if @question
        return paint(CONTINUE_PROMPT, 33) if @continue_offer

        paint(PROMPT, 92)
      end

      # Show the question and switch the open prompt to answer it. The
      # question is output, not the notes slot: it stays in the scrollback
      # above the answer typed at choice> (the live question widget is a
      # later phase of the live-region plan).
      def ask(pending)
        return unless pending

        @view.finish_thinking_spinner
        @question = QuestionPrompt.new(pending)
        @screen.commit(@question.lines(paint: method(:paint), color: color_output?).join("\n"))
        sync_prompt
      end

      def answer_question(text)
        return dismiss_question if text.empty?

        answer = @question.parse(text)
        @screen.commit(answer.note) if answer.note
        return @screen.commit(answer.error) unless answer.ok?

        reply = @client.answer(id: @question.id, selected: answer.selected, freeform: answer.freeform)
        case reply.status
        when 200
          @answered_ids << @question.id
          close_question(nil)
        when 409 then close_question("(already answered in another UI)")
        else
          detail = reply.json&.fetch("detail", nil) || reply.json&.fetch("error", nil)
          @screen.commit("could not answer (#{[reply.status, detail].compact.join(" ")})")
        end
        nil
      end

      # An empty answer dismisses the question, as in the REPL: the tool
      # returns unanswered and the turn goes on. The :question_cancelled
      # every UI gets finds it already closed here.
      def dismiss_question
        reply = @client.dismiss_question(id: @question.id)
        case reply.status
        when 200 then close_question("(cancelled)")
        when 409 then close_question("(question already closed in another UI)")
        else
          # e.g. 404 from a worker older than the route: the question stays.
          detail = reply.json&.fetch("error", nil)
          @screen.commit("could not dismiss the question (#{[reply.status, detail].compact.join(" ")}); Ctrl-C cancels the turn")
        end
        nil
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
        close_question("(answered in another UI: #{picked})")
      end

      def close_question(message)
        @screen.commit(message) if message
        @question = nil
        sync_prompt
      end

      # Restart the open read when its prompt no longer fits (a question or a
      # continue offer opened or closed), first erasing the prompt Reline drew.
      def sync_prompt
        return unless @reader

        @screen.synchronize do
          next if @reader.current == prompt_text

          @screen.clear_slot(:editor)
          @reader.reprompt
        end
      end

      # Ctrl-C cancels the running turn (whoever started it); at an idle
      # prompt it only clears the line.
      def interrupt
        @client.cancel(reason: "ctrl_c") if @running
      end

      def render_snapshot(snapshot, reset:)
        @view.finish_thinking_spinner
        if @attached
          @screen.commit("(resynced with the session)") if reset
        else
          @attached = true
          render_join_header(Array(snapshot[:messages]))
        end
        @recap = snapshot[:recap]
        offer = snapshot[:continue_offer]
        had_offer = !@continue_offer.nil?
        @continue_offer = offer && { context: offer[:context], no_interrupt: offer[:no_interrupt] }
        sync_prompt if had_offer != !@continue_offer.nil?
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

        why = reply.status == 404 ? STALE_WORKER : "the worker answered #{reply.status}"
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
        @screen.commit("Attached to session #{@client.session_id} (#{exchange.size} messages). " \
                           "Ctrl-D detaches; the session keeps running.")
        last_user = exchange.rindex { |m| m[:role].to_s == "user" }
        return unless last_user

        @screen.commit(prompt_line(nil, exchange[last_user][:content]))
        answer = exchange[(last_user + 1)..].reverse.find { |m| m[:role].to_s != "user" }
        @screen.commit(last_lines(answer[:content].to_s)) if answer
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
        @recap = nil # the turn makes it stale
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
        @running = false
        @joined_mid_turn = false
        close_question(nil) if @question
      end

      def end_turn(message)
        @view.finish_thinking_spinner
        @screen.commit(message)
        @running = false
        @joined_mid_turn = false
        close_question(nil) if @question
      end

      def own?(client_id) = !client_id.nil? && client_id == @client_id

      def reminder_origin?(origin) = origin[:client_id].to_s.start_with?("system:")

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
        "#{paint('tool>', 36)} #{part[:tool]}#{params_suffix}: #{paint(status, status == "ok" ? 32 : 31)}"
      end
    end
  end
end
