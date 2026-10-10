# frozen_string_literal: true

require_relative "errors"
require_relative "http"

module Samagotchi
  module LLM
    # A stream that dropped mid-answer is asked again from the same
    # conversation: the same limit, backoff and cancel behaviour for both
    # the chat loop and the native loop, so a native /completion and a chat
    # request react identically to a dropped stream.
    #
    # The helpers the ask-again loop needs: how many times a dropped
    # stream's step may be asked (stream_drop_limit), the transport's own
    # backoff before the ask-again (generation_retry_delay), and the
    # cancel-checking wait between the asks (wait_retry).
    module StreamDrops
      # The most times one step's dropped stream is asked again (both loops;
      # stream_drop_limit lowers it under a smaller retry.max).
      MAX_STREAM_DROPS = 2

      # A step's drops asked again (+drops+) and the HTTP requests made so
      # far (+requests+: each failed request's transport attempts), so the
      # error that ends the step counts every request, not the last one's.
      DropCount = Struct.new(:drops, :requests)

      # How many times a dropped stream's step may be asked again: +cap+,
      # or retry.max when that is smaller (retry.max: 0 turns it off, as it
      # does the transport's retries).
      def stream_drop_limit(cap)
        [cap, HTTP::RetryPolicy.from_config.max].min
      rescue StandardError
        cap
      end

      # The seconds before the +attempt+-th ask-again of a dropped stream's
      # step: the transport's own backoff (LLM::HTTP::RetryPolicy), 0 when
      # retry.max is spent.
      def generation_retry_delay(attempt)
        HTTP::RetryPolicy.from_config.delay_for(attempt) || 0.0
      rescue StandardError
        0.0
      end

      # Waits +seconds+ in short slices, raising RequestCancelled as soon as
      # one of +controllers+ (the turn's, the generation's) is cancelled,
      # as LLM::HTTP's own wait between retries does.
      def wait_retry(seconds, *controllers)
        remaining = seconds.to_f
        while remaining.positive?
          cancelled = controllers.compact.find(&:cancelled?)
          raise RequestCancelled, cancelled.reason if cancelled

          slice = [remaining, 0.05].min
          @sleeper.call(slice)
          remaining -= slice
        end
        cancelled = controllers.compact.find(&:cancelled?)
        raise RequestCancelled, cancelled.reason if cancelled
      end
    end
  end
end
