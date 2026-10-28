# frozen_string_literal: true

module Samagotchi
  # A claim selected in an earlier turn, carried only by a Verify turn.
  VerifyAnchor = Data.define(:turn_id, :quote) do
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    QUOTE_MAX = 200

    def self.from(value)
      return value if value.is_a?(self)
      return nil unless value.is_a?(Hash)

      fields = value.to_h { |key, entry| [key.to_s, entry] }
      return nil unless fields.keys.sort == %w[quote turn_id]

      turn_id = fields["turn_id"]
      quote = fields["quote"]
      return nil unless turn_id.is_a?(String) && UUID.match?(turn_id)
      return nil unless quote.is_a?(String) && quote.length.between?(1, QUOTE_MAX) && !quote.strip.empty?

      new(turn_id:, quote:)
    end

    def to_h = { turn_id:, quote: }

    def to_file = { "turn_id" => turn_id, "quote" => quote }
  end

  VerifyAnchor::FEATURE = "verify"
  VerifyAnchor::UNAVAILABLE = {
    "error" => "verify_unavailable",
    "detail" => "this session's worker predates Verify turns; restart this session to use Verify"
  }.freeze

  def VerifyAnchor.worker_unavailable?(features) = !features.nil? && !features.include?(VerifyAnchor::FEATURE)
end
