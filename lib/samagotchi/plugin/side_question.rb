# frozen_string_literal: true

require "json"
require_relative "../idle_recap"

module Samagotchi
  module Plugin
    # The request behind ctx.ask_model (plan D7): the conversation as a
    # transcript, filtered like the idle recap's (IdleRecap::TranscriptFilter:
    # no system prompt, no tool calls or outputs, no thinking, an image as a
    # line naming it), then the question. One user message holds both, so a
    # conversation that ends on a user turn (a running turn's prompt) doesn't
    # run into the question.
    module SideQuestion
      DEFAULT_SYSTEM = "You answer a question about the conversation below, on the side. Answer briefly and " \
                       "don't continue the conversation's task."
      # The most transcript one request sends: the tail is kept.
      MAX_TRANSCRIPT_CHARS = 32_000

      module_function

      # @param messages [Array<Hash>] the conversation (symbol or string keys)
      # @param prompt [String] the question
      # @param system [String, nil] instructions; DEFAULT_SYSTEM by default
      # @return [Array<Hash>] chat messages: {role: "system"}, {role: "user"}
      def request(messages:, prompt:, system: nil)
        system = system.to_s.strip.empty? ? DEFAULT_SYSTEM : system.to_s
        transcript = transcript(messages)
        question = prompt.to_s.strip
        user = if transcript.empty?
                 question
               else
                 "<conversation>\n#{transcript}\n</conversation>\n\n#{question}"
               end
        [{ role: "system", content: system }, { role: "user", content: user }]
      end

      # "User: …" and "Assistant: …" paragraphs; the tail when it is long.
      # @return [String]
      def transcript(messages)
        text = stringified(messages).filter_map do |message|
          line = IdleRecap::TranscriptFilter.build([message])
          next if line.strip.empty?

          "#{message["role"] == "user" ? "User" : "Assistant"}: #{line}"
        end.join("\n\n")
        return text if text.length <= MAX_TRANSCRIPT_CHARS

        "[earlier conversation left out]\n\n#{text[-MAX_TRANSCRIPT_CHARS..]}"
      end

      # String keys, as TranscriptFilter reads a saved session.
      def stringified(messages)
        JSON.parse(JSON.generate(Array(messages)))
      rescue StandardError
        []
      end
    end
  end
end
