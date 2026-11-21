# frozen_string_literal: true

require "time"

module Samagotchi
  # BlockFix's stamp on an answer's model message, apart from the rest so the
  # loops' allowlists (ChatLoop#plain, KernelLoop#sanitize_history) and
  # AnswerDisplay can name it without loading the request's side.
  module BlockFix
    # The answer message's display-only key (AnswerDisplay::DISPLAY_ONLY):
    # a list of {key:, fixed_key:, state:, reason:, at:}, one per block asked.
    STAMP = :block_fixes
    STATES = %w[fixed failed].freeze

    module_function

    # The answer message's stamp entries, with symbol keys (they come back
    # from disk with string keys).
    # @return [Array<Hash>]
    def stamps(message)
      return [] unless message.is_a?(Hash)

      list = message[STAMP] || message[STAMP.to_s]
      Array(list).filter_map do |entry|
        next unless entry.is_a?(Hash)

        entry.to_h { |k, v| [k.to_sym, v] }
      end
    end

    # The stamp entry that knows the block +key+ (by its key or its fixed
    # key), nil when none does.
    def stamp_for(message, key)
      stamps(message).find { |entry| entry[:key] == key || entry[:fixed_key] == key }
    end

    # A copy of +message+ with +entry+ added to a fresh stamp list.
    def with_stamp(message, entry)
      list = stamps(message).reject { |old| old[:key] == entry[:key] } + [entry]
      copy = message.reject { |k, _| k.to_s == STAMP.to_s }
      copy.merge(STAMP => list)
    end

    # One stamp entry.
    def entry(key:, state:, fixed_key: nil, reason: nil, at: Time.now)
      { key: key, fixed_key: fixed_key, state: state, reason: reason, at: at.utc.iso8601 }.compact
    end
  end
end
