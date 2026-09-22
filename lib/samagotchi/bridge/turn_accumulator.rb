# frozen_string_literal: true

require_relative "../kernel_loop"

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
      TERMINAL_EVENTS = %i[turn_completed turn_canceled turn_failed].freeze

      def initialize(max_output_chars: KernelLoop::DEFAULT_MAX_TOOL_OUTPUT_CHARS)
        @max_output_chars = max_output_chars
        @mutex = Mutex.new
        @turn = nil
        @queued = []
        @merged_origins = []
        @recap = nil
      end

      def call(event)
        @mutex.synchronize { fold(event) }
      rescue StandardError
        nil # never break the running turn
      end

      # @return [Hash, nil] a copy of the turn in progress: prompt, origin,
      #   continue, ordered parts (thinking / text / tool / input / reminder),
      #   pending_question and the last event_seq folded in
      def current_turn
        @mutex.synchronize { @turn && Marshal.load(Marshal.dump(@turn)) }
      end

      # @return [String, nil] the last idle recap, until a turn makes it stale
      def recap
        @mutex.synchronize { @recap }
      end

      # @return [Array<Hash>] turns announced as queued that haven't started
      #   or been merged into a running turn yet
      def queued
        @mutex.synchronize { @queued.map(&:dup) }
      end

      private

      def fold(event)
        type = event[:type]
        case type
        when :turn_enqueued
          @queued << { enqueued_id: event[:enqueued_id], client_id: event[:client_id], prompt: event[:prompt] }
        when :recap_ready
          @recap = event[:recap]
        when :turn_started
          @recap = nil
          dequeue([event[:origin]])
          @turn = { prompt: event[:prompt], origin: event[:origin], continue: !!event[:continue],
                    parts: [], pending_question: nil }
        when :input_merged
          @merged_origins = Array(event[:origins])
          dequeue(@merged_origins)
        end
        return unless @turn

        fold_turn_event(event)
        if TERMINAL_EVENTS.include?(type)
          @turn = nil
          @merged_origins = []
        else
          @turn[:event_seq] = event[:event_seq] if event[:event_seq]
        end
      end

      def fold_turn_event(event)
        parts = @turn[:parts]
        case event[:type]
        when :generation_chunk
          if event.key?(:text)
            # Profile-split stream: thinking and visible text separately.
            append_text(event[:iteration], "thinking", event[:thinking])
            append_text(event[:iteration], "text", event[:text])
          else
            append_text(event[:iteration], "text", event[:content])
          end
        when :tool_call_started
          parts << { kind: "tool", iteration: event[:iteration], call_index: event[:call_index],
                     tool: event[:tool], params: event[:params], status: "running" }
        when :tool_call_completed
          tool = parts.reverse_each.find do |part|
            part[:kind] == "tool" && part[:iteration] == event[:iteration] && part[:call_index] == event[:call_index]
          end
          return unless tool

          output = event[:output].to_s
          capped = output.length > @max_output_chars
          tool[:status] = (event.dig(:activity, :status) || "ok").to_s
          tool[:output] = capped ? output[0, @max_output_chars] : output.dup
          tool[:output_truncated] = capped || !!event[:output_truncated]
        when :pending_input_merged
          parts << { kind: "input", iteration: event[:iteration], text: event[:content].to_s.dup, origins: @merged_origins }
          @merged_origins = []
        when :reminder_injected
          parts << { kind: "reminder", reminders: Array(event[:reminders]).map(&:dup) }
        when :question_requested
          @turn[:pending_question] = event[:pending_question]&.dup
        when :question_answered, :question_cancelled
          @turn[:pending_question] = nil
        end
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
