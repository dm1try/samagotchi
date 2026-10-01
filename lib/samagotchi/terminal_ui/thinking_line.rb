# frozen_string_literal: true

require_relative "../output_formatter"
require_relative "../thinking_ticker"
require_relative "formatting"

module Samagotchi
  class TerminalUI
    # What the model is doing, as one sentence for the activity slot: the
    # newest sentence of the generation's thinking or of its text, through a
    # ThinkingTicker (so it changes at most once per dwell). Both TUIs use it
    # in place of the raw tail of the stream.
    #
    # A chunk carries :text (and :thinking): both loops split their stream,
    # for every profile. A chunk without them (an older worker) has its raw
    # :content, markup stripped, stand for thinking. A switch of lane starts the next sentence from the new
    # lane's text; the line shown keeps the label of the lane it came from.
    class ThinkingLine
      include Formatting

      # Enough text to find the newest sentence in; scanning grows with it.
      BUFFER_LIMIT = 2000
      # The Qwen turn preamble's first line ("TURN: reading the config").
      TURN_PREFIX = /\ATURN:\s*/i
      # Where a raw stream's thinking ends: a boundary, so its last words
      # don't run into the answer's first.
      THOUGHT_CLOSE = %r{<channel\|>|</think>}

      def initialize(clock:, dwell: ThinkingTicker::DWELL)
        @ticker = ThinkingTicker.new(clock: clock, dwell: dwell)
        reset
      end

      # A new generation.
      def reset
        @ticker.reset
        @lane = nil
        @buffer = +""
        @label = nil
        @pending_label = nil
      end

      # @return [Boolean] whether the line changed
      def chunk(event)
        # The Bridge's TurnAccumulator reads the lanes by the same rule.
        if event.key?(:text)
          changed = add(:thinking, event[:thinking])
          add(:writing, event[:text]) || changed
        else
          add(:thinking, event[:content], raw: true)
        end
      end

      # A turn joined mid-way: the newest thinking or text part so far.
      def resume(lane, text)
        add(lane, text.to_s, raw: true)
      end

      # @return [Boolean] whether a pending sentence came up
      def tick
        return false unless @ticker.tick

        @label = @pending_label
        true
      end

      def empty? = @ticker.line.empty?

      # @return [Symbol, nil] :thinking or :writing
      attr_reader :label

      # The sentence as a row shows it: no TURN: prefix, markdown plain.
      def sentence = strip_markdown(@ticker.line.sub(TURN_PREFIX, ""))

      # #sentence cut to +room+ columns, with an ellipsis when cut.
      def fit(room)
        text = sentence
        room = [room, 1].max
        text.length > room ? "#{text[0, room - 1]}…" : text
      end

      private

      def add(lane, piece, raw: false)
        return false if piece.nil? || piece.empty?

        if lane != @lane
          @lane = lane
          @buffer = +""
        end
        @buffer << piece
        @buffer = @buffer[-BUFFER_LIMIT..] if @buffer.length > BUFFER_LIMIT
        @pending_label = lane
        return false unless @ticker.feed(raw ? OutputFormatter.remove_tokens(@buffer.gsub(THOUGHT_CLOSE, "\n")) : @buffer)

        @label = lane
        true
      end
    end
  end
end
