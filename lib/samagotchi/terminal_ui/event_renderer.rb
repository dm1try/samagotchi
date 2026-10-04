# frozen_string_literal: true

require_relative "formatting"

module Samagotchi
  class TerminalUI
    # Renders one UI's view of Engine turn events: the thinking spinner while
    # the model generates, a `tool>` line per completed tool call, and the
    # answer (with any tool activity not already shown) from :turn_completed's
    # turn_summary, and how a turn ended. It is the `on_event:` sink the REPL
    # hands Engine#run_turn, and renders what attached mode gets over the
    # Bridge.
    #
    # Drawing is delegated to a +view+ (an AttachedView in both TUIs). The
    # renderer keeps
    # only per-turn bookkeeping that must come from the events themselves:
    # which tool lines were already streamed, and when each tool call started.
    # Events that came over the Bridge as JSON (string keys) are symbolized first.
    class EventRenderer
      def initialize(view, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @view = view
        @clock = clock
        @streamed_tool_activity = Hash.new(0)
        @tool_started_at = {}
        # Card ids shown so far (across turns): one shown again is updated.
        @card_ids = Set.new
        @turn_continues = false
      end

      # Whether the running turn continues an earlier one (a continue or a
      # reminder turn): set from :turn_started, or by a UI that joined the
      # turn mid-way. A canceled one gets no rollback hint.
      attr_writer :turn_continues

      # Deep-convert a string-keyed event (JSON from the Bridge) to the local
      # shape: symbol keys and a symbol :type. Other values stay as they are.
      def self.symbolize(event)
        event = deep_symbolize_keys(event)
        event[:type] = event[:type].to_sym if event[:type].is_a?(String)
        event
      end

      def self.deep_symbolize_keys(value)
        case value
        when Hash then value.to_h { |k, v| [k.is_a?(String) ? k.to_sym : k, deep_symbolize_keys(v)] }
        when Array then value.map { |v| deep_symbolize_keys(v) }
        else value
        end
      end

      def call(event)
        event = self.class.symbolize(event) if event.key?("type")
        case event[:type]
        when :turn_started
          begin_turn
          @turn_continues = event[:continue] ? true : event[:prompt].nil?
          Array(event[:images]).each { |ref| @view.print_line(@view.format_image_line(ref)) }
        when :generation_started
          @view.generation_feedback_started(event)
        when :generation_retrying
          @view.generation_feedback_retrying(event)
        when :generation_chunk
          @view.generation_feedback_chunk(event)
        when :tool_call_started
          # A joined running call (a snapshot's replay) started elapsed_ms ago.
          @tool_started_at[tool_call_key(event)] = @clock.call - (event[:elapsed_ms].to_f / 1000)
          @view.tool_call_feedback_started(event)
        when :tool_call_completed
          @view.clear_generation_retry
          @view.tool_call_feedback_completed(event)
          # A replayed row (a join) carries its duration (nil: unknown).
          measured = tool_duration_ms(event)
          render_streamed_tool_activity(event[:activity], duration_ms: event.fetch(:duration_ms, measured), images: event[:images],
                                                          diff: event[:diff])
        when :generation_completed, :generation_cancelled, :tool_dispatch_started
          @view.generation_feedback_finished
        when :pending_input_merged
          render_merge(event)
        when :empty_answer_retry
          @view.finish_thinking_spinner
          @view.print_line(@view.format_empty_retry_line(event))
        when :turn_completed
          render_turn_summary(event[:turn_summary]) if event[:turn_summary]
        when :turn_canceled
          @view.finish_thinking_spinner
          @view.print_line(@view.turn_canceled_line(event[:cancellation_reason], event[:duration_ms], by: event[:cancelled_by]))
          @view.print_line(@view.turn_end_hint(Formatting::ROLLBACK_HINT)) unless @turn_continues
        when :turn_failed
          # A provider error's one-line summary, else the message (an image
          # that couldn't be used).
          @view.finish_thinking_spinner
          @view.print_line(@view.turn_failed_line(event[:summary] || event[:message], event[:duration_ms]))
        when :guardrail_warning
          @view.print_line(self.class.load_warning_line(event))
        when :hook_notice
          @view.print_line(self.class.hook_notice_line(event))
        when :card
          render_card(event)
        # A turn waits for plugins' slow setup before its first request.
        when :plugin_init_wait
          @view.init_wait_feedback(event)
        end
      end

      # Print a card (a :card event or a snapshot's card) as a framed block;
      # one whose id was shown before is printed again, marked (updated).
      # @param updated [Boolean] marked (updated) anyway (a snapshot's card)
      def render_card(card, updated: false)
        id = card[:id].to_s
        updated ||= !id.empty? && @card_ids.include?(id)
        @card_ids << id unless id.empty?
        @view.print_line(@view.card_block(card, updated: updated))
      end

      # @return [Boolean] whether a card with this id was shown here
      def card_shown?(id) = @card_ids.include?(id.to_s)

      # What failed to load, labelled by what it is: guardrails (the
      # default) or plugins.
      def self.load_warning_line(event)
        "#{event[:label] || "guardrails"}> #{event[:message]}"
      end

      # A hook's notice as one line: "<bundle>> text" for a bundle hook,
      # "hook> text" for a config or turn hook (a warn one says so).
      # @param event [Hash] :hook_notice event or a snapshot part with
      #   hook:, text:, level:
      def self.hook_notice_line(event)
        # chi's own notices name themselves with a bare word (thinking).
        label = event[:hook].to_s[/\(bundle (.+)\)\z/, 1] || event[:hook].to_s[/\A[a-z][a-z0-9-]*\z/] || "hook"
        text = event[:text].to_s
        text = "warning: #{text}" if event[:level].to_s == "warn"
        "#{label}> #{text}"
      end

      # A plugin's init task (chi.init) as one line: "<bundle>> <label>…"
      # as it starts, "<bundle>> ✓ <summary>" when it is done. A failed
      # one is a warn card, not a line.
      # @return [String, nil]
      def self.init_line(event)
        case event[:type].to_s
        when "plugin_init_started" then "#{event[:bundle]}> #{event[:label]}…"
        when "plugin_init_finished"
          return nil unless event[:ok]

          "#{event[:bundle]}> ✓ #{event[:summary] || "#{event[:label]}: done"}"
        end
      end

      # Start a turn's bookkeeping and reset the view's per-turn feedback.
      # Also called directly by REPL paths that drive the kernel without
      # Engine#run_turn (so no :turn_started).
      def begin_turn
        @streamed_tool_activity = Hash.new(0)
        @tool_started_at = {}
        @view.reset_turn_feedback
      end

      # Render a finished turn: tool activity the stream did not already show,
      # the answer, and the iteration-limit notice.
      # @param summary [Hash] Engine#turn_summary
      def render_turn_summary(summary)
        @view.finish_thinking_spinner
        @view.capture_context_status(summary[:context_status])
        Array(summary[:tool_activity]).each do |activity|
          next if consume_streamed_tool_activity(activity)

          @view.print_line(@view.format_tool_activity_line(activity))
        end
        # No answer: chi's muted notice, never an empty answer line.
        if summary[:empty_answer]
          @view.print_line(@view.format_empty_answer_line(summary.dig(:empty_answer, :retries)))
        else
          @view.print_line(summary[:output])
        end
        @view.print_line("iteration limit reached") if summary[:resumable]
      end

      # Steering merged into the running turn: the answer it follows first
      # (the turn summary shows only the last one), then the note, then a
      # line per plugin steer (none for a steer-only merge).
      def render_merge(event)
        @view.finish_thinking_spinner
        @view.print_line(event[:answer]) unless event[:answer].to_s.strip.empty?
        count = event[:count].to_i
        @view.print_line("(#{count} message#{"s" unless count == 1} merged into the running turn)") if count.positive?
        Array(event[:steers]).each { |steer| @view.print_line(@view.format_steer_line(source: steer[:source], text: steer[:text])) }
      end

      private

      def render_streamed_tool_activity(activity, duration_ms:, images: nil, diff: nil)
        return if activity.nil?

        @streamed_tool_activity[tool_activity_key(activity)] += 1
        line = @view.format_tool_activity_line(activity, duration_ms: duration_ms)
        line += @view.format_tool_image_suffix(images) if images&.any?
        line += @view.format_tool_diff_suffix(diff) if diff
        @view.print_line(line)
      end

      def consume_streamed_tool_activity(activity)
        key = tool_activity_key(activity)
        count = @streamed_tool_activity[key]
        return false unless count.positive?

        @streamed_tool_activity[key] = count - 1
        true
      end

      def tool_activity_key(activity)
        [activity[:action], activity[:tool], activity[:params], activity[:status]].map(&:to_s).join("|")
      end

      def tool_call_key(event)
        [event[:iteration].to_i, event[:call_index].to_i, event[:tool].to_s]
      end

      # From tool_call_started, less an approval wait (waited_ms): an asked
      # row counts from the answer.
      def tool_duration_ms(event)
        started_at = @tool_started_at.delete(tool_call_key(event))
        started_at && [((@clock.call - started_at) * 1000.0) - event[:waited_ms].to_f, 0.0].max
      end
    end
  end
end
