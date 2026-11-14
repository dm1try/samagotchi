# frozen_string_literal: true

require_relative "../worker_idle_exit"
require_relative "../bridge_client"
require_relative "../chi_invocation"
require_relative "../client_id"
require_relative "../log"
require_relative "../owner_lock"
require_relative "../process_group"
require_relative "../reminder_carry"
require_relative "../session"
require_relative "../session_inbox"
require_relative "../task_files"
require_relative "../tools/task_record"
require_relative "../tools/task_runtime"
require_relative "../worker_link"

module Samagotchi
  class SessionManager
    # A restart that can't happen now. reason: :not_running (no live worker:
    # the next prompt starts one on the newest chi anyway), :unsupported (a
    # worker from before restarts, running +version+: stop it instead), a
    # WorkerIdleExit#hold_for_restart hold (:turn_running, :reminders, ...),
    # :fallback_held (disk-visible work blocks an unresponsive-worker restart),
    # :stopped (its worker, +pid+, is SIGSTOPped: neither the ask nor a TERM
    # reaches it until it is continued), or :failed (the worker answered something else or didn't release).
    class RestartRefused < StandardError
      attr_reader :session_id, :reason, :version, :holds, :pid

      def initialize(session_id, reason, version: nil, holds: [], pid: nil, via: ChiInvocation::HERE)
        @session_id = session_id
        @reason = reason.to_sym
        @version = version
        @holds = Array(holds).map(&:to_sym).freeze
        @pid = pid
        super(RestartRefused.words(session_id, @reason, version, @holds, pid: pid, via: via))
      end

      HOLDS = {
        starting: "its worker is still starting",
        turn_running: "a turn is running",
        input_queued: "a prompt is queued",
        continue_offered: "the step-limit question waits for an answer",
        question_pending: "a question or approval waits for an answer",
        # Only a worker from before ReminderCarry still holds a restart for its reminders.
        reminders: "it has reminders, which its worker's older chi can't carry over a restart",
        command_running: "a /btw (or another command) is still running",
        relays_open: "a delegate's approval relayed here is open or just answered",
        background_tasks: "background tasks it started are still running",
        scratch: "a chi scratch session's worker ends with its terminal"
      }.merge(WorkerIdleExit::LEAVING_WORDS).freeze

      # What the CLI and the web say.
      def self.words(session_id, reason, version = nil, holds = [], pid: nil, via: ChiInvocation::HERE)
        stop = via.command("sessions stop #{session_id}")
        case reason
        when :stopped
          where = via.remote? ? " on #{via.remote}" : ""
          "session #{session_id}'s worker#{" (pid #{pid})" if pid} is stopped (SIGSTOP or Ctrl-Z) and can't take " \
            "a restart: continue it#{" with `kill -CONT #{pid}`" if pid}#{where}, then restart again"
        when :not_running
          "session #{session_id} has no running worker; the next prompt starts one on the newest chi"
        when :unsupported
          "session #{session_id}'s worker runs chi #{version || "(older)"}, which can't restart: " \
            "#{stop}, then any prompt starts it on the newest chi"
        when :fallback_held
          why = holds.map { |hold| HOLDS.fetch(hold, hold.to_s.tr("_", " ")) }.join("; ")
          "session #{session_id} has disk-visible work that a restart might lose#{": #{why}" unless why.empty?}; " \
            "run `#{stop}`, then any prompt starts it on the newest chi"
        when :failed then "session #{session_id}'s worker didn't take the restart"
        else "not now: #{HOLDS.fetch(reason, reason.to_s.tr("_", " "))}"
        end
      end
    end

    # What a restart did: the worker's version before and after (nil when
    # the new worker hadn't published its Bridge within the wait).
    Restarted = Struct.new(:session_id, :from_version, :version, keyword_init: true)

    RESTART_WAIT = 10.0
    # A TERMed worker writes its recap on leave (an LLM call) while it still
    # holds the lock: STOP_WAIT plus the recap's own wait (SessionContinue::RECAP_WAIT).
    FALLBACK_STOP_WAIT = 40

    STOP_CANCEL_WAIT = 3.0
    # How long a stop from the CLI (chi sessions stop, delete, a continue's
    # orphan) waits for the worker to let go of the session, here or
    # through chi web (POST …/stop's wait, capped at it).
    STOP_WAIT = 10
    # The cancel reason of a turn a session stop cancels (Bridge::CANCEL_REASONS):
    # not the user's Stop, which only ends the turn ("user").
    STOP_CANCEL_REASON = "session_stopped"

    # Lifecycle: stop a session's worker (TERM, then CONT) and restart it on
    # the newest chi (its Bridge's POST /exit, else the fallback). Calls
    # SpawnPart's resume_session and the facade's ownership checks. Meant to
    # be loaded through samagotchi/session_manager.
    module LifecyclePart
      # Hand a session to a new worker on the newest chi installed: ask its
      # worker (POST /exit restart: true), which leaves only when nothing would
      # be lost and starts its successor. If the worker cannot be asked, stop
      # it without a stop marker and resume only when disk shows no work to lose.
      # @return [Restarted]
      # @raise [OwnedByTUI] a one-turn chi run owns the session
      # @raise [RestartRefused]
      # @raise [ArgumentError] no such session
      def restart_session(session_id, state_dir: nil, wait: RESTART_WAIT, client_id: ClientId::CLI_RESTART)
        sd = state_dir || Session.default_state_dir
        Session.load(session_id, state_dir: sd) # ArgumentError for none
        owner = refuse_tui!(session_id, state_dir: sd)
        # A stopped worker answers neither the ask (READ_TIMEOUT) nor the
        # fallback's TERM (FALLBACK_STOP_WAIT): say so now, not after ~70 s.
        raise RestartRefused.new(session_id, :stopped, pid: owner.pid) if owner&.worker? && ProcessGroup.stopped?(owner.pid)

        dir = Session.session_dir(session_id, state_dir: sd)
        link = WorkerLink.resolve(dir, unlink: false, owner: owner)
        if link.is_a?(WorkerLink::Skew)
          return restart_fallback(session_id, owner: owner, sidecar: link.sidecar, state_dir: sd, wait: wait, why: :skew)
        end

        if link.is_a?(WorkerLink::Starting)
          return restart_fallback(session_id, owner: owner, sidecar: nil, state_dir: sd, wait: wait, why: :starting_stuck) if link.stuck

          raise RestartRefused.new(session_id, :starting)
        end
        raise RestartRefused.new(session_id, :not_running) unless link.live?

        sidecar = link.sidecar
        unless sidecar.features.include?("restart")
          raise RestartRefused.new(session_id, :unsupported, version: sidecar.version)
        end

        begin
          reply = BridgeClient.for_sidecar(session_id, sidecar).request_exit(client_id: client_id, restart: true)
        rescue SystemCallError, IOError => e
          return restart_fallback(session_id, owner: owner, sidecar: sidecar, state_dir: sd, wait: wait, why: :unreachable,
                                                                          error: e)
        end
        raise RestartRefused.new(session_id, reply.json&.fetch("reason", nil) || :failed) if reply.status == 409
        if reply.secret_refused?
          return restart_fallback(session_id, owner: owner, sidecar: sidecar, state_dir: sd, wait: wait, why: :bridge_secret)
        end
        raise RestartRefused.new(session_id, :failed) unless reply.status == 200

        Log.info(:worker, "restart", sid: session_id, from: sidecar.version, by: client_id)
        fresh = WorkerLink.await(session_id, session_dir: dir, timeout: wait, unlink: false, interval: 0.1,
                                 until: ->(live) { live.epoch != sidecar.epoch || live.started_at != sidecar.started_at })
        # Timed out: the last outcome, the old worker's Live too, is no successor.
        changed = fresh.live? && (fresh.epoch != sidecar.epoch || fresh.started_at != sidecar.started_at)
        version = fresh.version if changed
        Restarted.new(session_id: session_id, from_version: sidecar.version, version: version)
      end

      private def restart_fallback(session_id, owner:, sidecar:, state_dir:, wait:, why:, error: nil)
        Log.info(:worker, "restart_fallback", sid: session_id, why: why, error: error&.class&.name, msg: error&.message)
        dir = Session.session_dir(session_id, state_dir: state_dir)
        session = Session.load(session_id, state_dir: state_dir)
        holds = restart_fallback_holds(session, dir)
        raise RestartRefused.new(session_id, :fallback_held, holds: holds) unless holds.empty?
        raise RestartRefused.new(session_id, :failed, version: sidecar&.version) unless (owner&.pid || 0).to_i.positive?

        # The ask may have taken READ_TIMEOUT: TERM only the owner read at the
        # start; a successor that took the lock meanwhile is awaited, not killed.
        current = session_owner(session_id, state_dir: state_dir)
        if current.nil?
          resume_session(session_id, state_dir: state_dir)
        elsif current.pid == owner.pid && current.started_at == owner.started_at
          begin
            Process.kill("TERM", owner.pid)
          rescue Errno::ESRCH
            nil
          rescue SystemCallError => e
            Log.warn(:worker, "restart_fallback_failed", sid: session_id, why: why, error: e.class.name, msg: e.message)
            raise RestartRefused.new(session_id, :failed, version: sidecar&.version)
          end
          unless wait_for_owner_release(session_id, timeout: FALLBACK_STOP_WAIT, state_dir: state_dir)
            raise RestartRefused.new(session_id, :failed, version: sidecar&.version)
          end

          resume_session(session_id, state_dir: state_dir)
        end
        previous_epoch = sidecar&.epoch
        previous_started_at = sidecar&.started_at
        fresh = WorkerLink.await(session_id, session_dir: dir, timeout: wait, unlink: false, interval: 0.1,
                                 until: ->(live) { live.epoch != previous_epoch || live.started_at != previous_started_at })
        changed = fresh.live? && (fresh.epoch != previous_epoch || fresh.started_at != previous_started_at)
        Restarted.new(session_id: session_id, from_version: sidecar&.version, version: (fresh.version if changed))
      end

      private def restart_fallback_holds(session, session_dir)
        holds = []
        holds << :turn_running if session.status == Session::STATUS_RUNNING
        holds << :question_pending if session.pending_question
        holds << :input_queued unless SessionInbox.find_new_input_files(session_dir).empty?
        holds << :background_tasks if running_created_task?(session)
        holds
      end

      private def running_created_task?(session)
        root = session.working_directory.to_s
        return false if root.empty?

        Tools::TaskRuntime.created_ids_in(session.messages).any? do |id|
          next false unless TaskFiles::TASK_ID.match?(id)

          path = File.join(root, TaskFiles::TASKS_DIR, id, TaskFiles::METADATA_FILENAME)
          next false unless File.file?(path)

          Tools::TaskRecord.from_file(JSON.parse(File.read(path)))&.running?
        rescue JSON::ParserError, SystemCallError => e
          Log.warn(:worker, "restart_task_check_failed", sid: session.id, task_id: id,
                                                             error: e.class.name, msg: e.message)
          true
        end
      end

      # Stop a session by sending TERM (then CONT, for a stopped one) to its process.
      # With +wait+ (seconds), also wait for the owner to let go of the session,
      # so a resume right after spawns a fresh worker instead of finding the
      # dying one.
      # A turn still running is canceled first (STOP_CANCEL_WAIT), as the
      # web's Cancel does, with reason STOP_CANCEL_REASON: its worker saves it. The TERM stops (and saves)
      # what still runs (WorkerSignals), with a short grace after the marker.
      # @return [Boolean, nil] with +wait+: whether the owner was gone in time
      # @raise [OwnedByTUI] when the interactive TUI owns the session
      def stop_session(session_id, state_dir: nil, wait: nil)
        sd = state_dir || Session.default_state_dir
        owner = refuse_tui!(session_id, state_dir: sd)

        cancel_running_turn(session_id, state_dir: sd)
        # Mark first: a worker that has not taken the lock yet sees it and exits.
        Session.mark_stopped(session_id, state_dir: sd)
        # A stop drops the reminders: a restart's hand-off no successor took
        # yet must not bring them back on the next resume.
        ReminderCarry.remove(Session.session_dir(session_id, state_dir: sd))
        # A deleter holding the lock (chi web, the CLI) is no worker to stop.
        pid = owner&.deleting? ? 0 : owner&.pid.to_i
        begin
          Process.kill("TERM", pid) if pid && pid > 0
        rescue Errno::ESRCH
          nil # already exited
        end
        continue_stopped(pid)
        wait_for_owner_release(session_id, timeout: wait, state_dir: sd) if wait
      end

      # A stopped worker (SIGSTOP, Ctrl-Z) runs its TERM handler only once
      # continued: CONT it after the TERM (as ProcessGroup.stop does), so it
      # leaves now rather than outliving the stop's wait. Best effort: one the
      # TERM ended may be gone already.
      private def continue_stopped(pid)
        Process.kill("CONT", pid) if pid && pid > 0
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # Cancel the session's running turn over its Bridge and wait (up to
      # STOP_CANCEL_WAIT) for the worker to save it. Best effort: without a
      # live Bridge, or when it doesn't answer, the stop goes on as before.
      private def cancel_running_turn(session_id, state_dir:)
        return unless Session.load(session_id, state_dir: state_dir).status == Session::STATUS_RUNNING

        client = WorkerLink.client(session_id, session_dir: Session.session_dir(session_id, state_dir: state_dir))
        return unless client && client.cancel(reason: STOP_CANCEL_REASON).status == 202

        BridgeClient.poll(STOP_CANCEL_WAIT) do
          Session.load(session_id, state_dir: state_dir).status != Session::STATUS_RUNNING
        end
      rescue StandardError => e
        Log.info(:worker, "stop_cancel_failed", sid: session_id, error: e.class.name, msg: e.message)
        nil
      end

      # @return [Boolean] whether the session had no owner within +timeout+ seconds
      def wait_for_owner_release(session_id, timeout:, state_dir:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
        while session_owner(session_id, state_dir: state_dir)
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep(OwnerLock::RETRY_INTERVAL)
        end
        true
      end
    end

    extend LifecyclePart
  end
end
