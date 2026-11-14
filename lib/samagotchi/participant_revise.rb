# frozen_string_literal: true

require_relative "answer_tail"
require_relative "steer"
require_relative "verify_anchor"

module Samagotchi
  # Whether a participant may Revise a turn: the rule chi web checks at the
  # send (Web::ParticipantAccess#participant_revise_refusal) and the worker
  # again at the stamp (TurnStages::VerifyAnchors#revision_target), from the
  # author the server stamped on each opening, never the body's. A turn
  # they may revise is one of their own, answered, not a Verify turn, with
  # only their own turns after it. The owner's Revise is never checked here.
  # See docs/internals/participants.md (Turns).
  module ParticipantRevise
    module_function

    # A turn's opening as the rule counts it: a prompt or a wake turn's
    # note, never a stored `!shell` line (the owner's, which a participant
    # doesn't see: ParticipantView drops it, so it counts for nothing).
    def opening?(message) = Steer.turn_prompt?(message) && !Steer.shell_line?(message)

    # Why +author+ ("p:<id>") may not revise the turn +turn_id+ in
    # +messages+, or nil when they may:
    # - :not_own: no opening carries that id, or it isn't theirs, has no
    #   answer, or is a Verify turn (a missing turn answers the same as
    #   someone else's: no existence oracle);
    # - :overtaken: a turn opening after it isn't theirs (the owner's,
    #   another participant's, a wake turn's).
    # +before+: the Revise turn's own id, whose opening and everything after
    # it are ignored (the worker's check, the turn already in the messages).
    # @return [Symbol, nil]
    def refusal(messages, turn_id:, author:, before: nil)
      list = Array(messages)
      author = Steer.sender_author(author)
      return :not_own unless author

      start = list.rindex { |m| opening?(m) && field(m, :turn_id).to_s == turn_id.to_s }
      return :not_own unless start && own_answered?(list, start, author)

      list[(start + 1)..].each do |message|
        next unless opening?(message)
        break if before && field(message, :turn_id).to_s == before.to_s
        return :overtaken unless Steer.sender_author(field(message, :author)) == author
      end
      nil
    end

    def own_answered?(list, start, author)
      opening = list[start]
      return false unless Steer.sender_author(field(opening, :author)) == author
      return false if VerifyAnchor.marks?(field(opening, :verify))

      # Its slice, as AnswerTail.turn_slice bounds one: up to the next prompt.
      stop = list.each_index.find { |i| i > start && Steer.turn_prompt?(list[i]) } || list.size
      list[start...stop].any? { |message| AnswerTail.answer?(message) }
    end

    def field(message, key) = message[key] || message[key.to_s]
  end
end
