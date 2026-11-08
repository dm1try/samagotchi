# frozen_string_literal: true

require_relative "session_manager"

module Samagotchi
  # WorkerBoot: the worker process, from run_session_loop (what the boot
  # string SessionManager#worker_command writes runs, through
  # SessionManager.run_session_loop) to what it does as it leaves (CROSS-VERSION
  # CONTRACT: spec/worker_contract_spec.rb). It takes the session's OwnerLock,
  # leaves the spawner's process tree, installs the signals and the project
  # env, and runs the Worker (worker.rb loads only then, after the lock). Calls
  # SessionManager's resume_session, discardable? and delete_session; the env
  # keys it reads are SessionManager's, which the spawner sets.
  module WorkerBoot
    class << self
      # Run the session loop inside the forked process: the worker's main,
      # which the boot string reaches through SessionManager.run_session_loop.
      #
      # Every worker starts its per-session Bridge (the single live client
      # transport) on a port bound to 127.0.0.1 before the loop and stops it on
      # exit. If the bridge fails to start the worker degrades: turns still flow
      # through the input-dir loop, but there is no live SSE or in-process
      # cancel/answer.
      #
      # The worker first takes the session's OwnerLock; when another owner holds
      # it (a racing resume spawned two workers, or the TUI has the session) it
      # exits quietly.
      #
      # A worker nobody uses returns once session.idle_exit_minutes have passed
      # (see WorkerIdleExit), and one a client asked to exit (Bridge POST /exit)
      # returns as soon as nothing keeps it. The next send wakes a new one.
      # @param idle_exit_minutes [Numeric, nil] nil: session.idle_exit_minutes
      # @param poll_interval [Numeric, nil] seconds between the loop's fallback
      #   ticks (nil: Worker::FALLBACK_TICK_SECONDS); queued turns wake it at once
      # A stopped session's worker exits 0 (a signalled one too) and a
      # crashed one 1, there.
      # @return [Symbol] :idle_exit, :exit_requested, :restart or :scratch_left
      def run_session_loop(session_id, state_dir: nil, owner_wait: OwnerLock::DEFAULT_WAIT,
                           idle_exit_minutes: nil, poll_interval: nil)
        # A worker inherits chi's locale (LC_ALL=C too): read files as UTF-8.
        Utf8Default.apply!
        sd = state_dir || Session.default_state_dir
        # The spawner passed the file and level through ENV; a worker's stderr
        # is /dev/null, so warnings only reach the file.
        Log.configure(stderr: false)
        Log.session_id = session_id
        session_dir = Session.session_dir(session_id, state_dir: sd)
        # Read (and taken out of ENV, so nothing the worker runs inherits it)
        # before anything else: set by spawn_options for a spawned worker.
        spawned = ENV.delete(SessionManager::WORKER_PROCESS_ENV) == "1"
        # Out of the spawner's process tree before the lock (it records this
        # process's pid) and before any thread starts.
        detach_from_spawner(session_dir) if ENV.delete(SessionManager::WORKER_DETACH_ENV) == "1"
        # Kept in a module ivar so the lock's File lives as long as the worker.
        @owner_lock = OwnerLock.acquire(session_dir, kind: "worker", wait: owner_wait)
        exit(0) unless @owner_lock
        # Set by the boot string when the newest installed chi didn't load.
        fallback = ENV.delete(SessionManager::BOOT_FALLBACK_ENV)
        Log.info(:worker, "start", cwd: Dir.pwd, version: VERSION)
        Log.warn(:worker, "boot_fallback", version: VERSION, error: fallback) if fallback
        # Tools follow the project (its `mise env`, computed once per worker;
        # this process's ENV is left as it is); never in a loop run in-process.
        apply_project_env(session_id, state_dir: sd) if spawned
        # A spawned worker stops its turn on TERM/HUP/INT and saves it; a
        # loop run in-process (specs) traps nothing.
        signals = spawned ? WorkerSignals.new.install! : WorkerSignals::NONE
        # Only now, after the detach and the lock: the Engine and all it loads.
        require_relative "worker"
        worker = Worker.new(session_id: session_id, state_dir: sd, session_dir: session_dir,
                            idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval, signals: signals,
                            owner_lock: @owner_lock)
        result = begin
          worker.run
        rescue StandardError, ScriptError => e
          # The worker's stderr is /dev/null: the log is the only trace.
          Log.exception(:worker, "crashed", e)
          raise
        ensure
          @owner_lock.release
          # A signal from here on ends the process as Ruby's default does.
          signals.restore!
        end
        Log.info(:worker, "stop", reason: result)
        # A scratch session goes with its worker however it leaves (its
        # terminal deletes it too, whichever comes first); nothing resumes it.
        if worker.scratch?
          delete_left_scratch(session_id, state_dir: sd)
          exit(result == :crashed ? 1 : 0) if %i[stopped signal crashed].include?(result)
          return result
        end
        # A stopped session is left as it is: no resume for input that came
        # in, no discard. One whose worker a signal stopped isn't discarded
        # either; input that came in (queued behind the turn it stopped)
        # wakes a new worker, as after an idle exit.
        exit(0) if result == :stopped
        if result == :signal
          SessionManager.resume_session(session_id, state_dir: sd) unless SessionInbox.find_new_input_files(session_dir).empty?
          exit(0)
        end
        exit(1) if result == :crashed
        # Only after the release: a writer that still saw this worker as the
        # owner may have queued input since the last check. Either it finds no
        # owner after its write and wakes one, or this finds its input.
        # A restart starts its successor here, on the newest chi installed
        # (worker_command), once this one's lock is free.
        # Delegate reports that rang while it left wake one too.
        if result == :restart && Session.stopped_marker?(session_id, state_dir: sd)
          # A stop landed as it left: no successor (resume_session would clear
          # the stop), and the reminders go with it.
          ReminderCarry.remove(session_dir)
          Log.info(:worker, "restart_dropped", why: :stopped)
        elsif result == :restart ||
              (%i[idle_exit exit_requested].include?(result) &&
            (!SessionInbox.find_new_input_files(session_dir).empty? || worker.wake_due?))
          SessionManager.resume_session(session_id, state_dir: sd)
        elsif worker.discard?
          discard_left_session(session_id, state_dir: sd, default_model: worker.default_model)
        end
        result
      end

      # A spawned worker leaves its spawner's process tree: a killer that
      # walks the tree by parent pid (a terminal closing, a tool's teardown
      # of a `chi send --wait` it ran in the background) no longer reaches it.
      # This process (the spawner's child, which its Process.detach waits on)
      # forks the worker, which starts a session of its own (setsid: no
      # controlling terminal, no SIGHUP from one) and returns to run the loop;
      # this one waits until the worker holds the session's OwnerLock, or has
      # exited, or WORKER_START_GRACE passed, and exits: the spawner's waiter
      # stays alive exactly while the worker starts (#still_starting?). The
      # worker is reparented to init (launchd), which reaps it.
      private def detach_from_spawner(session_dir)
        worker = Process.fork
        unless worker
          Process.setsid
          return
        end

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SessionManager::WORKER_START_GRACE
        until Process.waitpid(worker, Process::WNOHANG) || OwnerLock.owner(session_dir)&.pid == worker ||
              Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep(OwnerLock::RETRY_INTERVAL)
        end
        Process.exit!(0)
      end

      # Delete a scratch session its worker left (its terminal gone:
      # Worker#leave_scratch, or any other way out), now the lock is free.
      # Its terminal may have deleted it first.
      private def delete_left_scratch(session_id, state_dir:)
        SessionManager.delete_session(session_id, state_dir: state_dir)
        Log.info(:worker, "scratch_deleted", sid: session_id)
      rescue SessionManager::DeleteRefused, ArgumentError, SystemCallError => e
        Log.info(:worker, "scratch_kept", sid: session_id, error: e.class.name, msg: e.message)
      end

      # Delete a session its worker left empty. Checked again now the lock is
      # free: a note or input may have come in since the worker looked, and a
      # worker woken meanwhile owns it (delete_session refuses). A `chi send`
      # landing between this check and the delete fails with "no session"
      # (a window of an empty session's last moments, left as is).
      private def discard_left_session(session_id, state_dir:, default_model:)
        return unless SessionManager.discardable?(session_id, state_dir: state_dir, default_model: default_model)

        SessionManager.delete_session(session_id, state_dir: state_dir, purge_runs: false)
        Log.info(:worker, "discarded_empty", sid: session_id)
      rescue SessionManager::DeleteRefused, SessionManager::OwnedByTUI, ArgumentError, SystemCallError => e
        Log.info(:worker, "kept_session", sid: session_id, error: e.class.name, msg: e.message)
      end

      # The tools' ProjectEnv for the session's folder (its working_directory;
      # spawn_options chdirs there unless it is gone), installed for this
      # process's tool spawns. Never fatal: a worker without it still runs.
      private def apply_project_env(session_id, state_dir:)
        session = Session.summary_from_file(Session.session_file(session_id, state_dir: state_dir))
        dir = session&.working_directory.to_s
        overlay = ProjectEnv.install!(ProjectEnv.compute(dir))
        Log.info(:worker, "project_env_applied", dir: dir, ruby: overlay.ruby) if overlay.applied
      rescue StandardError => e
        Log.warn(:worker, "project_env", reason: "error", error: e.class.name, msg: e.message)
      end
    end
  end
end
