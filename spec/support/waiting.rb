# frozen_string_literal: true

require "samagotchi/testing/waiting"

# Waiting on state instead of sleeping a fixed time: a slow (parallel, CI)
# runner gets as long as it needs, a fast one doesn't wait at all. Included
# in every example group by spec_helper. The helpers are the bundle test
# kit's (Samagotchi::Testing::Waiting: wait_for, wait_until, join!, pop!,
# process_gone?), so core and bundle specs share one copy; SpecWaiting also
# extends them, so SpecWaiting.pop! (and the others) work outside an example
# group (a helper class's own wait). docs/testing.md, "Waiting and time".
module SpecWaiting
  include Samagotchi::Testing::Waiting
  extend Samagotchi::Testing::Waiting

  module_function

  # A monotonic clock, so a wait doesn't depend on Time.now.
  def mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Retries the block, every +interval+ s, until its expectations hold
  # (no RSpec::Expectations::ExpectationNotMetError), for "wait for this
  # value": eventually { expect(record.status).to eq("completed") }. After
  # +timeout+ s (× SPEC_TIME_SCALE) it raises the last failure again,
  # prefixed "still failing after 5 s:", so the message keeps the
  # matcher's own expected/got.
  # @return the block's value once it passed.
  def eventually(timeout: 5, interval: 0.01)
    waiting = Samagotchi::Testing::Waiting
    deadline = mono + waiting.scaled(timeout)
    begin
      yield
    rescue RSpec::Expectations::ExpectationNotMetError => e
      raise e.exception(still_failing(waiting.waited(timeout), e.message)) if mono > deadline

      sleep(interval)
      retry
    end
  end

  # Moves +path+'s mtime 1 s on, so it sorts after (is newer than) anything
  # written before it, whatever the file system's mtime granularity, without
  # a sleep between the writes.
  # @return [Time] the new mtime
  def distinct_mtime(path)
    (File.mtime(path) + 1).tap { |time| File.utime(time, time, path) }
  end

  # #eventually's message: a matcher's that starts on its own line
  # ("\nexpected: …") stays there.
  def still_failing(waited, message)
    prefix = "still failing after #{waited}:"
    message.start_with?("\n") ? "#{prefix}#{message}" : "#{prefix} #{message}"
  end
end
