# frozen_string_literal: true

require_relative "log"

module Samagotchi
  # The event trail: a SessionObserver subscriber (next to SessionMetrics)
  # that writes what happened in a session, in order, as `turn` records.
  # Both loops (native and chat) emit the same vocabulary, so every host
  # leaves the same trail. Event names are the observer's types.
  #
  # INFO carries sizes and timings, never the text of a prompt, answer or
  # tool output (DEBUG dumps are KernelLoop's). It runs under the observer's
  # lock: it only formats and appends (Log never blocks on rotation).
  class LogSubscriber
    TAG = :turn
    # One line each, with a few of their own fields (never text).
    ANNOUNCED = {
      turn_enqueued: %i[enqueued_id client_id],
      command_queued: %i[command_id client_id],
      command_ran: %i[command_id client_id status],
      input_merged: %i[count],
      prompt_restored: [],
      continue_offered: %i[no_interrupt],
      continue_resolved: [],
      context_added: %i[note_id source],
      reminder_injected: [],
      question_requested: [],
      question_answered: %i[id],
      question_cancelled: %i[id reason],
      generation_cancelled: %i[iteration],
      empty_answer_retry: %i[iteration attempt of finish_reason thinking_chars stopped_by]
    }.freeze

    # @param session_id [#call] the session the events are about (the
    #   Engine's current one), as the records' sid
    def initialize(session_id: -> {}, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @session_id = session_id
      @clock = clock
      @turn_started_at = nil
      @generation_started_at = {}
      @tool_started_at = {}
    end

    def call(event)
      type = event[:type]&.to_sym
      return unless type

      if respond_to?(handler = :"on_#{type}", true)
        send(handler, event)
      elsif ANNOUNCED.key?(type)
        log(:info, type, **event.slice(*ANNOUNCED[type]), **origin(event), **items(event))
      end
    rescue StandardError
      nil
    end

    private

    def on_turn_started(event)
      @turn_started_at = @clock.call
      @generation_started_at.clear
      @tool_started_at.clear
      log(:info, :turn_started, session: event[:session_id], prompt_chars: event[:prompt].to_s.length,
                                continue: event[:continue] || nil, **items(event), **origin(event))
    end

    def on_turn_completed(event)
      summary = event[:turn_summary] || {}
      log(:info, :turn_completed, ms: since(@turn_started_at), result_chars: summary[:output].to_s.length,
                                  tools: Array(summary[:tool_activity]).size,
                                  exhausted: summary[:exhausted] || nil, **origin(event))
    end

    # A plugin's steers by count and source, never their text.
    def on_pending_input_merged(event)
      steers = Array(event[:steers])
      log(:info, :pending_input_merged, **event.slice(:iteration, :count),
                                        steers: steers.empty? ? nil : steers.size,
                                        steer_sources: steers.empty? ? nil : steers.map { |s| s[:source] }.uniq.join(","),
                                        **origin(event))
    end

    def on_turn_canceled(event)
      log(:info, :turn_canceled, ms: since(@turn_started_at), reason: event[:cancellation_reason], **origin(event))
    end

    def on_turn_failed(event)
      log(:warn, :turn_failed, ms: since(@turn_started_at), error: event[:error_class], error_kind: event[:error_kind],
                               host: event[:host], retryable: event[:retryable],
                               msg: (event[:summary] || event[:message]).to_s[0, 300], **origin(event))
    end

    def on_generation_started(event)
      @generation_started_at[event[:iteration]] = @clock.call
      log(:debug, :generation_started, iteration: event[:iteration], profile: event[:profile],
                                       context_window: event[:context_window_tokens])
    end

    def on_generation_completed(event)
      ms = since(@generation_started_at.delete(event[:iteration]))
      log(:info, :generation_completed, iteration: event[:iteration], ms: ms,
                                        served_model: event[:served_model], requested_model: event[:requested_model],
                                        content_length: event[:content_length],
                                        thinking_chars: event[:thinking_chars], finish_reason: event[:finish_reason],
                                        stopped_by: event[:stopped_by])
      return unless event[:stopped_by]

      # A plugin cut this generation (stop_generation); the turn goes on.
      log(:info, :generation_stopped, iteration: event[:iteration], bundle: event[:stopped_by],
                                      reason: event[:stop_reason].to_s[0, 200], thinking_chars: event[:thinking_chars], ms: ms)
    end

    def on_generation_retrying(event)
      log(:warn, :generation_retrying, iteration: event[:iteration], attempt: event[:attempt],
                                       max_retries: event[:max_retries], delay_s: event[:next_delay],
                                       error: event[:error_class], msg: event[:error_message].to_s[0, 300])
    end

    def on_tool_call_started(event)
      @tool_started_at[[event[:iteration], event[:call_index]]] = @clock.call
    end

    def on_tool_call_completed(event)
      # A tool's output can be any bytes (invalid UTF-8 would fail the match).
      output = event[:output].to_s.scrub
      log(:info, :tool_call_completed, iteration: event[:iteration], tool: event[:tool],
                                       ms: since(@tool_started_at.delete([event[:iteration], event[:call_index]])),
                                       output_chars: output.length, truncated: event[:output_truncated] || nil,
                                       error: tool_error?(output) || nil)
    end

    def on_guardrail_warning(event)
      log(:warn, :guardrail_warning, label: event[:label], msg: event[:message].to_s[0, 300])
    end

    # A hook's notice to the user: who said it and what (its text is the
    # hook's, not the user's or the model's).
    def on_hook_notice(event)
      level = event[:level].to_s == "warn" ? :warn : :info
      log(level, :hook_notice, hook: event[:hook], msg: event[:text].to_s[0, 300])
    end

    # after_turn hooks presented the answer (AnswerDisplay): its size only
    # (none for the display: nil that says nothing was presented).
    def on_answer_display(event)
      log(:info, :answer_display, chars: event[:display].to_s.length) if event[:display]
    end

    # A card shown to the user (Engine#show_card): whose, which, and its
    # title (the body is the plugin's text; not logged).
    def on_card(event)
      log(:info, :card, source: event[:source], id: event[:id], actions: Array(event[:actions]).size,
                        msg: event[:title].to_s[0, 300])
    end

    def on_recap_ready(event)
      log(:info, :recap_ready, chars: event[:recap].to_s.length, generation: event[:generation], covered: event[:covered])
    end

    # "[read] Error: …" (the dispatch failed) or "[read]\nError: …" (the
    # tool said so), and an unknown tool's bare "Error: …".
    def tool_error?(output)
      output.match?(/\A(?:\[[^\]\n]*\]\s*)?Error:/)
    end

    def origin(event)
      client = event.dig(:origin, :client_id) if event[:origin].is_a?(Hash)
      client ? { client_id: client } : {}
    end

    def items(event)
      images = Array(event[:images]).size
      images.positive? ? { images: images } : {}
    end

    def since(started)
      started ? ((@clock.call - started) * 1000).round : nil
    end

    def log(level, event, **fields)
      Log.public_send(level, TAG, event, sid: @session_id.call, **fields)
    end
  end
end
