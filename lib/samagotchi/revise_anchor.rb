# frozen_string_literal: true

require_relative "verify_anchor"

module Samagotchi
  # The earlier turn a Revise turn rewrites the answer of, carried only by
  # a Revise turn (TurnAnchors). Its stamp on the turn's opening message
  # is display metadata, never in the prompt (Engine#revision_target).
  ReviseAnchor = Data.define(:turn_id) do
    def self.from(value)
      return value if value.is_a?(self)
      return nil unless value.is_a?(Hash)

      fields = value.to_h { |key, entry| [key.to_s, entry] }
      return nil unless fields.keys == %w[turn_id]

      turn_id = fields["turn_id"]
      return nil unless turn_id.is_a?(String) && VerifyAnchor::UUID.match?(turn_id)

      new(turn_id:)
    end

    def to_h = { turn_id: }

    def to_file = { "turn_id" => turn_id }
  end

  ReviseAnchor::FEATURE = "revise"
  ReviseAnchor::UNAVAILABLE = {
    "error" => "revise_unavailable",
    "detail" => "this session's worker predates Revise turns; restart this session to use Revise"
  }.freeze
end
