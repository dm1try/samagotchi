# frozen_string_literal: true

require_relative "session"
require_relative "worker_presence"
require_relative "continue_intent"

module Samagotchi
  # A session's lifecycle state, derived from what is on disk now: one read of
  # the liveness facts (WorkerPresence, with the WorkerLink looked at, never
  # unlinked) and of a continue in flight (ContinueIntent.in_flight), named
  # by the first of STATES whose facts hold (Reading.derive). Nothing is
  # stored: see docs/internals/session-lifecycle.md (Derived states).
  #
  # A read only: it writes, clears and unlinks nothing (the marker writers
  # are pinned in spec/session_lifecycle_writers_spec.rb). No decider reads
  # it yet; ALLOWED is what each operation does in each state today, pinned
  # against the deciders by spec/session_lifecycle/matrix_spec.rb.
  module SessionLifecycle
    # In precedence order: the first whose facts hold names the session.
    # The compound states (stopped_starting, archived_starting) are there
    # because the deciders disagree on which of two facts wins.
    STATES = %i[absent tui_owned deleting stopping skew leaving booting_stuck booting live
                stopped_starting stopped archived_starting starting archived idle].freeze

    autoload :Reading, File.expand_path("session_lifecycle/reading", __dir__)
    autoload :CANONICAL, File.expand_path("session_lifecycle/canonical", __dir__)
    autoload :ALLOWED, File.expand_path("session_lifecycle/allowed", __dir__)

    module_function

    # Read +session_id+'s state now.
    # @param state_dir [String, nil] nil: Session.default_state_dir
    # @param owner [OwnerLock::Owner, nil, :read, #call] as WorkerPresence.read takes it
    # @return [Reading]
    def read(session_id, state_dir: nil, owner: :read)
      sd = state_dir || Session.default_state_dir
      presence = WorkerPresence.read(session_id, state_dir: sd, owner: owner, link: :look)
      Reading.derive(presence, continuing: ContinueIntent.in_flight(session_id, state_dir: sd))
    end
  end
end
