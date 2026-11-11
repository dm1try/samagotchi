# frozen_string_literal: true

module Samagotchi
  # The sets of event types more than one place reads (the Worker, the
  # Bridge's observers, the TUI, the web), kept here once. The web's own
  # copies (app.js's stream handlers) are checked against these by
  # spec/events_drift_spec.rb.
  module Events
    # A turn is over: it completed, was canceled, or failed.
    TURN_END = %i[turn_completed turn_canceled turn_failed].freeze
    # Turn ends that leave the turn in the conversation: a failed turn's
    # prompt goes back to the composer instead, unless its work stayed
    # (#kept_turn?).
    TURN_KEPT = %i[turn_completed turn_canceled].freeze
    # The kinds of a running turn's parts (Bridge::TurnAccumulator), which a
    # joining UI replays as live events (a card part only in a finished
    # turn's drawing: a join takes its cards from CardStore).
    PART_KINDS = %w[generation thinking text tool input steer reminder notice card].freeze
    # Types no Engine emits that a UI handles: the Bridge's stream frames
    # and the one synthetic replay event (a prompt merged into the turn,
    # TurnAccumulator.replay_events).
    STREAM_FRAMES = %i[snapshot reset stream_closed].freeze
    SYNTHETIC = %i[merged_input].freeze

    # The client-facing lifetime of each event. Rows are drawn in the
    # conversation and survive reload; state updates the live UI; transient
    # is live-only; internal is not sent to clients.
    CLASSIFICATION = {
      after_generation: :internal,
      after_tool_call: :internal,
      after_turn: :internal,
      answer_display: :state,
      before_generation: :internal,
      before_tool_call: :internal,
      before_turn: :internal,
      card: :row,
      command_queued: :state,
      command_ran: :state,
      context_added: :row, # Reloaded from the session messages, not a turn fold or card store.
      context_status: :state,
      continue_offered: :state,
      continue_resolved: :state,
      empty_answer_retry: :row,
      generation_cancelled: :state,
      generation_chunk: :transient,
      generation_completed: :state,
      generation_progress: :internal,
      generation_retrying: :state, # Updates live retry status; a restart also removes invalidated chunks.
      generation_started: :state,
      guardrail_warning: :state, # Worker startup state; not a persistent conversation notice.
      hook_notice: :row,
      input_merged: :state,
      llm_context_edited: :row,
      merged_input: :row,
      objectives_updated: :state,
      participants_changed: :state,
      pending_input_merged: :row,
      plugin_init_finished: :state,
      plugin_init_started: :state,
      plugin_init_wait: :state,
      prompt_restored: :state,
      question_answered: :state,
      question_cancelled: :state,
      question_relay: :state,
      question_requested: :state,
      reasoning_history_refused: :internal,
      recap_ready: :state,
      reminder_injected: :row,
      reset: :state,
      sampling_refused: :internal,
      session_end: :internal,
      session_start: :internal,
      side_usage: :state,
      steer_cut: :row,
      stream_closed: :state,
      stream_resumed: :transient,
      stream_retrying: :transient,
      thinking_dropped: :transient,
      thinking_refused: :internal,
      tool_call_completed: :row,
      tool_call_started: :row,
      tool_dispatch_completed: :state,
      tool_dispatch_started: :state,
      turn_canceled: :row,
      turn_completed: :row,
      turn_dequeued: :state,
      turn_enqueued: :state,
      turn_failed: :row,
      turn_started: :row,
      used_memories_updated: :state,
      verdict_recorded: :state,
      worker_changed: :state,
      working_set_updated: :state
    }.freeze

    # Whether +event+ ends a turn that stays in the conversation: completed,
    # canceled, or failed with its work kept (turn_failed's kept_steps).
    def self.kept_turn?(event)
      TURN_KEPT.include?(event[:type]) || (event[:type] == :turn_failed && !event[:kept_steps].nil?)
    end
  end
end
