# frozen_string_literal: true

module Samagotchi
  # How `bin/chi` runs a session: attached to a worker (the attached TUI,
  # AttachLauncher), or --non-interactive's one turn in this process
  # (TerminalUI, the one-shot host).
  module LaunchMode
    # What an attached run can't be combined with.
    ATTACHED_CONFLICTS = { non_interactive: "--non-interactive", verbose: "--verbose" }.freeze
    # A worker spawned or resumed for an attach whose Bridge never came (%s:
    # the session id). A worker whose chi home couldn't load chi logs
    # SessionManager::HOME_BOOT_FAILED and exits: HomeDoctor's boot row says
    # what and what to run, so the text names chi home doctor.
    BRIDGE_LATE = "the worker for session %s did not start its Bridge in time " \
                  "(chi home doctor shows a worker that failed to boot)"
    # An attach (or a resume) that found the session's worker leaving, its
    # Bridge closed and its recap on leave still being written: it waits for
    # the worker to let go (OwnerLock.await_release), then starts a new one.
    RECAP_WAIT = "(waiting for the session to finish its recap…)"

    module_function

    # @param options [Hash] bin/chi's parsed options
    # @return [Symbol] :attached, :one_shot (--non-interactive: one turn in
    #   this process), or :repl (--verbose, until it runs attached)
    def resolve(options)
      return :attached if options[:attach]
      return :one_shot if options[:non_interactive]
      return :repl if options[:verbose]

      :attached
    end

    # Why an attached run's flags don't go together, or nil when they do.
    # @param options [Hash] bin/chi's parsed options
    # @return [String, nil]
    def attached_conflict(options)
      conflict = ATTACHED_CONFLICTS.find { |key, _flag| options[key] }
      if options[:attach] && options[:resume]
        "use either --attach ID or --resume ID"
      elsif conflict
        "--attach can't be combined with #{conflict.last}"
      end
    end
  end
end
