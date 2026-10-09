# frozen_string_literal: true

require_relative "../log"

module Samagotchi
  module Hooks
    # Fires the :generation_progress hook while a turn's model response
    # streams (docs/hooks.md), batched so it can't slow the stream: when
    # EVERY_CHARS new chars (thinking + text) are pending, or EVERY_SECONDS
    # passed since the last fire with anything pending. Checked on each
    # chunk: there is no timer thread, and the hook runs on the turn's
    # thread, inside the HTTP read.
    #
    # The Engine builds one per turn, only when a hook listens, and feeds it
    # each chunk after the UIs got it. Nothing fires once the turn or the
    # generation is cancelled (lines already read still come after the
    # socket closed), and there is no end-of-generation flush:
    # :after_generation sees the whole response.
    class StreamWatch
      EVENT = :generation_progress
      EVERY_CHARS = 2000
      EVERY_SECONDS = 1.0
      # A hook slower than this is logged (stream_hook_slow), once per turn.
      SLOW_SECONDS = 0.1

      # @param hooks [Registry]
      # @param cancel_controller [CancellationController] the turn's
      # @param clock [#call] monotonic seconds
      def initialize(hooks:, cancel_controller:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @hooks = hooks
        @cancel_controller = cancel_controller
        @clock = clock
        @slow_logged = false
        @iteration = nil
        @restarted = false
      end

      # A new generation (:generation_started), or a dropped stream's step
      # asked again (restarted: true: the first fire after it carries
      # restarted: true — what came before is void).
      def started(iteration, restarted: false)
        @iteration = iteration
        @started_at = @last_fire_at = @clock.call
        @thinking = +""
        @text = +""
        @thinking_chars = 0
        @text_chars = 0
        @restarted = restarted
      end

      # One chunk's new thinking and visible text.
      def feed(thinking:, text:)
        return unless @iteration
        return if @cancel_controller.cancelled? || @cancel_controller.generation_cancelled?

        thinking = thinking.to_s
        text = text.to_s
        @thinking << thinking
        @text << text
        @thinking_chars += thinking.length
        @text_chars += text.length
        pending = @thinking.length + @text.length
        return if pending.zero?

        now = @clock.call
        fire(now) if pending >= EVERY_CHARS || now - @last_fire_at >= EVERY_SECONDS
      end

      private

      def fire(now)
        event = { type: EVENT, iteration: @iteration, thinking: @thinking.freeze, text: @text.freeze,
                  thinking_chars: @thinking_chars, text_chars: @text_chars,
                  elapsed_ms: ((now - @started_at) * 1000).round,
                  # A question would hold the HTTP read for minutes.
                  ask_user: ->(**) {} }
        # The first fire after a restarted retry says so, once.
        event[:restarted] = true if @restarted
        @restarted = false
        @thinking = +""
        @text = +""
        @last_fire_at = now
        hook_started = @clock.call
        @hooks.fire_each(EVENT, event) do |fired|
          done = @clock.call
          slow(fired[:hook], done - hook_started)
          hook_started = done
        end
        @last_fire_at = @clock.call
      end

      def slow(hook, seconds)
        return if @slow_logged || seconds <= SLOW_SECONDS

        @slow_logged = true
        Log.warn(:turn, "stream_hook_slow", hook: hook.to_s, iteration: @iteration, ms: (seconds * 1000).round)
      end
    end
  end
end
