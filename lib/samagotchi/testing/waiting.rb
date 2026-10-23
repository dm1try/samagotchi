# frozen_string_literal: true

require_relative "../process_group"

module Samagotchi
  module Testing
    # Waiting with a deadline, for a test that waits on a thread or a
    # process (Helpers has them).
    module Waiting
      # The block's value once truthy, polled every +interval+ s; after
      # +timeout+ s its last (falsy) value.
      def wait_until(timeout: 5, interval: 0.01)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until (value = yield)
          return yield if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep(interval)
        end
        value
      end

      # #wait_until, raising "timed out after N s waiting for <what>" when
      # the time runs out: for a wait no check follows.
      def wait_until!(what, timeout: 5, interval: 0.01, &)
        wait_until(timeout: timeout, interval: interval, &) || raise("timed out after #{timeout} s waiting for #{what}")
      end

      # Thread#join with a deadline: a thread that never ends fails the test
      # with +what+ named, not after a suite-wide guard. Raises what the
      # thread raised, as #join does.
      # @return [Thread]
      def join!(thread, what, timeout: 5)
        thread.join(timeout) || raise("timed out after #{timeout} s waiting for #{what} to finish")
      end

      # Queue#pop with a deadline, for a queue that never carries nil: nothing
      # pushed in time fails with +what+ named. A gate a stubbed lib thread
      # waits on while the test works takes a longer +timeout+ (30): it only
      # has to end a hang, never cut a slow test short.
      # @return the value popped.
      def pop!(queue, what, timeout: 5)
        value = queue.pop(timeout: timeout)
        raise("timed out after #{timeout} s waiting for #{what}") if value.nil?

        value
      end

      # Whether no process +pid+ is left (a killed grandchild is reaped a
      # moment later: wait_until { process_gone?(pid) }). One that isn't
      # ours to signal is still there (ProcessGroup.alive?).
      def process_gone?(pid) = !ProcessGroup.alive?(pid)
    end
  end
end
