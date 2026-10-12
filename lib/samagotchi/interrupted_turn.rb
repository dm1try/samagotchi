# frozen_string_literal: true

module Samagotchi
  # The mark of a turn a worker checkpointed and never finished
  # (Session#interrupted_turn, saved as session.json's "interrupted_turn"):
  # TurnCheckpoint writes it with the turn's messages so far while the turn
  # runs; the turn's end saves without it; the next worker to start finds it
  # and settles the turn (Worker#settle_interrupted_turn).
  #
  # id: the turn's id (nil when unknown); started_at / at: iso8601, when the
  # turn began and when this checkpoint was taken; iteration: the loop
  # boundaries it had passed (Integer).
  InterruptedTurn = Data.define(:id, :started_at, :at, :iteration) do
    def initialize(id: nil, started_at: nil, at: nil, iteration: nil) = super

    # A saved record (string or symbol keys), an InterruptedTurn as it is;
    # nil for anything else.
    # @return [InterruptedTurn, nil]
    def self.from_file(raw)
      return raw if raw.is_a?(InterruptedTurn)
      return nil unless raw.is_a?(Hash)

      new(**members.to_h { |m| [m, raw.key?(m.to_s) ? raw[m.to_s] : raw[m]] })
    end

    # @return [Hash{String => Object}] string keys, unset fields left out
    def to_file = to_h.compact.transform_keys(&:to_s)

    # Seconds from the turn's start to this checkpoint (nil when unknown).
    # @return [Float, nil]
    def seconds
      return nil unless started_at && at

      (Time.iso8601(at) - Time.iso8601(started_at)).clamp(0, Float::INFINITY)
    rescue ArgumentError
      nil
    end
  end
end
