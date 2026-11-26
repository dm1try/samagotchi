# frozen_string_literal: true

require_relative "llm/errors"
require_relative "llm/utf8_scrub"

module Samagotchi
  # Marks an error whose message tells the user what to change (an image
  # the turn can't use, no model configured): a turn it fails shows that
  # message as it is, never as a chi error (FailureLine.chi_error?).
  module UserError
  end

  # The one line a failed turn shows (every UI, through the end event's
  # summary: TurnEndings#failed_event) and its note keeps (TurnNote.failed:
  # the reload's line, the model's; TurnFlow#prompt_turn_failed too), and
  # whether chi itself failed. Light on purpose: the TUI's and chi web's
  # thin loads reach it through TurnFlow.
  module FailureLine
    # A failed turn's error_kind when chi itself failed (.chi_error?).
    CHI_ERROR = :chi_error
    # The longest error message a chi error's line quotes.
    MESSAGE_MAX = 300

    module_function

    # Whether +error+ is chi's own failure: neither the provider's
    # (LLM::ProviderError, its own kind and summary) nor one that tells the
    # user what to change (UserError).
    def chi_error?(error) = !error.is_a?(LLM::ProviderError) && !error.is_a?(UserError)

    # A provider error's summary, a UserError's message, else "chi error:
    # <message> (<Class>); details in samagotchi.log". Its first line, read
    # as UTF-8: the message may hold the bytes that failed.
    # @return [String]
    def for(error)
      return error.summary if error.respond_to?(:summary)
      return error.message unless chi_error?(error)

      message = LLM::Utf8Scrub.call(error.message.to_s).lines.first.to_s.strip[0, MESSAGE_MAX]
      "chi error: #{message} (#{error.class.name}); details in samagotchi.log"
    end
  end
end
