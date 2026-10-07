# frozen_string_literal: true

module Samagotchi
  # The sets of event types more than one place reads (the Worker, the
  # Bridge's observers, the TUI, the web), kept here once. The web's own
  # copies (app.js's stream handlers, turn_events.js's snapshotEvents) are
  # checked against these by spec/events_drift_spec.rb.
  module Events
    # A turn is over: it completed, was canceled, or failed.
    TURN_END = %i[turn_completed turn_canceled turn_failed].freeze
    # Turn ends that leave the turn in the conversation: a failed turn's
    # prompt goes back to the composer instead, unless its work stayed
    # (#kept_turn?).
    TURN_KEPT = %i[turn_completed turn_canceled].freeze
    # The kinds of a running turn's parts (Bridge::TurnAccumulator), which a
    # joining UI replays as live events.
    PART_KINDS = %w[generation thinking text tool input steer reminder notice].freeze
    # Types no Engine emits that a UI handles: the Bridge's stream frames
    # and the web's one synthetic replay event (a prompt merged into the
    # turn, turn_events.js snapshotEvents).
    STREAM_FRAMES = %i[snapshot reset stream_closed].freeze
    SYNTHETIC = %i[merged_input].freeze

    # Whether +event+ ends a turn that stays in the conversation: completed,
    # canceled, or failed with its work kept (turn_failed's kept_steps).
    def self.kept_turn?(event)
      TURN_KEPT.include?(event[:type]) || (event[:type] == :turn_failed && !event[:kept_steps].nil?)
    end
  end
end
