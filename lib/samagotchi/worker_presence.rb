# frozen_string_literal: true

require_relative "session"
require_relative "owner_lock"
require_relative "worker_link"
require_relative "starting_marker"
require_relative "archive_store"

module Samagotchi
  # Whether a session's worker is there, coming or held off, read once for
  # one decision: the one reader of the liveness facts that the deciders
  # ("start a worker for this session?", "is one up?") combine. Each fact is
  # read from disk by WorkerPresence.read; the predicates are named after what
  # the deciders ask, and each decider keeps its own subset and order.
  #
  # Two "stopped"s stay apart: #stop_marked? is the `<id>/stopped` marker (a
  # `chi sessions stop`; a resume removes it), #turn_stopped? the loaded
  # session's status field (turn state, which Session.load also reads as
  # stopped while the marker is there). The second needs a Session (#with_session).
  #
  # @!attribute session_id [String]
  # @!attribute exists [Boolean] its session file is there (Session.exist?)
  # @!attribute owner [OwnerLock::Owner, nil] the owner lock's holder: a
  #   worker, a one-turn chi run (kind tui) or nil when free
  # @!attribute stop_marked [Boolean] the `stopped` marker (Session.stopped_marker?)
  # @!attribute starting_marked [Boolean] the `starting` marker, fresh
  #   (StartingMarker.fresh?): a worker is being started for it (every spawn
  #   writes it, until the worker holds the lock)
  # @!attribute archived [Boolean] ArchiveStore.archived?
  # @!attribute link [WorkerLink::Live, WorkerLink::Starting, WorkerLink::Leaving,
  #   WorkerLink::None, WorkerLink::Stale, WorkerLink::Skew, nil] the Bridge
  #   outcome, when read (+link:+), else nil
  # @!attribute turn_status [String, nil] the loaded session's status, nil
  #   until #with_session
  # @!attribute scratch [Boolean, nil] the loaded session's scratch flag, nil
  #   until #with_session
  WorkerPresence = Data.define(:session_id, :exists, :owner, :stop_marked, :starting_marked, :archived, :link,
                               :turn_status, :scratch) do
    # Read the facts for +session_id+ now.
    # @param state_dir [String, nil] nil: Session.default_state_dir
    # @param owner [OwnerLock::Owner, nil, :read, #call] the lock's holder as
    #   the caller already read it (SessionManager.session_owner, a stand-in
    #   manager's), or a reader of it called only for a valid id; :read reads
    #   it here (OwnerLock.owner)
    # @param link [nil, :look, :unlink] also resolve the WorkerLink:
    #   :look leaves a stale sidecar, :unlink removes it (WorkerLink.resolve,
    #   given the owner read here or by the caller: one moment's snapshot)
    # @return [WorkerPresence]
    def self.read(session_id, state_dir: nil, owner: :read, link: nil)
      return absent(session_id, link: link) unless Session.valid_id?(session_id)

      owner = owner.call if owner.respond_to?(:call)
      sd = state_dir || Session.default_state_dir
      dir = Session.session_dir(session_id, state_dir: sd)
      owner = OwnerLock.owner(dir) if owner == :read
      new(session_id: session_id,
          exists: Session.exist?(session_id, state_dir: sd),
          owner: owner,
          stop_marked: Session.stopped_marker?(session_id, state_dir: sd),
          starting_marked: StartingMarker.fresh?(session_id, state_dir: sd),
          archived: ArchiveStore.archived?(dir),
          link: link && WorkerLink.resolve(dir, unlink: link == :unlink, owner: owner))
    end

    # The stop marker alone, for a decider that asks nothing else (WorkerBoot's
    # restart leave, after the lock's release): no lock probe, no other file.
    # Same reader as #stop_marked?.
    def self.stop_marked?(session_id, state_dir: nil)
      Session.valid_id?(session_id) &&
        Session.stopped_marker?(session_id, state_dir: state_dir || Session.default_state_dir)
    end

    # An id that isn't one names no session: nothing on disk is read
    # (Session.session_dir would raise), and a link asked for is None.
    # @return [WorkerPresence]
    def self.absent(session_id, link: nil)
      new(session_id: session_id, exists: false, owner: nil, stop_marked: false, starting_marked: false,
          archived: false, link: link && WorkerLink::None.new)
    end

    def initialize(session_id:, exists:, owner:, stop_marked:, starting_marked:, archived:, link: nil,
                   turn_status: nil, scratch: nil)
      super
    end

    # The same facts with the loaded session's (#turn_stopped?, #scratch?).
    # @param session [Session]
    def with_session(session) = with(turn_status: session.status, scratch: session.scratch)

    def exists? = exists
    def archived? = archived

    # Someone holds the owner lock: a worker or a one-turn chi run.
    def owned? = !owner.nil?

    # A one-turn chi run (`chi -p X --non-interactive`, kind tui) holds it:
    # nothing else may resume, stop or delete it.
    def tui_owned? = owner&.tui? == true

    # The `<id>/stopped` marker: a user's stop, not the turn's status.
    def stop_marked? = stop_marked

    # The loaded session's status is stopped (turn state; Session.load reads
    # it so while #stop_marked?). False before #with_session.
    def turn_stopped? = turn_status == Session::STATUS_STOPPED

    # The loaded session is a `chi scratch` one. False before #with_session.
    def scratch? = scratch == true

    # A worker is being started for it: the fresh `starting` marker
    # (StartingMarker) a spawn writes until its worker holds the lock.
    def starting? = starting_marked

    # A worker being started (#starting?, from any process) may not hold the
    # lock yet, and no stop came since: a stop cancels the hold-off (a
    # resume after it clears the stop and spawns; the starting worker and
    # the new one race the lock, one wins). Of resumes after one stop, one
    # spawns: resume_session's claim takes over only a start marked before
    # the stop.
    def start_pending? = starting? && !stop_marked?

    # resume_session's hold-off, after the owner: a start pending.
    def resume_held_off? = start_pending?

    # The Bridge answers (WorkerLink::Live). False when the link wasn't read.
    def live? = link&.live? == true

    # A worker holds the lock, Bridge or not (Live, Starting, Leaving, Skew).
    # False when the link wasn't read.
    def worker_owned? = link&.worker_owned? == true
  end
end
