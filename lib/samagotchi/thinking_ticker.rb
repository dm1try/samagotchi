# frozen_string_literal: true

module Samagotchi
  # Live thinking as one sentence at a time, for the terminal: the Ruby side
  # of the web's sentences.js + thinking_ticker.js, with the same rules.
  #
  # Sentence boundary: [.!?…] optionally followed by closing quotes or
  # brackets, then whitespace; a newline is also a boundary, and so is the end
  # of the text (the ticker corrects itself on the next chunk). A bare list
  # number ("1.", "118.") at the start of a line is a marker, not a sentence.
  # Whitespace is collapsed. A trailing fragment longer than MAX_LEN (a
  # code-like run with no punctuation) counts as the current sentence.
  #
  # The ticker changes its line no sooner than DWELL seconds after the last
  # change, so a fast stream doesn't flicker: in between, the newest sentence
  # waits and #tick shows it when the dwell is over.
  class ThinkingTicker
    MAX_LEN = 160
    DWELL = 1.5
    BOUNDARY = /([.!?…][)"'\]]*)([[:space:]]|\z)|\n/
    LIST_MARKER = /\A\d{1,4}\.\z/

    # @return [Array<String>] every complete sentence of +text+ (the end
    #   counts as a boundary), collapsed, blanks skipped
    def self.sentences(text)
      raw = text.to_s
      found = []
      start = 0
      raw.to_enum(:scan, BOUNDARY).each do
        m = Regexp.last_match
        candidate = raw[start...(m.begin(0) + m[1].to_s.length)]
        # A list number is no sentence: keep reading from the same start.
        next if LIST_MARKER.match?(candidate.strip)

        collapsed = collapse(candidate)
        found << collapsed unless collapsed.empty?
        start = m.end(0)
      end
      found
    end

    # The newest complete sentence of +text+, else the trailing fragment when
    # longer than +max_len+, else "".
    def self.current_sentence(text, max_len: MAX_LEN)
      last = sentences(text).last
      return last if last

      fragment = collapse(text)
      fragment.length > max_len ? fragment : ""
    end

    def self.collapse(text)
      text.to_s.gsub(/[[:space:]]+/, " ").strip
    end

    attr_reader :line

    # @param clock [#call] seconds, monotonic
    def initialize(clock:, dwell: DWELL)
      @clock = clock
      @dwell = dwell
      reset
    end

    # Forget the line (a new generation).
    def reset
      @line = ""
      @pending = nil
      @changed_at = nil
    end

    # Show the newest sentence of +text+ now, or keep it pending for the
    # dwell. @return [Boolean] whether the line changed
    def feed(text)
      candidate = self.class.current_sentence(text)
      return false if candidate.empty?

      if candidate == @line
        @pending = nil
        false
      elsif @line.empty? || due?
        show(candidate)
      else
        @pending = candidate
        false
      end
    end

    # Show a pending sentence once the dwell is over.
    # @return [Boolean] whether the line changed
    def tick
      return false unless @pending && due?

      show(@pending)
    end

    private

    def due?
      @changed_at.nil? || @clock.call - @changed_at >= @dwell
    end

    def show(candidate)
      @line = candidate
      @pending = nil
      @changed_at = @clock.call
      true
    end
  end
end
