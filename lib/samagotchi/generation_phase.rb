# frozen_string_literal: true

module Samagotchi
  # What the running generation is doing, as the Engine's stream handler
  # sees it: whether a steer may cut it (Engine#cut_for_steer). A
  # generation is cuttable while it has only been thinking: it streamed
  # thinking, still streams it (a thinking delta in the last FRESH_SECONDS),
  # and has streamed no visible text and no tool call. Fed from the stream
  # thread, read from a steer's thread: its own Mutex, never held while
  # calling out.
  class GenerationPhase
    # A thinking delta this recent means the model is still thinking.
    FRESH_SECONDS = 2.0

    # @param clock [#call] monotonic seconds
    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock = clock
      @mutex = Mutex.new
      @running = false
      @started_at = nil
      clear_seen
    end

    # A generation began.
    def started!
      @mutex.synchronize do
        @running = true
        @started_at = @clock.call
        clear_seen
      end
    end

    # One streamed chunk's lanes. Blank text (a stray newline before Gemma's
    # thought channel) is no text.
    def chunk!(thinking:, text:, tool_call: false)
      @mutex.synchronize do
        unless thinking.to_s.empty?
          @thinking = true
          @thinking_at = @clock.call
        end
        @text = true unless text.to_s.strip.empty?
        @tool_call = true if tool_call
      end
    end

    # The request is sent again (a network retry): it streams from the
    # start, so what it had seen is forgotten; its age is kept.
    def retrying!
      @mutex.synchronize { clear_seen }
    end

    # The generation ended (completed, cut, cancelled, or the turn ended).
    def finished!
      @mutex.synchronize { @running = false }
    end

    # Whether a steer may cut the running generation: thinking only, still
    # thinking, and at least +min_age+ seconds old.
    def cuttable?(min_age)
      @mutex.synchronize do
        next false unless @running && @thinking && !@text && !@tool_call

        now = @clock.call
        now - @thinking_at <= FRESH_SECONDS && now - @started_at >= min_age
      end
    end

    # Seconds since the running generation began; nil with none.
    def age
      @mutex.synchronize { @running ? @clock.call - @started_at : nil }
    end

    private

    def clear_seen
      @thinking = false
      @thinking_at = nil
      @text = false
      @tool_call = false
    end
  end
end
