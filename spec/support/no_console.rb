# frozen_string_literal: true

# Loaded first (ruby -r) by the bin/chi children the suite spawns: their
# stdin, stdout and stderr are pipes already, but IO.console opens the
# controlling terminal itself, so a run from a terminal would wrap at its
# width. No console, as in CI. (The suite's own process stubs it, spec_helper.)
require "io/console" # first, or its later require puts the real one back

def IO.console(*) = nil
