# frozen_string_literal: true

require_relative "client_id"
require_relative "steer"

module Samagotchi
  # Who queued a turn: the client that sent it (+client_id+, ClientId), the
  # input file's id (+enqueued_id+, the reply's and the events' key) and,
  # for a participant's, its +author+ ("p:<id>"; none for the owner's).
  # Engine#run_turn's, the Worker's and GuardrailWiring's. On the wire (a
  # turn's boundary events, Bridge SSE, the inbox JSON's own fields) an
  # origin stays the Hash it always was: #to_h writes it, .from reads it
  # back, so a value that crosses a boundary is turned there, once.
  TurnOrigin = Data.define(:client_id, :enqueued_id, :author) do
    def initialize(client_id: nil, enqueued_id: nil, author: nil) = super

    # An origin from what a boundary carries: a TurnOrigin as it is, a Hash
    # (symbol or string keys: an event, an SSE line, a spec) as one; nil for
    # nil, an empty Hash and anything else (no sender named).
    # @return [TurnOrigin, nil]
    def self.from(value)
      return value if value.is_a?(TurnOrigin)
      return nil unless value.is_a?(Hash)

      field = ->(key) { value.key?(key) ? value[key] : value[key.to_s] }
      origin = new(client_id: field.call(:client_id), enqueued_id: field.call(:enqueued_id), author: field.call(:author))
      origin.to_h.empty? ? nil : origin
    end

    # Whether a participant queued the turn (Steer.participant_author?: any
    # author but none or the owner's).
    def participant? = Steer.participant_author?(author)

    # The author when a participant's (Steer.sender_author), else nil.
    def participant_author = Steer.sender_author(author)

    # The participant's id (Steer.participant_id: its author without "p:"),
    # nil for the owner's.
    def participant_id = participant_author && Steer.participant_id(participant_author)

    # What sent the turn, by its client (ClientId.origin): "client",
    # "reminder", "delegate", "review"...
    def source = ClientId.origin(client_id)

    # Whether a human sent the turn (ClientId.human?: a missing client is).
    def human? = ClientId.human?(client_id)

    # The wire form: only the fields set, as a turn's origin always went out.
    def to_h = super.compact
  end

  # No sender named: for a reader that wants an origin either way.
  TurnOrigin::NONE = TurnOrigin.new
end
