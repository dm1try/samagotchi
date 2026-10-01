# frozen_string_literal: true

require_relative "model_profile"

module Samagotchi
  # Incremental, profile-aware splitter for a raw model stream.
  #
  # It feeds raw streamed chunks (the `:generation_chunk` `content`, which is
  # never mutated) and routes each byte into one of two additive lanes:
  #   * :thinking — content inside a thinking block
  #   * :text     — visible prose (everything outside thinking/tool_call blocks)
  #
  # tool_call block bodies are dropped: the web activity panel renders those from
  # the `:tool_call_started` / `:tool_call_completed` events, so duplicating them
  # in the text bubble would be noise.
  #
  # The splitter is stateful across chunks: it carries partial open/close marker
  # fragments at the end of each chunk so a marker split across a stream boundary
  # is still recognized. `ThoughtStreamSplitter.for_profile` derives the block
  # markers from the active ModelProfile, so the same splitter works for the
  # Qwen literal-marker family and the Gemma control-token family.
  #
  # Gemma 4 thinks in a channel, `<|channel>thought` … `<channel|>`: that is
  # its thinking block. Its bare `<|think|>` cue has no close marker, so it is
  # not a block and stays in `:text` (the model doesn't emit it; the system
  # prompt carries it).
  class ThoughtStreamSplitter
    # Gemma 4's thought channel (ToolCallParser::Gemma strips the same pair).
    GEMMA_THOUGHT_CHANNEL = { open: "<|channel>thought", close: "<channel|>" }.freeze

    # @return [Array<Hash>] each entry { open: String, close: String, lane: :thinking|:drop }
    def self.for_profile(profile)
      blocks = []
      # A thinking block needs a close marker to be bounded.
      blocks << { open: profile.thought_open, close: profile.thought_close, lane: :thinking } if profile.thought_close
      blocks << GEMMA_THOUGHT_CHANNEL.merge(lane: :thinking) if profile.name == "gemma4"
      blocks << { open: profile.tool_call_open, close: profile.tool_call_close, lane: :drop }
      new(blocks)
    end

    # @param blocks [Array<Hash>] as produced by #for_profile
    def initialize(blocks)
      @blocks = blocks
      @carry = +""
      @state = :normal
      @active = nil
    end

    # Feed one raw chunk. Returns the newly-routed deltas for this chunk only.
    # @return [Hash{ text: String, thinking: String }]
    def feed(chunk)
      @carry << chunk.to_s
      text = +""
      thinking = +""
      loop do
        if @state == :normal
          hit = earliest_open
          if hit.nil?
            flush_normal(text)
            break
          end
          # Everything before the open marker is visible prose.
          text << @carry[0...hit[:pos]]
          @carry = @carry[hit[:pos]..]
          @active = hit[:block]
          @state = :in_block
          # Drop the open marker itself; its body follows.
          @carry = @carry[@active[:open].length..].to_s
        else
          close_pos = @carry.index(@active[:close])
          if close_pos.nil?
            flush_in_block(thinking)
            break
          end
          body = @carry[0...close_pos]
          route_body(body, thinking)
          @carry = @carry[close_pos + @active[:close].length..].to_s
          @active = nil
          @state = :normal
        end
      end
      { text: text, thinking: thinking }
    end

    # Flush any residual state at end of stream (e.g. an unterminated thinking
    # block: its content is still thinking; a partial trailing marker is
    # discarded since it can no longer complete).
    # @return [Hash{ text: String, thinking: String }]
    def finalize
      text = +""
      thinking = +""
      if @state == :in_block
        route_body(@carry, thinking)
      else
        text << @carry
      end
      @carry = +""
      @active = nil
      @state = :normal
      { text: text, thinking: thinking }
    end

    private

    # Normal state: the earliest complete open marker among @blocks, or nil.
    def earliest_open
      best = nil
      @blocks.each do |block|
        pos = @carry.index(block[:open])
        next if pos.nil?
        best = { pos: pos, block: block } if best.nil? || pos < best[:pos]
      end
      best
    end

    # Normal state: emit everything except a trailing fragment that could be the
    # start of an open marker (retained for the next chunk to complete it).
    def flush_normal(text)
      partial = @blocks.map { |block| longest_suffix_prefix_of(@carry, block[:open]) }.max.to_i
      text << @carry[0...(@carry.length - partial)]
      @carry = @carry[@carry.length - partial..].to_s
    end

    # In-block state: emit the body seen so far to the active lane, retaining a
    # trailing fragment that could be the start of the close marker.
    def flush_in_block(thinking)
      close = @active[:close]
      partial = longest_suffix_prefix_of(@carry, close)
      route_body(@carry[0...(@carry.length - partial)], thinking)
      @carry = @carry[@carry.length - partial..].to_s
    end

    # Route a body fragment to the active block's lane (:thinking or :drop).
    def route_body(body, thinking)
      return if body.nil? || body.empty?
      thinking << body if @active && @active[:lane] == :thinking
    end

    # Length of the longest suffix of +str+ that is a prefix of +marker+.
    # Used to hold back a fragment that may complete into a marker next chunk.
    def longest_suffix_prefix_of(str, marker)
      mlen = marker.length
      return 0 if mlen.zero? || str.empty?
      [str.length, mlen].min.downto(1) do |n|
        return n if str[-n..] == marker[0, n]
      end
      0
    end
  end
end
