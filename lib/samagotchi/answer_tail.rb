# frozen_string_literal: true

require_relative "context_note"
require_relative "output_formatter"
require_relative "steer"
require_relative "turn_note"

module Samagotchi
  # "The last answer a UI shows": the newest message the web's history
  # shows as an assistant message. One rule for the worker's Bridge (`/tail`,
  # Engine#last_answer_message) and the web's disk path, so the two can't
  # drift. Any change to what the web shows as an answer goes through here.
  module AnswerTail
    module_function

    # @param messages [Array<Hash>] a session's messages (symbol keys from
    #   disk or the Engine, string keys from a Bridge snapshot)
    # @return [Hash, nil] the raw message (not a copy), or nil
    def find(messages)
      Array(messages).reverse_each { |m| return m if answer?(m) }
      nil
    end

    # Shown as an assistant message: role assistant or model, not a context
    # note, a steer or a no-answer turn's marker, and some text left once the
    # wire-format markup is stripped (a tool-call-only step has none).
    def answer?(message)
      return false unless message.is_a?(Hash)
      return false if ContextNote.note?(message) || Steer.steer?(message) || TurnNote.empty_answer(message)
      return false unless %w[assistant model].include?((message[:role] || message["role"]).to_s)

      !OutputFormatter.strip_markup((message[:content] || message["content"]).to_s).empty?
    end
  end
end
