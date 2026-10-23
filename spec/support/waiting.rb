# frozen_string_literal: true

require "samagotchi/testing/waiting"

# Waiting on state instead of sleeping a fixed time: a slow (parallel, CI)
# runner gets as long as it needs, a fast one doesn't wait at all. Included
# in every example group by spec_helper. The helpers are the bundle test
# kit's (Samagotchi::Testing::Waiting), so core and bundle specs share one
# copy; SpecWaiting also extends them, so SpecWaiting.pop! (and the others)
# work outside an example group (a helper class's own wait).
module SpecWaiting
  include Samagotchi::Testing::Waiting
  extend Samagotchi::Testing::Waiting

  module_function

  # A monotonic clock, so a wait doesn't depend on Time.now.
  def mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
