# frozen_string_literal: true

module Samagotchi
  # A parsed verdict line from a Verify turn's final answer.
  Verdict = Data.define(:verdict, :reason) do
    LINE = /\AVerdict:\s*(confirmed|refuted|unclear)\b\s*(?:—|–|-)\s*(.+?)\s*\z/i
    MARKDOWN = /(?:\*\*|__|`)/

    def self.parse(text)
      line = text.to_s.lines.reverse_each.find { |candidate| !candidate.strip.empty? }
      return unless line

      normalized = line.strip.gsub(MARKDOWN, "")
      match = LINE.match(normalized)
      return unless match

      new(verdict: match[1].downcase, reason: match[2].strip)
    end
  end
end
