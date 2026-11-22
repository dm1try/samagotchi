# frozen_string_literal: true

require_relative "reply_for"
require_relative "revise_anchor"
require_relative "verify_anchor"

module Samagotchi
  # What a turn points at: a Verify turn's claim (VerifyAnchor), a Revise
  # turn's draft (ReviseAnchor) and the surface its reply is for (ReplyFor,
  # an ask's reply_for). One carrier
  # through every layer a turn's input travels (chi web's POST /turn, the
  # Bridge, the input file, SessionInbox::Input, WorkerInbound::Prompt, a
  # failed turn's restore), so a new anchor is one field here. On the wire
  # and in the input file each is its own key ("verify", "revises"); a
  # missing or malformed one is nil. The Engine takes them as run_turn's
  # keywords (#kwargs): what each means is its own. What a layer does
  # with a member by kind (held for the turn's end, shown to a
  # participant) is that member's rule (TurnAnchors::RULES), never a
  # list of names.
  TurnAnchors = Data.define(:verify, :revises, :reply_for) do
    def self.from(value)
      return value if value.is_a?(self)

      fields = value.is_a?(Hash) ? value.to_h { |key, entry| [key.to_s, entry] } : {}
      new(verify: fields["verify"], revises: fields["revises"], reply_for: fields["reply_for"])
    end

    # A chi web POST …/turn body's anchors (the owner's composer, a
    # participant's): only the members whose rule takes them from there
    # (+turn_route+); the others are set by their own route alone.
    def self.from_turn_route(body)
      anchors = from(body)
      anchors.with(**self::RULES.reject { |_, rule| rule.turn_route }.to_h { |member, _| [member, nil] })
    end

    # Whether a parsed input file names an anchor whose rule holds it for
    # the turn's end (a Hash under its key, well-formed or not):
    # SessionInbox.turn_end_data? holds it.
    def self.named_in?(data) = self::RULES.any? { |member, rule| rule.holds && data[member.to_s].is_a?(Hash) }

    def initialize(verify: nil, revises: nil, reply_for: nil)
      super(verify: VerifyAnchor.from(verify), revises: ReviseAnchor.from(revises), reply_for: ReplyFor.from(reply_for))
    end

    def empty? = member_values.none?

    # The anchors given, each answering FEATURE (the worker's Bridge
    # feature it needs) and UNAVAILABLE (the refusal without it).
    def present = member_values.compact

    # The anchors given whose rule has an input file written for them only
    # when the reading worker's sidecar lists their FEATURE (+vouched+: the
    # no-Bridge fallback, SessionManager::Delivery).
    def vouched = self.class::RULES.filter_map { |member, rule| public_send(member) if rule.vouched }.compact

    # The body's and the input file's keys.
    def to_file = self.class.members.to_h { |member| [member.to_s, public_send(member)&.to_file] }.compact

    # A :prompt_restored event's fields.
    def to_h = self.class.members.to_h { |member| [member, public_send(member)&.to_h] }.compact

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
    def kwargs = self.class.members.to_h { |member| [member, public_send(member)] }.compact

    private

    def member_values = self.class.members.map { |member| public_send(member) }
  end

  # A member's rules: +holds+, an input file naming it waits for the
  # running turn's end (#named_in?: merged into that turn as a steer, the
  # anchor would be lost); +participant+, a participant sees its
  # participant_view (#participant_view; false: left out); +turn_route+,
  # chi web's POST …/turn takes it from a body (.from_turn_route; false:
  # its own route alone sets it); +vouched+, the no-Bridge fallback writes
  # its input file only for a worker whose sidecar lists its FEATURE
  # (#vouched; false: the file goes as it is).
  TurnAnchors::Rule = Data.define(:holds, :participant, :turn_route, :vouched)
  # One per member, in the members' order.
  TurnAnchors::RULES = {
    verify: TurnAnchors::Rule.new(holds: true, participant: true, turn_route: true, vouched: false),
    revises: TurnAnchors::Rule.new(holds: true, participant: true, turn_route: true, vouched: false),
    # An ask's (POST …/ask): its own turn, never shown to a participant.
    # A worker older than it would drop it from the file, so the file goes
    # only to one that vouches for it.
    reply_for: TurnAnchors::Rule.new(holds: true, participant: false, turn_route: false, vouched: true)
  }.freeze
end
