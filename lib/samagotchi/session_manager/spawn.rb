# frozen_string_literal: true

module Samagotchi
  class SessionManager
    # How long after a spawn a resume trusts that worker to take the
    # session, while it runs (and the session wasn't stopped since).
    WORKER_START_GRACE = WorkerLink::START_LIMIT

    @spawns = {}
    @spawns_mutex = Mutex.new

    # Spawn: deciding to start a session's worker (a new session, a resume, a
    # delegate's report waking its parent) and the spawns this process
    # remembers. Calls WorkerBootPart's spawn_options and worker_command and
    # the facade's ownership checks. Loaded only through samagotchi/session_manager.
    module SpawnPart
      # Spawn a new background session that processes the given prompt (or,
      # with none, waits idle for input).
      #
      # Returns the session object with its ID. Every worker always starts its
      # per-session Bridge (the single live client transport), so external
      # clients can reach it once the sidecar is published.
      # @param memories [Array<String>] --memory: preloaded into the worker's prompt
      # @param muted_memories [Array<String>] --mute: hidden from the session
      #   (both are session fields, so a respawn keeps them)
      # @param parent_id [String, nil] the session that delegates this one (the
      #   `delegate` tool) or was forked from; a session field too
      # @param messages [Array<Hash>] a conversation to start from (a plugin's
      #   ctx.sessions.fork); its image refs are copied from +images_from+
      # @param images_from [String, nil] the session dir the seed's images are in
      # @param preview [String, nil] what the lists show before the first turn
      #   (the prompt's preview by default, else the seed's first user message)
      # @param title [String, nil] the session's own name (Session#title; a
      #   continue's link inherits its previous link's), saved before the
      #   worker starts: the worker owns the file from then on
      # @param setup [SessionSetup] the session's own settings (chi
      #   --llm-context; a fork and a continue copy their session's; a delegate
      #   child the toolkit its delegate call named); without a toolkit the
      #   session is stored on config's toolkit.default, a delegate child on
      #   toolkit.child (Toolkit.configured)
      # @param continues [String, nil] the session this one continues (a
      #   session field; SessionContinue)
      # @param note [String, nil] a context note the session starts with,
      #   from +note_source+: queued before its worker spawns, so its first
      #   turn sees it
      # @param review [SessionReview, nil] a review session's (ReviewStart; a
      #   continue keeps its previous link's)
      # @param verify_fresh [VerifyFreshOrigin, nil] a Verify fresh child's
      #   requester, rules and claim (VerifyFresh.start)
      # @param before_spawn [#call, nil] (session) runs once the session and
      #   its note are saved, before its worker spawns
      # @param scratch [Boolean] a `chi scratch` session (its terminal's
      #   AttachLauncher): its worker runs a scratch Engine and deletes it
      #   once its last client is gone
      # @return [Session] with #seed_images_dropped: refs whose file was gone,
      #   and #model_warning: an id its host's saved list doesn't have
      def spawn_session(prompt:, mode: "assist", working_directory: nil, model_name: nil, state_dir: nil,
                        memories: [], muted_memories: [], parent_id: nil, messages: [], images_from: nil,
                        preview: nil, title: nil, delegate: false, setup: SessionSetup.new, continues: nil, note: nil,
                        note_source: "chi", before_spawn: nil, review: nil, verify_fresh: nil, scratch: false)
        sd = state_dir || Session.default_state_dir
        # The resolved ref is stored (a resumed session keeps its model when an
        # alias is retargeted), with the name as typed beside it. A wrong host
        # refuses here, before anything is saved or spawned; a model id the
        # host's saved list doesn't have (ModelListStore) only warns
        # (#model_warning on the session), as some hosts serve ids they don't
        # list.
        typed = Samagotchi::ModelProfile.check_host!(Samagotchi::ModelProfile.required_model_name(model_name))
        model_warning = Samagotchi::ModelProfile.model_warning(typed)
        ref = HostConfig.model_ref(typed).ref
        session = Session.new_session(
          mode: mode,
          model_name: ref,
          model_typed: typed == ref ? nil : typed,
          working_directory: working_directory || Dir.pwd,
          preloaded_memory_names: memories,
          muted_memory_names: muted_memories,
          parent_id: parent_id,
          messages: messages,
          delegate: delegate,
          setup: setup,
          continues: continues,
          review: review,
          scratch: scratch
        )
        session.toolkit = Toolkit.configured(delegate: delegate) if session.toolkit.nil?
        session.toolkit_origin = setup.toolkit_origin || "default"
        # Saved before the worker starts: its first turn is already the requester's.
        session.verify_fresh = verify_fresh
        session.model_warning = model_warning
        # With no prompt there is no first turn to run (an attaching UI sends
        # the prompts), so the session starts idle.
        session.status = prompt.to_s.strip.empty? ? Session::STATUS_IDLE : Session::STATUS_RUNNING
        session.last_prompt = prompt
        # The first prompt's turn gets an id like a sent message's, so a wait
        # for it can name it (chi send --new --wait, chi web's create): the
        # worker runs it with that origin, and its reply file and last_turn
        # carry the id.
        session.first_turn_id = SecureRandom.uuid unless prompt.to_s.strip.empty?
        # The worker takes last_prompt and clears it, and messages are saved at
        # the turn's end: until then this is the only preview a list has.
        session.first_preview = Session.preview_of(preview.to_s.strip.empty? ? prompt : preview)
        session.title = title
        session_dir = Session.session_dir(session.id, state_dir: sd)
        unless session.messages.empty?
          session.messages, dropped = ImageStore.copy_refs(session.messages, from: images_from, to: session_dir)
          session.seed_images_dropped = dropped
        end
        setup_session_directory(session_dir, session, state_dir: sd)
        SessionInbox.write_note(session.id, text: note, source: note_source, state_dir: sd) if note
        before_spawn&.call(session)
        spawn_worker_for_session(session, state_dir: sd)
        session
      end

      # Start the next link of a chain (SessionContinue.run, which has the
      # rules and raises SessionContinue::Refused).
      def continue_session(...) = SessionContinue.run(...)

      # Ensure an existing session has a live worker process.
      # Returns the loaded session after state reconciliation.
      # @raise [OwnedByTUI] when the interactive TUI owns the session
      def resume_session(session_id, state_dir: nil)
        sd = state_dir || Session.default_state_dir
        session = Session.load(session_id, state_dir: sd)
        # Its terminal's worker came from spawn_session; nothing wakes another.
        raise ScratchSession, session.id if session.scratch
        return session if refuse_tui!(session.id, state_dir: sd)

        # status is turn state, not liveness: a new worker runs no turn yet,
        # and must not find the session stopped (it would exit): neither the
        # marker nor a status field from before it.
        # One this process just spawned may not hold the lock yet (a slow
        # start, deliver_turn's second resume): it would only lose it.
        return session if still_starting?(session.id, state_dir: sd)
        # A continue moving delegates to it spawns its worker once they are
        # moved; one spawned now (a moved child's ring) would race the move.
        return session if ChildMove.starting?(session.id, state_dir: sd)

        Session.clear_stopped(session.id, state_dir: sd)
        session.status = Session::STATUS_IDLE
        session.save(state_dir: sd)
        spawn_worker_for_session(session, state_dir: sd)
        session
      end

      # A delegate child rang a parent that has no worker (ChildRing): start
      # one, which runs a turn for the report. Not for a parent that is gone,
      # stopped, archived, a scratch session, a one-turn run's, or a
      # continue's new link still taking its delegates (its own spawn comes):
      # the ring waits on disk for whoever runs it next (#resume_session
      # itself would clear the stop). A stop landing between the check and
      # the resume is a small window, left as is. An archived parent with a
      # later link in its chain wakes that link instead: a ring a moved child
      # wrote just as the continue moved it reaches the new link that way
      # (ChildReports reads its predecessor's rings).
      # @return [Symbol] :woken, or why not (:gone, :stopped, :archived,
      #   :scratch, :owned, :starting)
      def wake_for_report(session_id, state_dir: nil, forward: true)
        sd = state_dir || Session.default_state_dir
        return :gone unless Session.exist?(session_id, state_dir: sd)
        return :owned if session_owner(session_id, state_dir: sd)
        return :stopped if Session.stopped_marker?(session_id, state_dir: sd)

        if ArchiveStore.archived?(Session.session_dir(session_id, state_dir: sd))
          following = forward && SessionChain.next_of(session_id, state_dir: sd)
          return following ? wake_for_report(following, state_dir: sd, forward: false) : :archived
        end
        return :starting if ChildMove.starting?(session_id, state_dir: sd)

        session = Session.load(session_id, state_dir: sd)
        return :stopped if session.status == Session::STATUS_STOPPED
        return :scratch if session.scratch

        resume_session(session_id, state_dir: sd)
        Log.info(:worker, "delegate_woke_parent", parent: session_id[0, 8])
        :woken
      rescue OwnedByTUI
        :owned
      end

      # A worker this process spawned for the session within
      # WORKER_START_GRACE is still running, and no stop came since.
      private def still_starting?(session_id, state_dir:)
        return false if Session.stopped_marker?(session_id, state_dir: state_dir)

        at, waiter = @spawns_mutex.synchronize { @spawns[[state_dir, session_id]] }
        return false unless at && waiter.respond_to?(:alive?) && waiter.alive?

        Process.clock_gettime(Process::CLOCK_MONOTONIC) - at < WORKER_START_GRACE
      end

      private def note_spawn(session_id, state_dir:, waiter:)
        @spawns_mutex.synchronize do
          @spawns.delete_if { |_, (_, w)| !(w.respond_to?(:alive?) && w.alive?) }
          @spawns[[state_dir, session_id]] = [Process.clock_gettime(Process::CLOCK_MONOTONIC), waiter]
        end
      end

      # Forget the spawns #still_starting? remembers (specs).
      def forget_spawns
        @spawns_mutex.synchronize { @spawns.clear }
      end

      # Starter processes are children of chi web, unlike the detached workers
      # they launch; the web restart adopts these pids before replacing itself.
      def live_spawn_pids
        @spawns_mutex.synchronize do
          @spawns.delete_if { |_, (_, waiter)| !(waiter.respond_to?(:alive?) && waiter.alive?) }
          @spawns.values.filter_map do |_, waiter|
            waiter.pid if waiter.respond_to?(:pid) && waiter.alive?
          end.uniq.sort
        end
      end

      private def setup_session_directory(session_dir, session, state_dir:)
        FileUtils.mkdir_p(session_dir)
        FileUtils.mkdir_p(File.join(session_dir, SessionInbox::INPUT_DIR))
        FileUtils.mkdir_p(File.join(session_dir, SessionInbox::OUTPUT_DIR))
        session.save(state_dir: state_dir)
      end

      private def spawn_worker_for_session(session, state_dir:)
        session_dir = Session.session_dir(session.id, state_dir: state_dir)
        FileUtils.mkdir_p(session_dir)
        FileUtils.mkdir_p(File.join(session_dir, SessionInbox::INPUT_DIR))
        FileUtils.mkdir_p(File.join(session_dir, SessionInbox::OUTPUT_DIR))

        opts = spawn_options(session)
        env = opts.delete(:env)
        command = worker_command(session.id, state_dir: state_dir)
        pid = env ? Process.spawn(env, *command, **opts) : Process.spawn(*command, **opts)
        # Reaped when it exits: a long-lived spawner (chi web) keeps no zombies.
        # +pid+ is the worker's starter, which exits once the worker it forked
        # holds the lock (detach_from_spawner): the lock's pid is the worker's.
        note_spawn(session.id, state_dir: state_dir, waiter: Process.detach(pid))
        Log.info(:worker, "spawn", sid: session.id, child_pid: pid)
        pid
      end
    end

    extend SpawnPart
  end
end
