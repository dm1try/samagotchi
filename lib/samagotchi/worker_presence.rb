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
  # the deciders ask, and each decider keeps its own subset and order (the
  # session inbox's WakePolicy is the table of most of them).
  #
  # "Stopped" is #stop_marked?, the `<id>/stopped` marker (a `chi sessions
  # stop`; a resume removes it): no decider reads the session file's status
  # (turn state). Nor is the file read here: the one decider that needs it
  # (a scratch session, WakePolicy#decide) reads it last, itself.
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
  WorkerPresence = Data.define(:session_id, :exists, :owner, :stop_marked, :starting_marked, :archived, :link) do
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

    # An id that isn't one names no session: nothing on disk is read
    # (Session.session_dir would raise), and a link asked for is None.
    # @return [WorkerPresence]
    def self.absent(session_id, link: nil)
      new(session_id: session_id, exists: false, owner: nil, stop_marked: false, starting_marked: false,
          archived: false, link: link && WorkerLink::None.new)
    end

    def initialize(session_id:, exists:, owner:, stop_marked:, starting_marked:, archived:, link: nil) = super

    def exists? = exists
    def archived? = archived

    # Someone holds the owner lock: a worker or a one-turn chi run.
    def owned? = !owner.nil?

    # A one-turn chi run (`chi -p X --non-interactive`, kind tui) holds it:
    # nothing else may resume, stop or delete it.
    def tui_owned? = owner&.tui? == true

    # The `<id>/stopped` marker: a user's stop, not the turn's status.
    def stop_marked? = stop_marked

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
