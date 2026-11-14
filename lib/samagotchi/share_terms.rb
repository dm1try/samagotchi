# frozen_string_literal: true

require_relative "delivery"
require_relative "worker_link"

module Samagotchi
  # What inviting a participant to a session now means (chi share, the
  # web's Invite, ctx-free: SessionAccess::Local and Web::ParticipantsAdmin
  # both ask it): their turns act in it under the owner's rules (every
  # grant is stamped Grants::PAIR_MODE), +warning+ the sentence that says
  # so, and +refusal+ (nil when an invite may go ahead) while the session's
  # live worker predates those turns (Delivery::PAIR_FEATURE): it would
  # refuse every turn of theirs, so no link is issued until it restarts.
  # One read of the live worker for both.
  ShareTerms = Data.define(:warning, :refusal) do
    # @param session [Session]
    # @param state_dir [String, nil] the sessions' state dir (nil: the default)
    # @return [ShareTerms]
    def self.of(session, state_dir: nil)
      id = session.id[0, 8]
      features = WorkerLink.live_features(session.id, state_dir: state_dir)
      if features && !features.include?(Delivery::PAIR_FEATURE)
        refusal = format(self::OLDER_WORKER_REFUSAL, id: id)
        return new(warning: refusal, refusal: refusal)
      end

      count = session.tool_output_count
      outputs = "#{count} tool output#{"s" unless count == 1} so far"
      new(warning: format(self::WARNING, id: id, outputs: outputs), refusal: nil)
    end
  end

  # The warning every invite shows: what a participant's turn does in the
  # session and how much its history holds.
  ShareTerms::WARNING = "%<id>s: a participant's turns act in this session with its tools (writes included; " \
                        "asks come to you) and read what its history holds (%<outputs>s)."
  # The refusal to invite anyone while the session's live worker predates
  # their turns (Delivery::PAIR_FEATURE): their link would be dead on arrival.
  ShareTerms::OLDER_WORKER_REFUSAL = "%<id>s: #{Delivery::OLDER_THAN_PAIR}: restart the session first " \
                                     "(chi sessions restart %<id>s), then invite them"
end
