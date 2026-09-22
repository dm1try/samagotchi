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
