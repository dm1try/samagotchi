# frozen_string_literal: true

module Samagotchi
  # What a message sent to a running turn does when it arrives: wait for the
  # turn's next step boundary and go in there (the default), cut the running
  # generation short to go in now, or wait for the turn to end and run as a
  # turn of its own (see docs/configuration.md). The field travels as the
  # wire value name; a sender that names nothing gets the default.
  module Delivery
    NEXT_STEP = "next_step"
    CUT = "cut"
    QUEUE = "queue"
    VALUES = [NEXT_STEP, CUT, QUEUE].freeze

    # A body's delivery field as one of VALUES. Missing, empty or unknown:
    # NEXT_STEP (an older client, a hand-written request).
    # @param raw [Object] the wire value
    # @return [String] one of VALUES
    def self.parse(raw)
      raw.is_a?(String) && VALUES.include?(raw) ? raw : NEXT_STEP
    end

    # Whether it is the one every sender defaulting to a step boundary uses.
    def self.next_step?(value) = parse(value) == NEXT_STEP

    # Whether the running turn should be cut for it (only when the message
    # asks: nothing else cuts).
    def self.cut?(value) = parse(value) == CUT

    # Whether it waits for the turn to end and runs as a turn of its own.
    def self.queue?(value) = parse(value) == QUEUE
  end
end
