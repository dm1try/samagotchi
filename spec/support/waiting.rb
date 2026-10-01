# frozen_string_literal: true

# Waiting on state instead of sleeping a fixed time: a slow (parallel, CI)
# runner gets as long as it needs, a fast one doesn't wait at all. Included
# in every example group by spec_helper; SpecWaiting.mono also works outside
# one (a helper class's own wait).
module SpecWaiting
  module_function

  # A monotonic clock, so a wait doesn't depend on Time.now.
  def mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Poll the block every +interval+ seconds until it returns truthy or
  # +timeout+ seconds pass.
  # @return the block's last value: truthy once it held, falsy on a timeout.
  def wait_until(timeout: 5, interval: 0.01)
    deadline = mono + timeout
    until (value = yield)
      return yield if mono > deadline

      sleep(interval)
    end
    value
  end
end
