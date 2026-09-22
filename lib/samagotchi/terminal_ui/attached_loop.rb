# frozen_string_literal: true

require "set"
require_relative "event_renderer"
require_relative "formatting"
require_relative "attached_view"
require_relative "../bridge_client"

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
      # Commands that need the local Engine (server APIs for them are v2).
      UNAVAILABLE_COMMANDS = %w[/model /models /continue !rollback].freeze
      DETACH_COMMANDS = %w[/exit /quit].freeze

      # Reads input lines on its own thread, so events keep rendering while
      # the user types, and hands each line (nil = Ctrl-D) or Ctrl-C to the
      # loop's queue.
      class LineReader
        # @param read [#call, nil] prompt -> line; defaults to Reline on a
        #   terminal, else $stdin
        def initialize(queue, prompt:, read: nil)
          @queue = queue
          @prompt = prompt
          @read = read || method(:read_line)
        end

        def start
          @thread = Thread.new { run }
          @thread.report_on_exception = false
          self
        end

        def stop
          @thread&.kill
          @thread&.join(0.5)
        end

        private

        def run
          loop do
            line = @read.call(@prompt)
            @queue << [:line, line]
            break if line.nil?
          rescue Interrupt
            @queue << [:interrupt]
          end
        end

        def read_line(prompt)
          return $stdin.gets&.chomp unless $stdin.tty?

          Reline.readline(prompt, true)
        end
      end

      # Prompt labels by the sender's client_id prefix.
      CLIENT_LABELS = { "web" => "web", "tui" => "tui", "system" => "reminder" }.freeze

      attr_reader :client_id, :recap, :pending_question

      # @param client [BridgeClient]
      # @param screen [AttachedScreen]
      # @param client_id [String] this UI's id in the events ("tui:<pid>")
      def initialize(client:, screen:, client_id:)
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
        @pending_question = nil
      end

      def running? = @running

      # Follow the session and read input until Ctrl-D, /exit or the worker
      # goes away. The worker keeps running after a detach.
      # @param input [#call, nil] prompt -> line (nil = Ctrl-D, raising
      #   Interrupt = Ctrl-C); defaults to Reline
      def run(input: nil)
        queue = Thread::Queue.new
        stream = @client.follow { |event| queue << [:event, event] }
        reader = LineReader.new(queue, prompt: paint(PROMPT, 92), read: input).start
        loop do
          kind, payload = next_item(queue)
          case kind
          when :event then break if safely_handle(payload) == :closed
          when :line then break if submit(payload) == :detach
          when :interrupt then interrupt
          end
        end
      ensure
        reader&.stop
        stream&.close
      end

      # Render one Bridge event (string keys).
      # @return [Symbol, nil] :closed when the stream ended
      def handle_event(event)
        event = EventRenderer.symbolize(event)
        case event[:type]
        when :snapshot, :reset then render_snapshot(event[:snapshot] || {}, reset: event[:type] == :reset)
        when :turn_enqueued then show_enqueued(event)
        when :turn_started then start_turn(event)
        when :turn_completed then complete_turn(event)
        when :turn_canceled
          end_turn("turn cancelled (#{event[:cancellation_reason]})")
        when :turn_failed
          end_turn("turn failed: #{event[:message]} (#{event[:error_class]})")
        when :input_merged
          count = event[:count].to_i
          @screen.print_line("(#{count} message#{"s" unless count == 1} merged into the running turn)")
        when :question_requested then @pending_question = event[:pending_question]
        when :question_answered, :question_cancelled then @pending_question = nil
        when :recap_ready then @recap = event[:recap]
        when :stream_closed
          @view.finish_thinking_spinner
          @screen.print_line("Lost the session's worker (#{event[:reason]}). " \
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
        @screen.print_line("(could not render #{event["type"] || event[:type]}: #{e.class}: #{e.message})")
        nil
      end

      # @return [Symbol, nil] :detach to end the loop
      def submit(line)
        if line.nil?
          @view.finish_thinking_spinner
          @screen.print_line("Detached; the session keeps running. Re-attach with: chi --attach #{@client.session_id}")
          return :detach
        end

        text = line.strip
        return if text.empty?
        return submit(nil) if DETACH_COMMANDS.include?(text)

        command = text.split(/\s+/, 2).first
        if command == STATS_COMMAND
          show_stats
        elsif command == RECAP_COMMAND
          @screen.print_line(@recap || "no recap: worker sessions run without the idle recap for now")
        elsif UNAVAILABLE_COMMANDS.include?(command) || text.start_with?("!")
          @screen.print_line("#{command} is not available in attached mode yet")
        else
          send_prompt(text)
        end
        nil
      end

      def send_prompt(text)
        reply = @client.post_turn(prompt: text, client_id: @client_id)
        return if reply.status == 202

        detail = reply.json&.fetch("error", nil)
        @screen.print_line("could not send the prompt (#{[reply.status, detail].compact.join(" ")})")
      end

      def show_stats
        metrics = @client.get_json("state")&.dig("session_state_snapshot", "metrics")
        @screen.print_line(metrics ? format_session_metrics(EventRenderer.deep_symbolize_keys(metrics)) : "(no metrics: the worker did not answer)")
      end

      # Ctrl-C cancels the running turn (whoever started it); at an idle
      # prompt it only clears the line.
      def interrupt
        @client.cancel(reason: "ctrl_c") if @running
      end

      def render_snapshot(snapshot, reset:)
        @view.finish_thinking_spinner
        if @attached
          @screen.print_line("(resynced with the session)") if reset
        else
          @attached = true
          render_join_header(Array(snapshot[:messages]))
        end
        render_current_turn(snapshot[:current_turn])
        Array(snapshot[:queued]).each do |entry|
          next if own?(entry[:client_id])

          @shown_enqueued << entry[:enqueued_id]
          @screen.print_line("queued #{prompt_line(entry[:client_id], entry[:prompt])}")
        end
      end

      def render_join_header(messages)
        exchange = messages.select { |m| %w[user model assistant].include?(m[:role].to_s) }
        @screen.print_line("Attached to session #{@client.session_id} (#{exchange.size} messages). " \
                           "Ctrl-D detaches; the session keeps running.")
        last_user = exchange.rindex { |m| m[:role].to_s == "user" }
        return unless last_user

        @screen.print_line(prompt_line(nil, exchange[last_user][:content]))
        answer = exchange[(last_user + 1)..].reverse.find { |m| m[:role].to_s != "user" }
        @screen.print_line(answer[:content].to_s) if answer
      end

      def render_current_turn(turn)
        @running = !turn.nil?
        @joined_mid_turn = @running
        @pending_question = turn && turn[:pending_question]
        return unless turn

        @screen.print_line(prompt_line(turn.dig(:origin, :client_id), turn[:prompt]))
        tail = nil
        running_tool = nil
        Array(turn[:parts]).each do |part|
          case part[:kind]
          when "text" then tail = part[:text]
          when "tool"
            if part[:status] == "running"
              running_tool = part[:tool]
            else
              @screen.print_line(snapshot_tool_line(part))
            end
          when "input" then @screen.print_line("input> #{part[:text]}")
          end
        end
        @view.resume(tail: tail, tool: running_tool)
      end

      def show_enqueued(event)
        return if own?(event[:client_id])

        @shown_enqueued << event[:enqueued_id]
        @screen.print_line(prompt_line(event[:client_id], event[:prompt]))
      end

      def start_turn(event)
        @running = true
        @joined_mid_turn = false
        origin = event[:origin] || {}
        unless own?(origin[:client_id]) || @shown_enqueued.include?(origin[:enqueued_id])
          @screen.print_line(prompt_line(origin[:client_id], event[:prompt]))
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
        @pending_question = nil
      end

      def end_turn(message)
        @view.finish_thinking_spinner
        @screen.print_line(message)
        @running = false
        @joined_mid_turn = false
        @pending_question = nil
      end

      def own?(client_id) = !client_id.nil? && client_id == @client_id

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
