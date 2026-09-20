# frozen_string_literal: true

module Samagotchi
  # Extracts a short "what am I doing" phrase from a model's thinking stream
  # for a single generation iteration.
  #
  # Primary source: an explicit "TURN: <phrase>" first line, which the model
  # is instructed to emit (see Engine#turn_preamble_instruction, Qwen only).
  # Fallback: the first sentence of the accumulated thinking text, used when
  # the model didn't comply with the TURN: convention.
  #
  # One instance covers one generation iteration; callers reset (replace) the
  # instance at the same points the thinking-tail preview is reset.
  class TurnPreamble
    TURN_LINE_RE = /\ATURN:\s*(.+)\z/i.freeze
    SENTENCE_END_RE = /[.!?]/.freeze
    MAX_PHRASE_LENGTH = 80

    def initialize
      @buffer = +""
      @turn_phrase = nil
    end

    # Feed the next slice of thinking-lane text (from the :thinking field of a
    # generation_chunk event).
    def feed(thinking_chunk)
      return if thinking_chunk.nil? || thinking_chunk.empty?

      @buffer << thinking_chunk
      capture_turn_line if @turn_phrase.nil?
    end

    # @return [String, nil] the TURN: phrase, the first-sentence fallback, or
    #   nil if no thinking text has streamed yet.
    def phrase
      return @turn_phrase unless @turn_phrase.nil?
      return nil if @buffer.empty?

      first_sentence_fallback
    end

    private

    def capture_turn_line
      first_line = @buffer.each_line.first.to_s
      return unless first_line.include?("\n") || @buffer.length >= 120

      match = TURN_LINE_RE.match(first_line.strip)
      @turn_phrase = cap(match[1].strip) if match
    end

    def first_sentence_fallback
      sentence_end = @buffer.index(SENTENCE_END_RE)
      text = sentence_end ? @buffer[0..sentence_end] : @buffer
      cap(text.strip)
    end

    def cap(text)
      text.length > MAX_PHRASE_LENGTH ? text[0, MAX_PHRASE_LENGTH] : text
    end
  end
end
