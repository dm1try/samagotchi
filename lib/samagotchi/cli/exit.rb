# frozen_string_literal: true

module Samagotchi
  module CLI
    # chi's exit statuses, one table for every subcommand (docs/cli.md,
    # docs/sub-agent.md): a script or a parent agent branches on them.
    module Exit
      OK = 0
      # Anything that went wrong at run time: a refusal, a failed turn, a
      # worker gone, a file that isn't there.
      FAILED = 1
      # The command line itself: an unknown flag, a missing argument, an
      # option the question doesn't offer.
      USAGE = 2
      # A question waits for an answer (chi send --wait, chi answer, chi -p).
      QUESTION = 3
      # Still running after --timeout.
      RUNNING = 4
      # Ctrl-C: what a shell gives a command it interrupted.
      INTERRUPTED = 130
    end
  end
end
