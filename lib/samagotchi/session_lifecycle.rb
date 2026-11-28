# frozen_string_literal: true

require_relative "session"
require_relative "worker_presence"
require_relative "continue_intent"
require_relative "session_transition"

module Samagotchi
  # A session's lifecycle state, derived from what is on disk now: one read of
  # the liveness facts (WorkerPresence, with the WorkerLink looked at, never
  # unlinked) and of a continue in flight (ContinueIntent.in_flight), named
  # by the first of STATES whose facts hold (Reading.derive). Nothing is
  # stored: see docs/internals/session-lifecycle.md (Derived states).
  #
  # A read only: it writes, clears and unlinks nothing (the marker writers
  # are pinned in spec/session_lifecycle_writers_spec.rb). Two deciders
  # read it (restart_session's precheck, ALLOWED[:restart]; a schedule's busy
  # check, Schedules#busy_cell, ALLOWED[:sched_chain] / [:sched_same]); ALLOWED is what
  # each operation does in each state, pinned against the deciders by
  # spec/session_lifecycle/matrix_spec.rb.
  module SessionLifecycle
    # In precedence order: the first whose facts hold names the session.
    # The compound states (stopped_starting, archived_starting) are there
    # because the deciders disagree on which of two facts wins.
    STATES = %i[absent tui_owned deleting stopping skew leaving booting_stuck booting live
                stopped_starting stopped archived_starting starting archived idle].freeze

    # The states whose session is shown "stopped" (the hub shows the stopped
    # status only there; the file's own status is shown everywhere else).
    STOPPED_STATES = %i[stopping stopped_starting stopped].freeze

    autoload :Reading, File.expand_path("session_lifecycle/reading", __dir__)
    autoload :CANONICAL, File.expand_path("session_lifecycle/canonical", __dir__)
    autoload :ALLOWED, File.expand_path("session_lifecycle/allowed", __dir__)
    autoload :TRANSITIONING, File.expand_path("session_lifecycle/allowed", __dir__)
    autoload :TAKES_LOCK, File.expand_path("session_lifecycle/allowed", __dir__)

    # The cell words that are no refusal, per operation: a resume that finds
    # a worker there or one being started waits for it; a restart's
    # fallback (an unresponsive worker's path) goes.
    VERDICT_WORDS = { resume: { live: :wait, starting: :wait }, restart: { fallback: :go } }.freeze

    module_function

    # @param transitioning [Boolean] a transition holds the session's lock
    #   (Reading#transitioning): an op TRANSITIONING names answers its cell
    #   there, whatever the state
    # @return [Symbol] the cell of +op+ in +state+ (ALLOWED)
    def allowed(op, state, transitioning: false)
      return TRANSITIONING.fetch(op) if transitioning && TRANSITIONING.key?(op)

      ALLOWED.fetch(op).fetch(state)
    end

    # A cell as :go, :wait or :refused: :go and :wait are themselves, an
    # operation's own words (VERDICT_WORDS) theirs, every other a refusal.
    # @return [Symbol]
    def verdict(op, cell)
      return cell if %i[go wait].include?(cell)

      VERDICT_WORDS.fetch(op, {}).fetch(cell, :refused)
    end

    # Read +session_id+'s state now.
    # @param state_dir [String, nil] nil: Session.default_state_dir
    # @param owner [OwnerLock::Owner, nil, :read, #call] as WorkerPresence.read takes it
    # @return [Reading]
    def read(session_id, state_dir: nil, owner: :read)
      sd = state_dir || Session.default_state_dir
      presence = WorkerPresence.read(session_id, state_dir: sd, owner: owner, link: :look)
      Reading.derive(presence, continuing: ContinueIntent.in_flight(session_id, state_dir: sd),
                               transitioning: SessionTransition.held?(session_id, state_dir: sd))
    end
  end
end
