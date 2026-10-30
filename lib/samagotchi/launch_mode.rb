# frozen_string_literal: true

module Samagotchi
  # How `bin/chi` runs a session: attached to a worker (as `--attach` and
  # `--shared` do) or in the plain in-process REPL. With `session.shared` on,
  # plain `chi` runs attached unless it asks for something attached mode
  # can't do yet.
  module LaunchMode
    # Options an attached TUI can't honor: the worker prints nothing, so
    # --verbose is about this process's output. (--model and --no-interrupt
    # reach the worker: a /model command, and no_interrupt on each posted
    # turn; --memory and --mute are session fields the worker reads.)
    REPL_ONLY = { verbose: "--verbose" }.freeze
    # What an attached run can't be combined with (the worker runs its turns).
    ATTACHED_CONFLICTS = { non_interactive: "--non-interactive", verbose: "--verbose" }.freeze
    # Opening a `chi scratch` session a killed REPL left behind would turn it
    # into a kept one.
    SCRATCH_LEFTOVER = "that's a leftover scratch session; it is deleted at the next sweep (chi sessions clean)"
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
    # @param shared_config [Boolean] the session.shared config value
    # @return [Array(Symbol, String)] :attached or :repl, and a note for the
    #   user when the config asked for attached mode but didn't get it
    def resolve(options, shared_config:)
      return [:attached, nil] if options[:attach] || options[:shared]
      # --no-shared, or nobody asked for attached mode.
      return [:repl, nil] if options[:shared] == false || !shared_config
      # A one-shot with no REPL: nothing to attach.
      return [:repl, nil] if options[:non_interactive]

      flag = REPL_ONLY.find { |key, _flag| options[key] }&.last
      return [:repl, "(session.shared: #{flag} runs in a plain REPL)"] if flag

      [:attached, nil]
    end

    # Why an attached run's flags don't go together, or nil when they do.
    # @param options [Hash] bin/chi's parsed options
    # @return [String, nil]
    def attached_conflict(options)
      conflict = ATTACHED_CONFLICTS.find { |key, _flag| options[key] }
      if options[:attach] && options[:shared]
        "use either --attach ID or --shared"
      elsif options[:attach] && options[:resume]
        "--attach takes the session id; --resume goes with --shared"
      elsif conflict
        "--attach/--shared can't be combined with #{conflict.last}"
      end
    end
  end
end
