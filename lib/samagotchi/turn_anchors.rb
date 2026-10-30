# frozen_string_literal: true

require_relative "revise_anchor"
require_relative "verify_anchor"

module Samagotchi
  # What a turn points at in an earlier turn: a Verify turn's claim
  # (VerifyAnchor) and a Revise turn's draft (ReviseAnchor). One carrier
  # through every layer a turn's input travels (chi web's POST /turn, the
  # Bridge, the input file, SessionInbox::Input, WorkerInbound::Prompt, a
  # failed turn's restore), so a new anchor is one field here. On the wire
  # and in the input file each is its own key ("verify", "revises"); a
  # missing or malformed one is nil. The Engine takes them as run_turn's
  # keywords (#kwargs): what each means is its own.
  TurnAnchors = Data.define(:verify, :revises) do
    def self.from(value)
      return value if value.is_a?(self)

      fields = value.is_a?(Hash) ? value.to_h { |key, entry| [key.to_s, entry] } : {}
      new(verify: fields["verify"], revises: fields["revises"])
    end

    # Whether a parsed input file names an anchor (a Hash under its key,
    # well-formed or not): SessionInbox.turn_end_data? holds it.
    def self.named_in?(data) = %w[verify revises].any? { |key| data[key].is_a?(Hash) }

    def initialize(verify: nil, revises: nil)
      super(verify: VerifyAnchor.from(verify), revises: ReviseAnchor.from(revises))
    end

    def empty? = verify.nil? && revises.nil?

    # The anchors given, each answering FEATURE (the worker's Bridge
    # feature it needs) and UNAVAILABLE (the refusal without it).
    def present = [verify, revises].compact

    # The body's and the input file's keys.
    def to_file = { "verify" => verify&.to_file, "revises" => revises&.to_file }.compact

    # A :prompt_restored event's fields.
    def to_h = { verify: verify&.to_h, revises: revises&.to_h }.compact

    # Engine#run_turn's keywords.
    def kwargs = { verify:, revises: }.compact

    # A participant's: they can't Revise (participant_access.rb, the Bridge).
    def without_revises = with(revises: nil)
  end
end
