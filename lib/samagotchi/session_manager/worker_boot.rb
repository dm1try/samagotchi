# frozen_string_literal: true

module Samagotchi
  class SessionManager
    # CROSS-VERSION CONTRACT: this boot string, run_session_loop(id,
    # state_dir:), the env keys spawn_options sets and the input/ file
    # format are read by a NEWER chi than the one writing them. Change them
    # only additively (spec/worker_contract_spec.rb).
    BOOT_FALLBACK_ENV = "SAMAGOTCHI_BOOT_FALLBACK"
    # "1" in a worker spawn_options started: it traps signals (WorkerSignals).
    # run_session_loop deletes it from ENV as it reads it.
    WORKER_PROCESS_ENV = "SAMAGOTCHI_WORKER_PROCESS"
    # "1" in a worker spawn_options started: run_session_loop leaves the
    # spawner's process tree first (detach_from_spawner); deleted from ENV
    # as it is read, so an rspec run by the worker's execute never forks.
    WORKER_DETACH_ENV = "SAMAGOTCHI_WORKER_DETACH"

    # The boot string's rescue under a chi home: one line in the spawner's
    # log file (SAMAGOTCHI_LOG_FILE, set by spawn_options), LogLine's shape,
    # then exit. Single-quoted: the #{} run in the worker. SID is replaced.
    # rubocop:disable-next Lint/InterpolationCheck -- the worker interpolates these, not this process
    HOME_BOOT_FAILED = 'rescue ScriptError, StandardError => e; f = ENV["SAMAGOTCHI_LOG_FILE"].to_s; begin; ' \
                       'File.open(f, "a") { |io| io.puts(Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ") + ' \
                       '" ERROR worker pid=#{Process.pid} sid=SID boot_failed ruby=#{RbConfig.ruby.inspect} error=" + ' \
                       "e.message.lines.first.to_s.strip.inspect) } unless f.empty?; rescue SystemCallError; end; exit 1"

    # WorkerBoot: the worker process, from its spawn options and command line
    # to run_session_loop inside it and what it does as it leaves (CROSS-VERSION
    # CONTRACT: spec/worker_contract_spec.rb). Calls SpawnPart's note_spawn and
    # resume_session, EmptinessPart's discardable? and RemovalPart's
    # delete_session. Loaded only through samagotchi/session_manager.
    module WorkerBootPart
      # Build the opts hash passed to Process.spawn for a forked worker. The
      # child inherits this process's ENV and reads config.yml itself (as it
      # is when the worker starts); opts[:env] adds to it (merged, not
      # replaced) what it can't read there: this `chi`'s CLI settings
      # (Config.cli_env) and the absolute log file. It unsets
      # what ChildEnv lists (SAMAGOTCHI_GUARDRAILS_*, the session markers).
      # XDG_CONFIG_HOME passes: whoever starts or
      # wakes the worker picks which config.yml it reads (docs/guardrails.md).
      # XDG_STATE_HOME and XDG_CONFIG_HOME, when set, pass made absolute
      # (Paths): the worker starts in the session's directory.
      private def spawn_options(session)
        # Own process group: workers outlive `chi web`, and a Ctrl-C in its
        # terminal must not reach them (the worker then leaves the process
        # tree too: WORKER_DETACH_ENV).
        opts = { out: File::NULL, err: File::NULL, pgroup: true }
        # The worker's tools (and `!cmd`) run in the session's directory, not
        # in the cwd of whoever woke it (`chi web`, another terminal).
        dir = session.working_directory.to_s
        if !dir.empty? && File.directory?(dir)
          opts[:chdir] = dir
        else
          Log.warn(:worker, "cwd_gone", sid: session.id, dir: dir, cwd: Dir.pwd)
        end
        # (A chi a session's tool runs took that session's project env out at
        # its start: bin/chi, ProjectEnv.take_orig!.)
        child_env = {}
        # A worker gets no CLI args: --model, --thinking, --log-level and the
        # other flags this chi was started with.
        child_env.merge!(Config.cli_env)
        child_env[ModelProfile::MODEL_FROM_CLI_ENV] = "1" if child_env.key?(ModelProfile::MODEL_ENV)
        # And the spawner's debug log, absolute: a relative log.file would
        # otherwise land in the worker's (the session's) directory.
        log_path = begin LogPath.resolve rescue nil end # degrade-ok: no log to say it in; the worker's is off (below)
        if log_path
          child_env["SAMAGOTCHI_LOG_FILE"] = log_path
        else
          child_env["SAMAGOTCHI_LOG_DISABLE"] = "true"
        end
        # And the spawner's XDG dirs, absolute: a relative XDG_STATE_HOME or
        # XDG_CONFIG_HOME would otherwise be read from the session's directory.
        child_env.merge!(Paths.absolute_xdg)
        # Unset (Process.spawn unsets a key mapped to nil) what no child chi
        # takes from its spawner (ChildEnv): the spawner's guardrails settings
        # (a parent agent starting or waking a session; config.yml no longer
        # reads them, this keeps an older or future env-exposed one out as
        # well); the session markers, a session's own (a worker started from
        # its commands, chi send, is another session: its execute and tasks
        # set its own; nothing else it runs has one); and a smoke's fake
        # "newest installed", for this process's notices only.
        child_env.merge!(ChildEnv.unset)
        # A worker process: run_session_loop traps signals, and leaves this
        # process's tree.
        child_env[WORKER_PROCESS_ENV] = "1"
        child_env[WORKER_DETACH_ENV] = "1"
        # A gem-mode worker activates the newest installed chi itself: under
        # `bundle exec` (a Gemfile that has samagotchi) Bundler's RUBYOPT would
        # hold it to the bundle's version, and its badge would never clear.
        child_env.merge!(ChildEnv.unbundled)
        opts[:env] = child_env unless child_env.empty?
        opts
      end

      # Run the session loop inside the forked process.
      # This is the entry point called by Process.spawn.
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
        spawned = ENV.delete(WORKER_PROCESS_ENV) == "1"
        # Out of the spawner's process tree before the lock (it records this
        # process's pid) and before any thread starts.
        detach_from_spawner(session_dir) if ENV.delete(WORKER_DETACH_ENV) == "1"
        # Kept in a class ivar so the lock's File lives as long as the worker.
        @owner_lock = OwnerLock.acquire(session_dir, kind: "worker", wait: owner_wait)
        exit(0) unless @owner_lock
        # Set by the boot string when the newest installed chi didn't load.
        fallback = ENV.delete(BOOT_FALLBACK_ENV)
        Log.info(:worker, "start", cwd: Dir.pwd, version: VERSION)
        Log.warn(:worker, "boot_fallback", version: VERSION, error: fallback) if fallback
        # Tools follow the project (its `mise env`, computed once per worker;
        # this process's ENV is left as it is); never in a loop run in-process.
        apply_project_env(session_id, state_dir: sd) if spawned
        # A spawned worker stops its turn on TERM/HUP/INT and saves it; a
        # loop run in-process (specs) traps nothing.
        signals = spawned ? WorkerSignals.new.install! : WorkerSignals::NONE
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
          resume_session(session_id, state_dir: sd) unless SessionInbox.find_new_input_files(session_dir).empty?
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
          resume_session(session_id, state_dir: sd)
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

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WORKER_START_GRACE
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
        delete_session(session_id, state_dir: state_dir)
        Log.info(:worker, "scratch_deleted", sid: session_id)
      rescue DeleteRefused, ArgumentError, SystemCallError => e
        Log.info(:worker, "scratch_kept", sid: session_id, error: e.class.name, msg: e.message)
      end

      # Delete a session its worker left empty. Checked again now the lock is
      # free: a note or input may have come in since the worker looked, and a
      # worker woken meanwhile owns it (delete_session refuses). A `chi send`
      # landing between this check and the delete fails with "no session"
      # (a window of an empty session's last moments, left as is).
      private def discard_left_session(session_id, state_dir:, default_model:)
        return unless discardable?(session_id, state_dir: state_dir, default_model: default_model)

        delete_session(session_id, state_dir: state_dir, purge_runs: false)
        Log.info(:worker, "discarded_empty", sid: session_id)
      rescue DeleteRefused, OwnedByTUI, ArgumentError, SystemCallError => e
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

      def config_idle_exit_minutes
        Degrade.call(:config, "idle_exit_minutes_unreadable") { Samagotchi::Config.get("session.idle_exit_minutes") }
      end

      # The worker's command line. Run from an installed gem, the worker
      # activates the newest installed samagotchi (`>= 0.a`, prereleases
      # count), whoever spawns it: an old chi web, chi send or --attach then
      # starts new workers on the newest chi rather than on its own. Activating
      # the gem also makes its dependencies resolve as its gemspec pins them
      # (reline ~> 0.6.3). Should that fail (a broken newest install), the
      # worker falls back to the spawner's own version and logs why.
      #
      # A source checkout (bin/chi, bundle exec; InstalledGem.spec is nil
      # there) keeps the plain -I lib: a worktree's bin/chi spawns its own code.
      def worker_command(session_id, state_dir:, gem_spec: InstalledGem.spec,
                         home: ChiHome.current(gem_spec: gem_spec))
        boot = "require 'samagotchi/session_manager'; " \
               "Samagotchi::SessionManager.run_session_loop('#{session_id}', state_dir: #{state_dir.inspect})"
        return [RbConfig.ruby, "-I", File.expand_path("../..", __dir__), "-e", boot] unless gem_spec
        return home_worker_command(session_id, state_dir: state_dir, gem_spec: gem_spec, home: home) if home

        activate = "begin; gem 'samagotchi', '>= 0.a'; rescue LoadError => e; " \
                   "ENV['#{BOOT_FALLBACK_ENV}'] = e.message; gem 'samagotchi', '= #{gem_spec.version}'; end"
        [RbConfig.ruby, "-e", "#{activate}; #{boot}"]
      end

      # With a chi home (ChiHome.current, docs/architecture.md "How chi
      # launches itself"): the home's ruby, `Gem.paths` set to its gems in the
      # boot string (no GEM_* in the worker's env), the newest chi there, else
      # the fallback pin (ChiHome.fallback_version). A home that still can't
      # load chi (a broken install) logs HOME_BOOT_FAILED and exits: never a
      # silent spawn timeout.
      private def home_worker_command(session_id, state_dir:, gem_spec:, home:)
        newest = home.newest_version
        if newest && newest < Gem::Version.new(gem_spec.version.to_s)
          ChiHome.warn_once(:older_than_spawner, home: newest.to_s, spawner: gem_spec.version.to_s)
        end
        fallback = ChiHome.fallback_version(home, gem_spec)
        activate = if fallback
                     "begin; gem 'samagotchi', '>= 0.a'; rescue LoadError => e; " \
                       "ENV['#{BOOT_FALLBACK_ENV}'] = e.message; gem 'samagotchi', '= #{fallback}'; end"
                   else
                     "gem 'samagotchi', '>= 0.a'"
                   end
        home.boot_argv(run: "begin; #{activate}; require 'samagotchi/session_manager'; " \
                             "#{HOME_BOOT_FAILED.sub("SID", session_id)}; end; " \
                             "Samagotchi::SessionManager.run_session_loop('#{session_id}', state_dir: #{state_dir.inspect})")
      end

      # Start the in-process Bridge transport for this worker. The bridge is
      # the single live client transport, so every worker starts it. Bridge
      # creation happens *before* the loop so the capture observer is in place
      # for the whole session; the caller stops the returned instance on exit
      # (see Worker#run's ensure).
      #
      # @return [Samagotchi::Bridge, nil] nil when the transport failed to start
      #   (the worker degrades: turns still flow through the input-dir loop, but
      #   there is no live SSE or in-process cancel/answer).
      # @param on_input [#call, nil] called after the Bridge queues a turn
      def start_bridge(engine:, state_dir:, session_id:, on_input: nil, on_command: nil, on_exit_request: nil,
                       exit_discards: nil, exit_stopped: nil, on_holds: nil, on_holds_stop: nil)
        require_relative "../bridge"
        Samagotchi::Bridge.new(
          engine: engine, state_dir: state_dir, session_id: session_id, input_format: SessionInbox::INPUT_FORMAT,
          on_input: on_input, on_command: on_command, on_exit_request: on_exit_request, exit_discards: exit_discards,
          exit_stopped: exit_stopped, on_holds: on_holds, on_holds_stop: on_holds_stop
        ).start
      rescue StandardError => e
        Log.error(:bridge, "start_failed", echo: "Bridge: failed to start for session #{session_id}: #{e.class}: #{e.message}", sid: session_id, error: e.class.name)
        nil
      end
    end

    extend WorkerBootPart
  end
end
