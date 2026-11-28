# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"
require "samagotchi/session_lifecycle"
require "samagotchi/client_id"
require "samagotchi/session_transition"
require "samagotchi/session_manager"
require "samagotchi/schedules"
require "samagotchi/worker_boot"
require "samagotchi/terminal_ui/local_link"
require "samagotchi/web/session_summary"

# The rows, files and drivers of the session lifecycle characterization
# matrix (spec/session_lifecycle/matrix_spec.rb): every combination of the
# liveness facts written as real files, and every decider driven over them,
# its answer projected into ALLOWED's cell words. Every reach into a private
# method (WorkerBoot.respawn, Schedules#busy_reason, the restart fallback,
# Process.spawn) is in one driver here, so a decider migrated to
# SessionLifecycle edits this file only. No real process is started or
# signalled: the owner lock's holder is stubbed (OwnerLock.owner), and so
# are Process.spawn, TERM/CONT and the worker's Bridge.
module LifecycleMatrix
  # The pid the stubbed owner and its sidecar name (never signalled: TERM
  # and CONT are stubbed).
  OWNER_PID = 999_991
  SUCCESSOR = "11111111-2222-4333-8444-555555555555"

  # Owner kind × link outcome, as the matrix combines them.
  PAIRS = [%i[none none], %i[none stale], %i[tui none], %i[tui stale], %i[deleting none], %i[worker live],
           %i[worker starting], %i[worker stuck], %i[worker leaving], %i[worker skew], %i[unknown none]].freeze

  # A schedule's busy_reason texts and the cell word each is; an unknown
  # text fails (a copy edit shows up here, on purpose).
  REASONS = {
    Samagotchi::SessionManager::DeliverResult::STOPPED["detail"] => :stopped,
    Samagotchi::SessionManager::DeliverResult::DELETING["detail"] => :deleting,
    Samagotchi::WorkerLink::Skew.new(sidecar: nil, owner: nil, reason: :protocol).short_message => :worker_newer,
    "its worker is starting or leaving" => :worker_busy
  }.freeze

  # The operations whose expectation is SHOWN (the session hub's summary),
  # not ALLOWED.
  HUB_OPS = %i[hub_status hub_bridge_up hub_live].freeze

  # A deliberate stop of the matrix's restart ask (the Bridge's POST /exit
  # reached: the restart goes).
  class RestartAsked < StandardError; end

  # One combination of facts. owner: :none, :tui, :deleting, :worker or
  # :unknown (a lock record still blank); link: :none, :stale, :live,
  # :starting, :stuck, :leaving or :skew; start_after_stop: the starting
  # marker written after the stop (else before it); reachable false with a
  # note: a combination the code doesn't make, asserted all the same;
  # transitioning: the session's transition lock held for real, by another
  # thread, while the row is read and driven (its deliveries then go
  # through the seats: Drivers#deliver_held).
  Row = Data.define(:name, :exists, :owner, :link, :stop, :start, :archived, :continuing, :start_after_stop,
                    :reachable, :note, :transitioning) do
    def initialize(name:, exists:, owner:, link:, stop: false, start: false, archived: false, continuing: false,
                   start_after_stop: false, reachable: true, note: nil, transitioning: false) = super

    def owner_record(now = Time.now)
      started = (now - 1).iso8601(3)
      case owner
      when :none then nil
      when :tui then Samagotchi::OwnerLock::Owner.new(pid: OWNER_PID, kind: "tui", started_at: started)
      when :deleting then Samagotchi::OwnerLock::Owner.new(pid: OWNER_PID, kind: Samagotchi::OwnerLock::DELETING)
      when :unknown then Samagotchi::OwnerLock::Owner.new
      else worker_record(now)
      end
    end

    # The facts in memory, as WorkerPresence would read them: what the row's
    # state is derived from (Reading.derive), files aside.
    def presence
      record = owner_record
      Samagotchi::WorkerPresence.new(session_id: name, exists: exists, owner: record, stop_marked: stop,
                                     starting_marked: start, archived: archived, link: link_of(record))
    end

    def state = Samagotchi::SessionLifecycle::Reading.derive(presence).state

    private

    def worker_record(now)
      started = (now - (link == :stuck ? 120 : 1)).iso8601(3)
      leaving = { leaving_at: now.iso8601(3), leave_wait: 5.0 } if link == :leaving
      Samagotchi::OwnerLock::Owner.new(pid: OWNER_PID, kind: "worker", started_at: started, **leaving.to_h)
    end

    def link_of(record)
      link_class = Samagotchi::WorkerLink
      case link
      when :stale then link_class::Stale.new(sidecar: LifecycleMatrix.sidecar(:stale), reason: :lock_free, owner: record)
      when :live then link_class::Live.new(sidecar: LifecycleMatrix.sidecar(:live), owner: record)
      when :skew then link_class::Skew.new(sidecar: LifecycleMatrix.sidecar(:skew), owner: record, reason: :protocol)
      when :leaving then link_class::Leaving.new(owner: record)
      when :starting, :stuck then link_class::Starting.new(owner: record, stuck: link == :stuck)
      else record && !record.tui? ? link_class::Starting.new(owner: record) : link_class::None.new(owner: record)
      end
    end
  end

  module_function

  # Every row: the owner/link pairs × stop × starting × archived, one
  # absent session, a continue in flight on each archived row with no
  # owner, a start marked after the stop on each no-owner row with both,
  # and a held transition lock on a few (HELD_ROWS).
  # @return [Array<Row>]
  def rows
    base = PAIRS.flat_map do |owner, link|
      [false, true].product([false, true], [false, true]).map do |stop, start, archived|
        name = [owner, link, ("stop" if stop), ("start" if start), ("archived" if archived)].compact.join("+")
        unreachable = owner == :tui && stop
        Row.new(name: name, exists: true, owner: owner, link: link, stop: stop, start: start, archived: archived,
                reachable: !unreachable,
                note: ("stop_session refuses a one-turn run's session (refuse_tui!)" if unreachable))
      end
    end
    no_owner = base.select { |row| row.owner == :none }
    continuing = no_owner.select(&:archived).map { |row| row.with(name: "#{row.name}+continuing", continuing: true) }
    after = no_owner.select { |row| row.stop && row.start }
                    .map { |row| row.with(name: "#{row.name}+start_after_stop", start_after_stop: true) }
    held = base.select { |row| HELD_ROWS.include?(row.name) }
               .map { |row| row.with(name: "#{row.name}+transitioning", transitioning: true) }
    [Row.new(name: "absent", exists: false, owner: :none, link: :none), *base, *continuing, *after, *held]
  end

  # The rows also driven with their transition lock held: idle, archived,
  # stopped and a live worker's.
  HELD_ROWS = %w[none+none none+none+archived none+none+stop worker+live].freeze

  # The sidecar a row's link stands on: its owner's pid and a port (Live,
  # Skew: protocol newer than this chi), or another pid's (Stale).
  def sidecar(link)
    protocol = Samagotchi::WorkerLink::PROTOCOL + (link == :skew ? 1 : 0)
    Samagotchi::WorkerSidecar.new(port: 45_678, pid: link == :stale ? OWNER_PID + 1 : OWNER_PID,
                                  features: %w[restart activity], version: Samagotchi::VERSION, epoch: "matrix",
                                  started_at: "2020-01-01T00:00:00Z", protocol: protocol)
  end

  # Write +row+'s files under +root+: the session file, the starting marker
  # (before the stop, or after it), the stop, the archive, the sidecar.
  # @return [Array(String, String)] the session id and its state dir
  def write(row, root)
    state_dir = File.join(root, row.name.tr("+", "_"))
    FileUtils.mkdir_p(state_dir)
    return [SecureRandom.uuid, state_dir] unless row.exists

    session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
    session.save(state_dir: state_dir)
    id = session.id
    mark_start = -> { Samagotchi::StartingMarker.mark(id, state_dir: state_dir, pid: Process.pid) }
    mark_start.call if row.start && !row.start_after_stop
    if row.stop
      at = row.start_after_stop ? Time.now - 5 : Time.now
      Samagotchi::Session.mark_stopped(id, state_dir: state_dir, now: at)
    end
    mark_start.call if row.start && row.start_after_stop
    Samagotchi::ArchiveStore.archive(id, state_dir: state_dir) if row.archived
    if %i[stale live skew].include?(row.link)
      sidecar(row.link).write(Samagotchi::Session.session_dir(id, state_dir: state_dir))
    end
    [id, state_dir]
  end

  # The drivers, for an example group (they stub with its mocks).
  module Drivers
    DELIVERY_OPS = (Samagotchi::SessionInbox::WakePolicy::ROWS.keys - %i[ring leave]).freeze
    # Operations that write (a stop marker, a cleared one, an unlinked
    # stale sidecar, a dropped reminder hand-off): each gets a fresh copy of
    # the row's files.
    WRITING_OPS = %i[resume stop attach leave].freeze
    # Writing operations that take the transition lock themselves
    # (stop_session's exclusive try): on a held row they are refused and
    # write nothing, so they run on the row's own files, whose lock is held.
    HELD_IN_PLACE = %i[stop].freeze

    def lifecycle_ops = Samagotchi::SessionLifecycle::ALLOWED.keys + HUB_OPS

    # The stand-ins every row shares: no spawn, no signal, no Bridge, no
    # restart fallback, no log line, an idle worker's activity.
    def stub_matrix_seams
      @matrix_resumes = nil
      @matrix_logged = []
      allow(Process).to receive(:spawn).and_return(20_002)
      allow(Process).to receive(:kill).and_call_original
      allow(Process).to receive(:kill).with("TERM", anything).and_return(1)
      allow(Process).to receive(:kill).with("CONT", anything).and_return(1)
      allow(Samagotchi::ProcessGroup).to receive(:stopped?).and_return(false)
      # A held row's stop is refused at once, not after the CLI's wait.
      stub_const("Samagotchi::SessionManager::STOP_LOCK_WAIT", 0)
      bridge = double("worker bridge")
      allow(bridge).to receive(:request_exit).and_raise(RestartAsked)
      allow(Samagotchi::BridgeClient).to receive(:for_sidecar).and_return(bridge)
      allow(Samagotchi::SessionManager).to receive(:restart_fallback).and_return(:fallback)
      allow(Samagotchi::SessionManager).to receive(:resume_session).and_wrap_original do |original, id, **options, &block|
        next original.call(id, **options, &block) unless @matrix_resumes

        @matrix_resumes << id
        Samagotchi::Session.load(id, state_dir: options[:state_dir])
      end
      allow(Samagotchi::Log).to receive(:info) { |_tag, event, **details| @matrix_logged << [event, details] }
    end

    # The row's owner and continue, for every reader.
    def stub_row(row)
      allow(Samagotchi::OwnerLock).to receive(:owner).and_return(row.owner_record)
      allow(Samagotchi::ContinueIntent).to receive(:in_flight).and_return(row.continuing ? SUCCESSOR : nil)
    end

    # What +op+ answers for session +id+ under +state_dir+, as a cell word
    # (ALLOWED's, SHOWN's for the hub; nil for the hub of an absent session).
    def drive(op, id, state_dir, row: nil)
      return deliver_held(op, id, state_dir) if row&.transitioning && DELIVERY_OPS.include?(op)
      return deliver(op, id, state_dir) if DELIVERY_OPS.include?(op)

      send(:"drive_#{op}", id, state_dir)
    end

    def deliver(kind, id, state_dir)
      presence = Samagotchi::WorkerPresence.read(id, state_dir: state_dir)
      Samagotchi::SessionLifecycle::DELIVERY_CELLS.fetch(
        Samagotchi::SessionInbox::WakePolicy.for(kind).decide(presence, wake: true, load: nil)
      )
    end

    # A delivery through its seat, its row's transition hold taken there:
    # an inbox kind through SessionInbox.deliver (it writes nothing, asks
    # for a worker, a start is :woken), a turn delivery's sender through
    # SessionManager.deliver_turn (a 409 transition_busy is :busy,
    # link_continued :continued; nothing else is expected while held).
    def deliver_held(kind, id, state_dir)
      turn = TURN_SENDERS[kind]
      unless turn
        delivered = Samagotchi::SessionInbox.deliver(kind, id, state_dir: state_dir, start: ->(_) { :woken }) { true }
        return delivered.wake == :woken ? :go : Samagotchi::SessionLifecycle::DELIVERY_CELLS.fetch(delivered.wake)
      end

      result = Samagotchi::SessionManager.deliver_turn(id, prompt: "matrix", client_id: turn, state_dir: state_dir,
                                                           bridge: -> {})
      return :busy if result.busy?
      return :continued if result.continued?

      raise "a turn from #{kind} went past a held transition lock: #{result.inspect}"
    end

    # The client id of each turn delivery's sender (ClientId.wake_kind).
    TURN_SENDERS = { send: "cli:send", schedule: Samagotchi::ClientId.schedule("matrix"),
                     plugin: Samagotchi::ClientId::PLUGIN, delegate: Samagotchi::ClientId.delegate("abcd1234"),
                     participant: Samagotchi::ClientId.participant("p_1"), agent: Samagotchi::ClientId.agent("matrix"),
                     automatic: "someone:else" }.freeze

    # The block with +id+'s transition lock held exclusively by another
    # thread when +row+ is transitioning (never this one: its own hold
    # would pass its shared ones through), else as is.
    def holding_for(row, id, state_dir)
      return yield unless row.transitioning

      taken = Queue.new
      release = Queue.new
      holder = Thread.new do
        Samagotchi::SessionTransition.exclusive(id, kind: :continue, state_dir: state_dir) do
          taken << true
          release.pop
        end
      end
      taken.pop(timeout: 10) or raise "the matrix's transition lock of #{id} was not taken"
      yield
    ensure
      release&.push(true)
      holder&.join
    end

    # A ring's wake (SessionManager.wake_for_report): a start is resume_session's stand-in.
    def drive_ring(id, state_dir)
      outcome = with_resume_stand_in { Samagotchi::SessionManager.wake_for_report(id, state_dir: state_dir) }
      outcome == :woken ? :go : Samagotchi::SessionLifecycle::DELIVERY_CELLS.fetch(outcome)
    end

    # A restart's leave starting its successor (WorkerBoot.respawn, private).
    def drive_leave(id, state_dir)
      @matrix_logged.clear
      dir = Samagotchi::Session.session_dir(id, state_dir: state_dir)
      resumed = with_resume_stand_in do
        Samagotchi::WorkerBoot.send(:respawn, id, state_dir: state_dir, session_dir: dir, result: :restart)
        @matrix_resumes
      end
      return :go if resumed.include?(id)

      _event, details = @matrix_logged.find { |event, _| %w[restart_dropped respawn_dropped].include?(event) }
      Samagotchi::SessionLifecycle::DELIVERY_CELLS.fetch(details.fetch(:why))
    end

    def drive_resume(id, state_dir)
      outcome = :woken
      Samagotchi::SessionManager.resume_session(id, state_dir: state_dir) { |done| outcome = done }
      { woken: :go, live: :live, starting: :starting }.fetch(outcome)
    rescue Samagotchi::SessionManager::OwnedByTUI
      :owned_by_tui
    rescue Samagotchi::Session::NotFound
      :gone
    end

    def drive_restart(id, state_dir)
      Samagotchi::SessionManager.restart_session(id, state_dir: state_dir, wait: 0)
    rescue RestartAsked
      :go
    rescue Samagotchi::SessionManager::RestartRefused => e
      e.reason
    rescue Samagotchi::SessionManager::OwnedByTUI
      :owned_by_tui
    rescue Samagotchi::Session::NotFound
      :gone
    end

    def drive_stop(id, state_dir)
      Samagotchi::SessionManager.stop_session(id, state_dir: state_dir)
      :go
    rescue Samagotchi::SessionTransition::Busy
      :busy
    rescue Samagotchi::SessionManager::OwnedByTUI
      :owned_by_tui
    rescue Samagotchi::Session::NotFound
      :gone
    end

    def drive_archive(id, state_dir)
      Samagotchi::SessionManager.archivable!(id, state_dir)
      :go
    rescue Samagotchi::SessionManager::ArchiveRefused => e
      e.reason
    rescue Samagotchi::SessionManager::OwnedByTUI
      :owned_by_tui
    rescue Samagotchi::Session::NotFound
      :gone
    end

    def drive_delete(id, state_dir)
      Samagotchi::SessionManager.release_for_delete!(id, state_dir: state_dir, stop: false, wait: 0)
      :go
    rescue Samagotchi::SessionManager::DeleteRefused => e
      e.reason
    rescue Samagotchi::SessionManager::OwnedByTUI
      :owned_by_tui
    end

    def drive_sched_chain(id, state_dir) = schedule_busy(Samagotchi::Schedules::CHAIN, id, state_dir)
    def drive_sched_same(id, state_dir) = schedule_busy(Samagotchi::Schedules::SAME, id, state_dir)

    # Schedules#busy_reason (private) for an entry in +mode+, its target the
    # row's session; a live worker's activity is idle with no streams.
    def schedule_busy(mode, id, state_dir)
      schedules = Samagotchi::Schedules.new(state_dir: state_dir)
      allow(schedules).to receive(:ask_activity)
        .and_return({ turn_running: false, input_pending: false, awaiting_continue: false, open_streams: 0 })
      links = Samagotchi::SessionChain::Links.new(state_dir: state_dir)
      verdict = schedules.send(:busy_reason, double("schedule entry", mode: mode), links, id)
      return :go if verdict.nil?

      REASONS.fetch(verdict.last) { raise KeyError, "no cell word for the schedule's #{verdict.inspect}" }
    end

    def drive_attach(id, state_dir)
      link = Samagotchi::TerminalUI::LocalLink.new(client: double("bridge client", session_id: id), state_dir: state_dir)
      found, why = link.live_worker
      return :"gone_#{why}" if found == :gone

      found ? :go : :wait
    end

    def drive_hub_status(id, state_dir) = hub(id, state_dir)&.fetch(:status)
    def drive_hub_bridge_up(id, state_dir) = hub(id, state_dir)&.fetch(:bridge_up)
    def drive_hub_live(id, state_dir) = hub(id, state_dir)&.fetch(:live)

    # The session hub's summary (Web::SessionSummary.build) of the session as
    # Session.load reads it; live is the live the summary gates the open
    # question on (SessionSummary.shown).
    def hub(id, state_dir)
      return nil unless Samagotchi::Session.exist?(id, state_dir: state_dir)

      @matrix_hub ||= {}
      @matrix_hub[[id, state_dir]] ||= begin
        session = Samagotchi::Session.load(id, state_dir: state_dir)
        dir = Samagotchi::Session.session_dir(id, state_dir: state_dir)
        owner = Samagotchi::SessionManager.session_owner(id, state_dir: state_dir)
        summary = Samagotchi::Web::SessionSummary.build(session, owner: owner, session_dir: dir)
        live = Samagotchi::Web::SessionSummary.shown(session, owner: owner, session_dir: dir).up
        { status: summary[:status], bridge_up: summary[:bridge_up], live: live }
      end
    end

    def with_resume_stand_in
      @matrix_resumes = []
      yield
    ensure
      @matrix_resumes = nil
    end

    # One pass: each row's files, its read, and every operation's cell.
    # @return [Array<Hash>] {row:, read:, cells: {op => cell}}
    def run_lifecycle_matrix(root)
      stub_matrix_seams
      LifecycleMatrix.rows.each_with_index.map do |row, index|
        stub_row(row)
        id, state_dir = LifecycleMatrix.write(row, File.join(root, index.to_s))
        holding_for(row, id, state_dir) do
          read = Samagotchi::SessionLifecycle.read(id, state_dir: state_dir)
          cells = lifecycle_ops.to_h do |op|
            dir = state_dir
            if WRITING_OPS.include?(op) && !(row.transitioning && HELD_IN_PLACE.include?(op))
              dir = "#{state_dir}.#{op}"
              FileUtils.cp_r(state_dir, dir)
            end
            [op, drive(op, id, dir, row: row)]
          end
          { row: row, read: read, cells: cells }
        end
      end
    end
  end
end
