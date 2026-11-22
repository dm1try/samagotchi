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
  # keywords (#kwargs): what each means is its own. What a layer does
  # with a member by kind (held for the turn's end, shown to a
  # participant) is that member's rule (TurnAnchors::RULES), never a
  # list of names.
  TurnAnchors = Data.define(:verify, :revises) do
    def self.from(value)
      return value if value.is_a?(self)

      fields = value.is_a?(Hash) ? value.to_h { |key, entry| [key.to_s, entry] } : {}
      new(verify: fields["verify"], revises: fields["revises"])
    end

    # Whether a parsed input file names an anchor whose rule holds it for
    # the turn's end (a Hash under its key, well-formed or not):
    # SessionInbox.turn_end_data? holds it.
    def self.named_in?(data) = self::RULES.any? { |member, rule| rule.holds && data[member.to_s].is_a?(Hash) }

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

    # What a participant sees of each anchor whose rule shows it to them
    # (its participant_view); a member without one is left out.
    def participant_view
      self.class.members.each_with_object({}) do |member, view|
        next unless self.class::RULES.fetch(member).participant

        shown = public_send(member)&.participant_view
        view[member.to_s] = shown unless shown.nil?
      end
    end

    # Engine#run_turn's keywords.
    def kwargs = { verify:, revises: }.compact
  end

  # A member's rules: +holds+, an input file naming it waits for the
  # running turn's end (#named_in?: merged into that turn as a steer, the
  # anchor would be lost); +participant+, a participant sees its
  # participant_view (#participant_view; false: left out).
  TurnAnchors::Rule = Data.define(:holds, :participant)
  # One per member, in the members' order.
  TurnAnchors::RULES = {
    verify: TurnAnchors::Rule.new(holds: true, participant: true),
    revises: TurnAnchors::Rule.new(holds: true, participant: true)
  }.freeze
end
