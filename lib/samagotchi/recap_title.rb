# frozen_string_literal: true

module Samagotchi
  # The auto title the recap reply leads with (IdleRecap::RecapPrompt::TITLE):
  # "Title: <2-6 words>", a blank line, then the recap. #split takes the
  # title line off, so the recap text the bubble, /recap, a continue's carry
  # note and the next "Earlier recap:" read never holds it. A title line
  # last is taken too (the spike's last-line arm put it there; a model may
  # drift). A title that isn't 2-6 words or names an actor is no title, but
  # its line still goes. Never raises.
  module RecapTitle
    LABEL = "Title:"
    # As long as a card's title shows on a phone without wrapping twice.
    MAX_CHARS = 60
    WORDS = (2..6)
    # "Title: Foo", "**Title:** Foo", "## Title: Foo" (a colon only: a
    # recap may open "Title-casing the headings…").
    LINE_RE = /\A[\s*_#>]*title[\s*_]*:[\s*_]*(?<title>.*)\z/i
    # An instruction echoed between the title and the recap (the spike's
    # "Blank line follows title."), or "(blank line)": dropped.
    ECHO_RE = /\A[\s*_(\[]*(?:a |the )?blank line\b[^\n]{0,40}\z/i
    # A "Recap:" label before the recap's first sentence: dropped, the
    # sentence kept.
    RECAP_LABEL_RE = /\A[\s*_#]*recap[\s*_]*:[\s*_]*/i
    # The recap prompt's actors (RecapPrompt::SYSTEM: no "the user", no "the
    # assistant", no "I", no "we"). A bare "User" or "Chi" stays: "User
    # settings page", "Chi web push devices" name things.
    ACTOR_RE = /\A(?:the\s+(?:user|assistant)(?:'s)?|(?:user|assistant)'s|i|we|you)(?=\s|\z)/i
    QUOTES = "\"'`“”‘’«»"

    # A reply split in two: +title+ nil when it has none (or none that
    # passes), +body+ the recap without the title line.
    Split = Data.define(:title, :body)

    module_function

    # @param text [String] the recap model's reply
    # @return [Split]
    def split(text)
      lines = text.to_s.strip.lines(chomp: true)
      if lines.first && LINE_RE.match?(lines.first)
        title = lines.shift[LINE_RE, :title]
        lines = lead_cleaned(lines)
      elsif lines.size > 1 && LINE_RE.match?(lines.last)
        title = lines.pop[LINE_RE, :title]
      else
        return Split.new(title: nil, body: text.to_s.strip)
      end
      Split.new(title: clean(title), body: lines.join("\n").strip)
    rescue StandardError
      Split.new(title: nil, body: text.to_s.strip)
    end

    # The title as a card shows it: markup, quotes and a closing period
    # gone, one line, cut at MAX_CHARS; nil when it isn't 2-6 words or
    # starts with an actor.
    def clean(raw)
      title = raw.to_s.gsub(/[*_#]+/, " ").gsub(/\s+/, " ").strip
      title = title.delete_prefix(title[0]).delete_suffix(title[-1]).strip while quoted?(title)
      title = title.sub(/[.。]+\z/, "").strip
      return nil unless WORDS.cover?(title.split.size)
      return nil if ACTOR_RE.match?(title)

      title.length > MAX_CHARS ? "#{title[0, MAX_CHARS - 1].rstrip}…" : title
    end

    def quoted?(title) = title.length > 1 && QUOTES.include?(title[0]) && QUOTES.include?(title[-1])

    # Blank lines, echoed instructions and a "Recap:" label before the recap.
    def lead_cleaned(lines)
      lines = lines.drop_while { |line| line.strip.empty? || ECHO_RE.match?(line) }
      return lines if lines.empty?

      first = lines.first.sub(RECAP_LABEL_RE, "")
      first.strip.empty? ? lead_cleaned(lines.drop(1)) : [first, *lines.drop(1)]
    end
  end
end
