# frozen_string_literal: true

require_relative "message_time"
require_relative "steer"

module Samagotchi
  # The session owner's own words: the one rule for what may act on a
  # session's conversation by itself (toolkit suggest, attached context's
  # candidates). A participant's turn and a review session never do.
  module OwnerPrompt
    module_function

    # The owner's own prompt: a user line the Engine kept for a turn (it
    # carries the turn's id), or TurnCheckpoint's line for a turn killed
    # before its first boundary (stamped, no id). A !command's output, a
    # declined continue's reason and KernelLoop's recovery prompt are
    # neither; steers, notes and reminders carry their kind.
    def message?(message)
      field(message, :role).to_s == "user" &&
        !Steer.participant_author?(field(message, :author)) &&
        !%w[input steer note reminder].include?(field(message, :kind).to_s) &&
        !field(message, :preserve_literals) &&
        !(field(message, :turn_id) || field(message, MessageTime::KEY)).nil?
    end

    # Whether a turn by +author+ in +session+ is the owner's own: not a
    # participant's, not in a review session.
    def turn?(session:, author:)
      !session&.review? && !Steer.participant_author?(author)
    end

    def field(hash, key)
      return nil unless hash.is_a?(Hash)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
    private_class_method :field
  end
end
