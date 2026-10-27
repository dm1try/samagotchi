# frozen_string_literal: true

require_relative "steer"
require_relative "turn_origin"
require_relative "verify_anchor"
require_relative "participant_mode"

module Samagotchi
  # A Verify fresh child's own field (Session#verify_fresh; VerifyFresh
  # starts one): who asked for it (+author+, a participant's "p:<id>", nil
  # for the owner), the rules a participant's turns run under in it
  # (+mode+, "review" or "pair": their grant's mode in the parent when it
  # started, ParticipantMode.live_for), the parent's verdict it checks again
  # (+of+, that verdict's check_turn_id) and the claim (+anchor+, a
  # VerifyAnchor). Every turn of a participant's child is theirs
  # (#origin_for): their author, their boundary, their cap. A field that is
  # there but doesn't read as one is INVALID, whose author is no
  # participant's: its turns are refused, never run as the owner's.
  VerifyFreshOrigin = Data.define(:author, :mode, :of, :anchor) do
    # @param value [VerifyFreshOrigin, Hash, nil] the session file's form too
    # @return [VerifyFreshOrigin, nil] nil for nil; INVALID for anything
    #   else that doesn't read as one
    def self.of(value)
      return value if value.is_a?(self)
      return nil if value.nil?
      return self::INVALID unless value.is_a?(Hash)

      field = ->(key) { value.key?(key) ? value[key] : value[key.to_s] }
      author = field.call(:author)
      mode = field.call(:mode)
      anchor = VerifyAnchor.from(field.call(:anchor))
      of = field.call(:of)
      return self::INVALID unless anchor && of.is_a?(String) && !of.empty?
      return new(author: nil, mode: nil, of: of, anchor: anchor) if author.nil?
      return self::INVALID unless author.is_a?(String) && Steer.participant_author?(author) && self::MODES.include?(mode)

      new(author: author, mode: mode, of: of, anchor: anchor)
    end

    # Whether a participant asked for it (the owner's child runs as any
    # delegate child).
    def participant? = Steer.participant_author?(author)

    # The boundary a participant's turn runs under here: :pair only when
    # saved so, else :review (fail closed).
    def turn_mode = mode == ParticipantMode::PAIR.to_s ? ParticipantMode::PAIR : ParticipantMode::REVIEW

    # +origin+ with this child's requester as its author: every turn of a
    # participant's child is theirs, whoever typed it; the owner's child
    # keeps the origin as it is.
    # @param origin [TurnOrigin]
    # @return [TurnOrigin]
    def origin_for(origin)
      origin = TurnOrigin.of(origin)
      participant? ? origin.with(author: author) : origin
    end

    # The session file's form.
    def to_file = { "author" => author, "mode" => mode, "of" => of, "anchor" => anchor&.to_file }.compact
  end

  # A verify_fresh field that doesn't read: a participant author nobody
  # has, so the worker refuses its turns ("revoked"), under the review
  # boundary.
  # The modes a participant's child may be saved with (a constant of
  # VerifyFreshOrigin: one inside the Data.define block would be Samagotchi's).
  VerifyFreshOrigin::MODES = [ParticipantMode::REVIEW.to_s, ParticipantMode::PAIR.to_s].freeze

  VerifyFreshOrigin::INVALID = VerifyFreshOrigin.new(author: "#{Steer::PARTICIPANT_PREFIX}invalid", mode: "review",
                                                     of: nil, anchor: nil)
end
