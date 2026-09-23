# frozen_string_literal: true

module Samagotchi
  # Context shown to the model as a quote above the user's own words, the
  # shape the web annotations use (annotations.js quoteBlock), minus their
  # source label: `pbpaste | chi send -m "same bug?" ID`.
  module ContextQuote
    # @param text [String, nil]
    # @return [String, nil] each line as "> line" ("> " dropped for an empty
    #   one), ending in a blank line so the message follows as is; nil when
    #   the text is blank
    def self.block(text)
      lines = text.to_s.gsub(/\r\n?/, "\n").split("\n", -1).map { |line| line.sub(/[[:space:]]+\z/, "") }
      lines.shift while lines.first&.empty?
      lines.pop while lines.last&.empty?
      return nil if lines.empty?

      "#{lines.map { |line| line.empty? ? ">" : "> #{line}" }.join("\n")}\n\n"
    end
  end
end
