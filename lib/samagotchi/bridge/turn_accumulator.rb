# frozen_string_literal: true

require_relative "../events"
require_relative "../kernel_loop"
require_relative "../steer"
require_relative "../tool_row_fields"
require_relative "turn_notice"

module Samagotchi
  class Bridge
    # Folds the event log into the state of the turn in progress, so a UI
    # that joins mid-turn can render all of it at once (the Bridge's snapshot
    # frame) instead of replaying events the ring buffer may have dropped.
    #
    # A persistent observer: #call runs under the SessionObserver's lock,
    # enqueue-cheap (appends to strings and arrays). The turn is cleared on
    # its terminal event, the same event that brings its messages into the
    # session, so a snapshot shows a turn in exactly one of the two.
    class TurnAccumulator
      # @param clock [#call] monotonic seconds: a tool call's duration
      def initialize(max_output_chars: KernelLoop::DEFAULT_MAX_TOOL_OUTPUT_CHARS,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @max_output_chars = max_output_chars
        @clock = clock
        @mutex = Mutex.new
        @turn = nil
        # When each running tool call started, by [iteration, call_index].
        @tool_started_at = {}
        @queued = []
        @queued_commands = []
        @merged_origins = []
        @recap = nil
        @continue_offer = nil
      end

      def call(event)
        @mutex.synchronize { fold(event) }
      rescue StandardError
        nil # never break the running turn
      end

      # @return [Hash, nil] a copy of the turn in progress: prompt, origin,
      #   continue, ordered parts (generation / thinking / text / tool /
      #   input / steer / reminder / notice), pending_question and the last event_seq folded
      #   in. A finished tool part keeps the live row's action and duration_ms
      #   too, a running one the time it has run so far (elapsed_ms), so a
      #   join times its row from its start. A notice part holds the event
      #   of one of the turn's rows (TurnNotice: a hook's notice, an
      #   empty-answer retry, a question and its answer), which a UI replays
      #   through its live handler.
      def current_turn
        @mutex.synchronize do
          next nil unless @turn

          turn = Marshal.load(Marshal.dump(@turn))
          now = @clock.call
          Array(turn[:parts]).each do |part|
            started_at = part[:kind] == "tool" && part[:status] == "running" && @tool_started_at[[part[:iteration], part[:call_index]]]
            part[:elapsed_ms] = ((now - started_at) * 1000).round if started_at
          end
          turn
        end
      end

      # The turn in progress as conversation messages, for a plugin's
      # ctx.messages mid-turn (plan O1): its prompt (with its images), the
      # model's text so far, and the lines merged into it, in order. Tool
      # calls and thinking are left out.
      # @return [Array<Hash>] [] with no turn running
      def current_messages
        @mutex.synchronize { @turn ? self.class.messages_of(@turn) : [] }
      end

      # @param turn [Hash] #current_turn's shape
      # @return [Array<Hash>] {role: "user"|"model", content:, images:}
      def self.messages_of(turn)
        messages = []
        text = +""
        flush = lambda do
          messages << { role: "model", content: text.dup } unless text.strip.empty?
          text.clear
        end
        unless turn[:prompt].nil?
          prompt = { role: "user", content: turn[:prompt].to_s }
          prompt[:images] = turn[:images] if turn[:images]
          messages << prompt
        end
        Array(turn[:parts]).each do |part|
          case part[:kind]
          when "text" then text << part[:text].to_s
          when "input"
            flush.call
            messages << { role: "user", content: part[:text].to_s }
          when "steer"
            flush.call
            messages << Steer.message(text: part[:text], source: part[:source])
          end
        end
        flush.call
        messages
      end

      # The turn in progress (#current_turn's shape, symbol keys) as the live
      # events that would have drawn it, in order, as turn_events.js
      # snapshotEvents replays it for the web (spec/shared/turn_snapshot.json
      # pins both): a generation_started per generation part (a join during
      # a hold shows the step the model is on), a generation_chunk per
      # thinking or text part (a
      # generation_completed closes text before the next step's), a tool's
      # tool_call_started and, once finished, its tool_call_completed (with
      # the live activity: action, tool, params, status), a merged_input
      # (the one synthetic type) per merged prompt, a steer-only
      # pending_input_merged per steer, a reminder_injected, and a notice
      # part's own event.
      # @param started_at [String, nil] the turn's start, on turn_started
      # @return [Array<Hash>] symbol keys and types; [] with no turn
      def self.replay_events(turn, started_at: nil)
        return [] unless turn

        started = { type: :turn_started, prompt: turn[:prompt], origin: turn[:origin], continue: !!turn[:continue] }
        started[:started_at] = started_at if started_at
        events = [with_images(started, turn[:images])]
        text_iteration = nil # a text part is open for this iteration
        close_text = lambda do
          events << { type: :generation_completed } unless text_iteration.nil?
          text_iteration = nil
        end
        Array(turn[:parts]).each do |part|
          case part[:kind]
          when "generation"
            close_text.call
            events << { type: :generation_started, iteration: part[:iteration] }
          when "thinking" then events << { type: :generation_chunk, text: "", thinking: part[:text], iteration: part[:iteration] }
          when "text"
            close_text.call if !text_iteration.nil? && text_iteration != part[:iteration]
            text_iteration = part[:iteration]
            events << { type: :generation_chunk, text: part[:text], thinking: "", iteration: part[:iteration] }
          when "tool"
            close_text.call
            events.concat(tool_replay_events(part))
          when "input"
            close_text.call
            events << { type: :merged_input, content: part[:text], origins: part[:origins] || [] }
          when "reminder"
            close_text.call
            events << { type: :reminder_injected, reminders: part[:reminders] || [] }
          when "notice"
            close_text.call
            notice = part[:event]
            events << notice.merge(type: notice[:type].to_sym) if notice.is_a?(Hash) && notice[:type]
          when "steer"
            close_text.call
            events << { type: :pending_input_merged, count: 0, content: nil, steers: [{ source: part[:source], text: part[:text] }] }
          end
        end
        events
      end

      def self.tool_replay_events(part)
        call = { iteration: part[:iteration], call_index: part[:call_index], tool: part[:tool] }
        call[:label] = part[:label] if part[:label]
        # Its row fields (ToolRowFields), each in its place: title and, for
        # an alias's call, the name the model used, also in the activity.
        title = part.slice(*ToolRowFields::ACTIVITY_KEYS).compact
        view = part.slice(*ToolRowFields::EVENT_KEYS).compact
        events = [{ type: :tool_call_started, **call, params: part[:params], **title, **view }]
        if part[:status] == "running"
          events.first[:elapsed_ms] = part[:elapsed_ms] unless part[:elapsed_ms].nil?
          return events
        end

        activity = { tool: part[:tool], status: part[:status], params: part[:params], **title }
        activity[:action] = part[:action] if part[:action]
        activity[:no_match] = true if part[:no_match]
        completed = { type: :tool_call_completed, **call, output: part[:output], output_truncated: !!part[:output_truncated],
                      activity: activity }
        completed[:duration_ms] = part[:duration_ms] unless part[:duration_ms].nil?
        completed[:diff] = part[:diff] if part[:diff]
        completed.merge!(view)
        events << with_images(completed, part[:images])
      end
      private_class_method :tool_replay_events

      # +event+ with images: when there are any.
      def self.with_images(event, images)
        Array(images).empty? ? event : event.merge(images: images)
      end
      private_class_method :with_images

      # @return [String, nil] the last idle recap, until a turn makes it stale
      def recap
        @mutex.synchronize { @recap }
      end

      # @return [Hash, nil] a copy of the pending continue offer ({context:,
      #   no_interrupt:}), from :continue_offered until :continue_resolved
      def continue_offer
        @mutex.synchronize { @continue_offer && Marshal.load(Marshal.dump(@continue_offer)) }
      end

      # @return [Array<Hash>] turns announced as queued that haven't started
      #   or been merged into a running turn yet
      def queued
        @mutex.synchronize { @queued.map(&:dup) }
      end

      # @return [Array<Hash>] commands queued for after the running turn
      #   (command_queued with waits, not a card's action) that haven't run
      #   or been dropped yet:
      #   {command_id:, client_id:, line:}, in arrival order
      def queued_commands
        @mutex.synchronize { @queued_commands.map(&:dup) }
      end

      private

      def fold(event)
        type = event[:type]
        case type
        when :command_queued
          # A card's action shows as its card, never as a line (the UIs skip it live).
          @queued_commands << event.slice(:command_id, :client_id, :line) if event[:waits] && !event[:card]
        when :command_ran
          @queued_commands.reject! { |entry| entry[:command_id] == event[:command_id] } if event[:queued]
        when :turn_enqueued
          queued = { enqueued_id: event[:enqueued_id], client_id: event[:client_id], prompt: event[:prompt] }
          queued[:images] = event[:images] if event[:images]
          @queued << queued
        when :recap_ready
          # One collected just as a turn started describes the chat before it.
          @recap = event[:recap] unless @turn
        when :continue_offered
          @continue_offer = { context: event[:context], no_interrupt: !!event[:no_interrupt] }
        when :continue_resolved
          @continue_offer = nil
        when :turn_started
          @recap = nil
          dequeue([event[:origin]])
          @turn = { prompt: event[:prompt], origin: event[:origin], continue: !!event[:continue],
                    parts: [], pending_question: nil }
          @tool_started_at = {}
          @turn[:images] = event[:images] if event[:images]
        when :input_merged
          @merged_origins = Array(event[:origins])
          dequeue(@merged_origins)
        end
        return unless @turn

        fold_turn_event(event)
        if Events::TURN_END.include?(type)
          @turn = nil
          @merged_origins = []
        elsif event[:event_seq]
          @turn[:event_seq] = event[:event_seq]
        end
      end

      def fold_turn_event(event)
        parts = @turn[:parts]
        case event[:type]
        when :generation_started
          parts << { kind: "generation", iteration: event[:iteration] }
        when :generation_chunk
          if event.key?(:text)
            # Profile-split stream: thinking and visible text separately.
            append_text(event[:iteration], "thinking", event[:thinking])
            append_text(event[:iteration], "text", event[:text])
          else
            append_text(event[:iteration], "text", event[:content])
          end
        when :generation_retrying
          # A dropped stream's step asked again: what it streamed is void.
          if event[:restarted]
            parts.reject! { |part| %w[thinking text].include?(part[:kind]) && part[:iteration] == event[:iteration] }
          end
        when :tool_call_started
          part = { kind: "tool", iteration: event[:iteration], call_index: event[:call_index],
                   tool: event[:tool], params: event[:params], status: "running" }
          part[:label] = event[:label] if event[:label]
          ToolRowFields::KEYS.each { |key| part[key] = event[key] if event[key] }
          parts << part
          @tool_started_at[[event[:iteration], event[:call_index]]] = @clock.call
        when :tool_call_completed
          tool = parts.reverse_each.find do |part|
            part[:kind] == "tool" && part[:iteration] == event[:iteration] && part[:call_index] == event[:call_index]
          end
          return unless tool

          output = event[:output].to_s
          capped = output.length > @max_output_chars
          tool[:status] = (event.dig(:activity, :status) || "ok").to_s
          tool[:no_match] = true if event.dig(:activity, :no_match)
          tool[:output] = capped ? output[0, @max_output_chars] : output.dup
          tool[:output_truncated] = capped || !!event[:output_truncated]
          tool[:images] = event[:images] if event[:images]
          tool[:diff] = event[:diff] if event[:diff]
          action = event.dig(:activity, :action)
          tool[:action] = action.to_s if action
          # As the live row times it (EventRenderer): from tool_call_started,
          # less an approval wait.
          started_at = @tool_started_at.delete([event[:iteration], event[:call_index]])
          tool[:duration_ms] = [((@clock.call - started_at) * 1000) - event[:waited_ms].to_f, 0].max.round if started_at
        when :pending_input_merged
          # A steer-only merge (count 0) has no user part: the origins stay
          # for the user lines' own merge.
          unless event[:content].nil?
            parts << { kind: "input", iteration: event[:iteration], text: event[:content].to_s.dup, origins: @merged_origins }
            @merged_origins = []
          end
          Array(event[:steers]).each do |steer|
            parts << { kind: "steer", iteration: event[:iteration], source: steer[:source].to_s, text: steer[:text].to_s.dup }
          end
        when :reminder_injected
          parts << { kind: "reminder", reminders: Array(event[:reminders]).map(&:dup) }
        when :question_requested
          @turn[:pending_question] = event[:pending_question]&.dup
        when :question_answered, :question_cancelled
          @turn[:pending_question] = nil
        when :question_relay
          pending = @turn[:pending_question]
          if pending && pending[:id].to_s == event[:id].to_s
            relayed_to = event[:relayed_to]
            @turn[:pending_question] = relayed_to ? pending.merge(relayed_to: relayed_to) : pending.except(:relayed_to)
          end
        end
        parts << { kind: "notice", event: TurnNotice.slice(event) } if TurnNotice.notice?(event)
      end

      def append_text(iteration, kind, text)
        return if text.nil? || text.empty?

        last = @turn[:parts].last
        if last && last[:kind] == kind && last[:iteration] == iteration
          last[:text] << text
        else
          @turn[:parts] << { kind: kind, iteration: iteration, text: String.new(text) }
        end
      end

      def dequeue(origins)
        ids = origins.filter_map { |origin| origin.is_a?(Hash) ? origin[:enqueued_id] : nil }
        @queued.reject! { |entry| ids.include?(entry[:enqueued_id]) } unless ids.empty?
      end
    end
  end
end
