# frozen_string_literal: true

require_relative "../process_group"

module Samagotchi
  module Testing
    # Waiting with a deadline, for a test that waits on a thread or a
    # process (Helpers has them). Every deadline is the given +timeout+ ×
    # Waiting.time_scale (SPEC_TIME_SCALE, CI sets 2): a slow runner gets
    # more headroom, a fast one never waits longer than its condition takes.
    module Waiting
      # A wait whose deadline passed: its message names what it waited for
      # (Waiting.timed_out_message).
      class TimedOut < StandardError; end

      # The most of a +seen:+ value's inspect a message shows.
      SEEN_LIMIT = 300

      class << self
        # SPEC_TIME_SCALE as a Float, at least 1 (unset or empty: 1). A value
        # that isn't a number gives 1 and one warning. Read per call.
        def time_scale
          raw = ENV.fetch("SPEC_TIME_SCALE", "").strip
          return 1.0 if raw.empty?

          [Float(raw), 1.0].max
        rescue ArgumentError
          unless @warned_scale
            @warned_scale = true
            warn("SPEC_TIME_SCALE=#{raw.inspect} is not a number: waiting with scale 1")
          end
          1.0
        end

        # +timeout+ s scaled: the deadline a helper waits for.
        def scaled(timeout, scale = time_scale) = timeout * scale

        # How long a wait took to give up: "5 s", or with a scale
        # "10.0 s (5 s × SPEC_TIME_SCALE 2)".
        def waited(timeout, scale = time_scale)
          return "#{timeout} s" if scale == 1

          "#{scaled(timeout, scale).round(3).to_f} s (#{timeout} s × SPEC_TIME_SCALE #{number(scale)})"
        end

        # The one failure text of wait_for, join! and pop!:
        # "timed out after 5 s waiting for <what>", then "; last saw: <value>"
        # when +seen+ (a callable) is given, its value's inspect cut to
        # SEEN_LIMIT chars.
        def timed_out_message(what, timeout, scale: time_scale, seen: nil)
          message = "timed out after #{waited(timeout, scale)} waiting for #{what}"
          seen ? "#{message}; last saw: #{seen_text(seen)}" : message
        end

        private

        def number(value) = value == value.to_i ? value.to_i.to_s : value.to_s

        def seen_text(seen)
          text = seen.call.inspect
          text.length > SEEN_LIMIT ? "#{text[0, SEEN_LIMIT]}…" : text
        rescue StandardError => e
          "(raised #{e.class}: #{e.message})"
        end
      end

      # The block's value once truthy, polled every +interval+ s; after
      # +timeout+ s (scaled) its last (falsy) value. For a wait whose
      # timeout is fine (a bounded best-effort wait); a wait that must hold
      # is #wait_for.
      def wait_until(timeout: 5, interval: 0.01)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Waiting.scaled(timeout)
        until (value = yield)
          return yield if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep(interval)
        end
        value
      end

      # Polls the block every +interval+ s until it returns truthy and
      # returns that value. After +timeout+ s (scaled) it raises
      # Waiting::TimedOut naming +what+ ("timed out after 5 s waiting for
      # <what>"); +seen+ (a callable) adds what it last saw, since a falsy
      # block value tells nothing.
      def wait_for(what, timeout: 5, interval: 0.01, seen: nil, &)
        wait_until(timeout: timeout, interval: interval, &) ||
          raise(TimedOut, Waiting.timed_out_message(what, timeout, seen: seen))
      end

      # Thread#join with a deadline (scaled): a thread that never ends fails
      # the test with "<what> to finish" named, not after a suite-wide guard.
      # Raises what the thread raised, as #join does.
      # @return [Thread]
      def join!(thread, what, timeout: 5)
        thread.join(Waiting.scaled(timeout)) || raise(TimedOut, Waiting.timed_out_message("#{what} to finish", timeout))
      end

      # Queue#pop with a deadline (scaled), for a queue that never carries
      # nil: nothing pushed in time fails with +what+ named. A gate a stubbed
      # lib thread waits on while the test works takes a longer +timeout+
      # (30): it only has to end a hang, never cut a slow test short.
      # @return the value popped.
      def pop!(queue, what, timeout: 5)
        value = queue.pop(timeout: Waiting.scaled(timeout))
        raise(TimedOut, Waiting.timed_out_message(what, timeout)) if value.nil?

        value
      end

      # Whether no process +pid+ is left (a killed grandchild is reaped a
      # moment later: wait_for("pid gone") { process_gone?(pid) }). One that
      # isn't ours to signal is still there (ProcessGroup.alive?).
      def process_gone?(pid) = !ProcessGroup.alive?(pid)
    end
  end
end
