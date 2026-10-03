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
    # @param turn_id [String, nil] that turn's answer: the last one between
    #   the prompt carrying this turn id and the next prompt (a queued turn's
    #   page re-reads after the next turn ran). An unknown or missing id:
    #   the newest answer.
    # @return [Hash, nil] the raw message (not a copy), or nil
    def find(messages, turn_id: nil)
      list = Array(messages)
      list = turn_slice(list, turn_id.to_s) || list unless turn_id.to_s.empty?
      list.reverse_each { |m| return m if answer?(m) }
      nil
    end

    # The messages of the turn whose prompt carries +turn_id+, from its
    # prompt up to the next prompt (merged input and steers stay in it), or
    # nil when no prompt carries it.
    def turn_slice(list, turn_id)
      start = list.rindex { |m| Steer.turn_prompt?(m) && (m[:turn_id] || m["turn_id"]).to_s == turn_id }
      return nil unless start

      stop = list.each_index.find { |i| i > start && Steer.turn_prompt?(list[i]) } || list.size
      list[start...stop]
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
