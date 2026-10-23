# frozen_string_literal: true

require "samagotchi/reply_wait"

# A ReplyWait's looks, for a "the worker answers once the wait looked"
# step: each poll calls the wait's interject, counted here (around the
# caller's own interject, if any), so a step on another thread waits for
# the looks instead of a fixed delay. Include it in an example group and
# call count_reply_wait_looks before the wait runs.
module ReplyWaitLooks
  def count_reply_wait_looks
    @reply_wait_looks = [0]
    looks = @reply_wait_looks
    allow(Samagotchi::ReplyWait).to receive(:call).and_wrap_original do |original, *args, interject: nil, **opts|
      counting = lambda do
        interject&.call
        looks[0] += 1
      end
      original.call(*args, interject: counting, **opts)
    end
  end

  # Blocks until the waits made +count+ more looks: 2 is a whole look at
  # what the caller set just before.
  def looked(count = 1)
    start = @reply_wait_looks[0]
    wait_for("the reply wait to look #{count} more time(s)", seen: -> { @reply_wait_looks[0] - start }) do
      @reply_wait_looks[0] >= start + count
    end
  end
end
