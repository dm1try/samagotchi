# frozen_string_literal: true

require_relative "../owner_lock"
require_relative "../worker_link"
require_relative "../worker_presence"
require_relative "../worker_sidecar"
require_relative "../session_lifecycle"

module Samagotchi
  module SessionLifecycle
    # The fewest facts that make each state (STATES order), as a
    # WorkerPresence with its link: what ALLOWED's delivery columns are
    # decided on. Each derives back to its own state (Reading.derive). A
    # compound state takes the decided facts: stopping is a worker whose
    # Bridge answers, with a stop; stopped_starting a start marked before
    # the stop (one marked after it holds a resume off: a row fact the
    # characterization matrix keeps).
    CANONICAL = lambda do
      worker = OwnerLock::Owner.new(pid: 1, kind: "worker")
      sidecar = WorkerSidecar.new(port: 1, pid: 1)
      live = WorkerLink::Live.new(sidecar: sidecar, owner: worker)
      at = lambda do |owner: nil, link: WorkerLink::None.new(owner: owner), exists: true, stop: false, start: false, archived: false|
        WorkerPresence.new(session_id: "canonical", exists: exists, owner: owner, stop_marked: stop,
                           starting_marked: start, archived: archived, link: link)
      end
      tui = OwnerLock::Owner.new(pid: 1, kind: "tui")
      deleting = OwnerLock::Owner.new(pid: 1, kind: OwnerLock::DELETING)
      leaving = worker.with(leaving_at: "2020-01-01T00:00:00Z", leave_wait: 1.0)
      {
        absent: at.call(exists: false),
        tui_owned: at.call(owner: tui),
        deleting: at.call(owner: deleting, link: WorkerLink::Starting.new(owner: deleting)),
        stopping: at.call(owner: worker, link: live, stop: true),
        skew: at.call(owner: worker, link: WorkerLink::Skew.new(sidecar: sidecar.with(protocol: WorkerLink::PROTOCOL + 1),
                                                                owner: worker, reason: :protocol)),
        leaving: at.call(owner: leaving, link: WorkerLink::Leaving.new(owner: leaving)),
        booting_stuck: at.call(owner: worker, link: WorkerLink::Starting.new(owner: worker, stuck: true)),
        booting: at.call(owner: worker, link: WorkerLink::Starting.new(owner: worker)),
        live: at.call(owner: worker, link: live),
        stopped_starting: at.call(stop: true, start: true),
        stopped: at.call(stop: true),
        archived_starting: at.call(archived: true, start: true),
        starting: at.call(start: true),
        archived: at.call(archived: true),
        idle: at.call
      }.freeze
    end.call
  end
end
