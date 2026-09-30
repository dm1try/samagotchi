# frozen_string_literal: true

require_relative "../kernel_loop"
require_relative "../steer"
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
      TERMINAL_EVENTS = %i[turn_completed turn_canceled turn_failed].freeze

      def initialize(max_output_chars: KernelLoop::DEFAULT_MAX_TOOL_OUTPUT_CHARS)
        @max_output_chars = max_output_chars
        @mutex = Mutex.new
        @turn = nil
        @queued = []
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
      #   continue, ordered parts (thinking / text / tool / input / steer /
      #   reminder / notice), pending_question and the last event_seq folded
      #   in. A notice part holds the event of one of the turn's rows
      #   (TurnNotice: a hook's notice, an empty-answer retry, a question and
      #   its answer), which a UI replays through its live handler.
      def current_turn
        @mutex.synchronize { @turn && Marshal.load(Marshal.dump(@turn)) }
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

      private

      def fold(event)
        type = event[:type]
        case type
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
          @turn[:images] = event[:images] if event[:images]
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
          part = { kind: "tool", iteration: event[:iteration], call_index: event[:call_index],
                   tool: event[:tool], params: event[:params], status: "running" }
          part[:label] = event[:label] if event[:label]
          part[:title] = event[:title] if event[:title]
          parts << part
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
          tool[:images] = event[:images] if event[:images]
          tool[:diff] = event[:diff] if event[:diff]
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
