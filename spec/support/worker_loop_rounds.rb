# frozen_string_literal: true

# A worker's loop passes, for a check that nothing happens (no turn, no
# ring, still up): each pass with nothing to do ends in its Waker's wait,
# counted, so the check waits for passes instead of a fixed time. Include
# it in an example group and call count_loop_rounds before the worker runs.
module WorkerLoopRounds
  def count_loop_rounds(worker)
    @loop_worker = worker
    @rounds = [0]
    waker = worker.instance_variable_get(:@waker)
    allow(waker).to receive(:wait).and_wrap_original do |original, *args|
      @rounds[0] += 1
      original.call(*args)
    end
  end

  # Wakes the loop until it came round to its wait +count+ more times: two
  # make one whole pass that began after the call.
  def loop_rounds(count = 2)
    waker = @loop_worker.instance_variable_get(:@waker)
    count.times do
      start = @rounds[0]
      waker.wake
      expect(wait_until { @rounds[0] > start }).to be(true)
    end
  end
end
