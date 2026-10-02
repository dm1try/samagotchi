# frozen_string_literal: true

require "securerandom"

module Samagotchi
  # A parent worker's relays of its delegates' approvals: relay id → the
  # child and its question, and the answer this worker's own question flow
  # took from a UI. A child believes a relayed answer only when it asked
  # this table for it, through the parent's Bridge (POST relay/status).
  #
  # Memory only: never in the session file, the event log, a snapshot, a
  # log line or the environment, so nothing but this worker's question flow
  # writes it. Entries are dropped KEEP_SECONDS after they settle.
  class RelayDesk
    KEEP_SECONDS = 600

    # @param clock [#call] monotonic seconds (specs)
    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock = clock
      @mutex = Mutex.new
      @relays = {}
    end

    # @return [String] the new relay's id (a UUID: an id, not a secret)
    def open(child_id:, child_question_id:)
      id = SecureRandom.uuid
      @mutex.synchronize do
        prune
        @relays[id] = { child_id: child_id.to_s, child_question_id: child_question_id.to_s, state: "open",
                        answer: nil, by: nil, settled_at: nil }
      end
      id
    end

    # The parent's user (or a parent agent) answered the relay card.
    # @param by [String] "user" or "parent_agent"
    # @return [Boolean] false when the relay isn't open (first answer wins)
    def record(id, selected_indices: [], freeform: nil, dismissed: false, by:)
      @mutex.synchronize do
        relay = @relays[id.to_s]
        next false unless relay && relay[:state] == "open"

        relay.merge!(state: "answered", by: by.to_s, settled_at: @clock.call,
                     answer: { selected_indices: Array(selected_indices), freeform: freeform, dismissed: !!dismissed })
        true
      end
    end

    # The relay ended with no answer (a Stop, the child gone or answered).
    def close(id)
      @mutex.synchronize do
        relay = @relays[id.to_s]
        relay&.merge!(state: "closed", settled_at: @clock.call) if relay && relay[:state] == "open"
      end
      nil
    end

    # @return [Hash, nil] {child_id:, child_question_id:, state:, answer:, by:}
    def status(id)
      @mutex.synchronize do
        prune
        @relays[id.to_s]&.except(:settled_at)&.then { |relay| Marshal.load(Marshal.dump(relay)) }
      end
    end

    private

    def prune
      now = @clock.call
      @relays.delete_if { |_, relay| relay[:settled_at] && now - relay[:settled_at] > KEEP_SECONDS }
    end
  end
end
