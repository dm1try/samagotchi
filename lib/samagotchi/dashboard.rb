# frozen_string_literal: true

require "samagotchi/session_manager"

module Samagotchi
  # Dashboard — CLI menu for managing background sessions.
  #
  # NOTE: The interactive Dashboard is currently a minimal no-crash shim while
  # the multi-agent / engines UI is being reworked (see tmp/plans/). The full
  # re-implementation is a future deliverable; this shim loads and exits cleanly.
  class Dashboard
    def initialize
      # no interactive state — see note above
    end

    # Print a short notice and return cleanly.
    #
    # The shim prints to `$stdout` (so specs can assert with `.to_stdout`) and
    # returns rather than exiting — bin/chi handles the process exit.
    def run
      $stdout.puts <<~NOTICE
        Chi Dashboard is being reworked.

        The full multi-agent / engines Dashboard is out of scope for the current
        core/terminal-UI split. The background-session engine (Engine) works; the
        interactive dashboard menu is temporarily unavailable.

        See tmp/plans/20260818-000000-core-ui-separation.md for the plan.
      NOTICE
    end
  end
end
