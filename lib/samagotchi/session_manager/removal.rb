# frozen_string_literal: true

module Samagotchi
  class SessionManager
    # A delete that would pull the session from under its live worker.
    # reason: :worker_running (not asked to stop it) or :still_stopping
    # (stopped, but the worker outlived the wait).
    class DeleteRefused < StandardError
      attr_reader :session_id, :reason

      def initialize(session_id, reason)
        @session_id = session_id
        @reason = reason
        super(reason == :still_stopping ? "session #{session_id}'s worker is still shutting down" : "session #{session_id}'s worker is running")
      end
    end

    # An archive that can't happen now: a turn runs in the session or in one
    # of its children (+busy_id+ names which), or it is a scratch session.
    class ArchiveRefused < StandardError
      attr_reader :session_id, :reason, :busy_id

      def initialize(session_id, reason, busy_id: nil)
        @session_id = session_id
        @reason = reason
        @busy_id = busy_id
        super(archive_refused_message)
      end

      private

      def archive_refused_message
        case @reason
        when :scratch then "a scratch session is deleted when you leave; nothing to archive"
        when :busy_child then "its delegate #{@busy_id[0, 8]} is running a turn; wait for it or stop it first"
        when :queued then "a prompt is queued, which a resume would run; let it run first"
        when :queued_child then "its delegate #{@busy_id[0, 8]} has a prompt queued, which a resume would run; let it run first"
        when :offer then "the step-limit question waits for an answer; answer Continue or Stop first"
        when :offer_child then "its delegate #{@busy_id[0, 8]} waits for an answer to its step-limit question; answer it first"
        when :starting then "its worker is starting; try again in a moment"
        when :starting_child then "its delegate #{@busy_id[0, 8]}'s worker is starting; try again in a moment"
        else "a turn is running; wait for it or cancel it first"
        end
      end
    end

    # What one archive did: id: the session it was asked for; archived: the
    # ids (it and its delegates) now hidden for good; stopped: the live
    # workers stopped first; discarded: empty sessions its stopping worker deleted.
    ArchiveResult = Data.define(:id, :archived, :stopped, :discarded)

    # Removal: archive, unarchive and delete a session (an archive takes its
    # delegates too), and the retention sweep's entry. Calls LifecyclePart's
    # stop_session, ListingPart's descendant_ids and the facade's ownership
    # checks. Meant to be loaded through samagotchi/session_manager.
    module RemovalPart
      # Archive a session and its delegated children (ArchiveStore): hidden
      # from every list, kept by the retention sweep. A live idle worker is
      # stopped first; the marker is written even while it shuts down.
      # @return [ArchiveResult]
      # @raise [ArgumentError] unknown id (Session::AmbiguousId for a prefix of several)
      # @raise [OwnedByTUI] a one-turn chi run owns it or one of its children
      # @raise [ArchiveRefused] a turn runs in it or in a child, a prompt is
      #   queued in one (a later resume would run it), a live one offers to
      #   continue past the step limit, or it is a scratch session
      # @param except [Array<String>] descendants left alone with their own
      #   subtrees (delegates a continue moves to the chain's new link)
      def archive_session(id_or_prefix, state_dir: nil, wait: 5, except: [])
        sd = state_dir || Session.default_state_dir
        id = archive_target(id_or_prefix, sd)
        tree, owners = archivable!(id, sd, except: except)
        stopped = tree.select { |sid| owners[sid] }
        stopped.each { |sid| stop_session(sid, state_dir: sd, wait: wait) }
        archived, discarded = tree.partition { |sid| ArchiveStore.archive(sid, state_dir: sd) }
        # A restart's reminders hand-off no successor took (the stop above
        # removes a live one's): archived sessions keep no reminders.
        archived.each { |sid| ReminderCarry.remove(Session.session_dir(sid, state_dir: sd)) }
        # D8: an archive ends the review (unarchiving doesn't restore it).
        Participants.end_sessions(archived, by: "archive", state_dir: sd)
        ArchiveResult.new(id: id, archived: archived, stopped: stopped, discarded: discarded)
      end

      # The session and its descendants, with their owners, when they can be
      # archived now (#archive_refusal for each), else the refusal. Public for
      # SessionContinue, which checks before its recap wait.
      # @return [Array(Array<String>, Hash)] the ids, and id => OwnerLock::Owner or nil
      # @raise [ArchiveRefused, OwnedByTUI]
      def archivable!(id, state_dir, except: [])
        raise ArchiveRefused.new(id, :scratch) if Session.load(id, state_dir: state_dir).scratch

        tree = [id, *descendant_ids(id, state_dir, except: except)]
        presences = tree.to_h do |sid|
          [sid, WorkerPresence.read(sid, state_dir: state_dir, owner: session_owner(sid, state_dir: state_dir))]
        end
        tree.each do |sid|
          refusal = archive_refusal(sid, presences[sid], state_dir)
          raise ArchiveRefused.new(id, sid == id ? refusal : :"#{refusal}_child", busy_id: sid) if refusal
        end
        [tree, presences.transform_values(&:owner)]
      end

      # What keeps +sid+ (in an archive's tree) from being archived:
      # :starting (a worker is being started for it, holding no lock yet: a
      # continue's new link, a resume), :busy (a
      # turn runs), :queued (input/ holds a prompt, which outlives the stop and
      # runs on a resume, live worker or not), :offer (a live worker's continue
      # offer, which the stop would drop), or nil.
      # The status is read only while someone owns it (+presence+'s owner).
      # @raise [OwnedByTUI] a one-turn chi run owns it
      private def archive_refusal(sid, presence, state_dir)
        raise OwnedByTUI, sid if presence.tui_owned?
        return :starting if presence.starting? && !presence.owned?

        session = presence.owned? ? Session.load(sid, state_dir: state_dir) : nil
        return :busy if session&.status == Session::STATUS_RUNNING
        return :queued unless SessionInbox.find_new_input_files(Session.session_dir(sid, state_dir: state_dir)).empty?

        :offer if session&.waiting_question(live: true)&.dig(:kind) == ContinueOffer::KIND
      end

      # Unarchive a session and its delegated children.
      # @return [Hash] {id:, unarchived: [ids that were archived]}
      # @raise [ArgumentError] unknown id
      def unarchive_session(id_or_prefix, state_dir: nil)
        sd = state_dir || Session.default_state_dir
        id = archive_target(id_or_prefix, sd)
        unarchived = [id, *descendant_ids(id, sd)].select { |sid| ArchiveStore.unarchive(sid, state_dir: sd) }
        { id: id, unarchived: unarchived }
      end

      private def archive_target(id_or_prefix, state_dir) = Session.resolve!(id_or_prefix.to_s, state_dir: state_dir)

      # The retention sweep (SessionRetention.sweep_if_due), here for the web
      # app and hub, which take this class as their manager.
      def retention_sweep_if_due(state_dir: nil) = SessionRetention.sweep_if_due(state_dir: state_dir)

      # Delete one session: its <id>.json, the whole <id>/ directory
      # (history sidecars, input, output, notes, images) and its attached
      # context (ContextSources: its sources, subscriptions, mute markers). The CLI, the TUI's
      # /exit --delete and the web all come here.
      # @param id_or_prefix [String] a session id or a unique prefix of one
      # @param stop [Boolean] stop a live worker first (waits +wait+ seconds)
      # @return [Hash] {id:, removed: [paths], stopped: whether a worker was stopped}
      # @raise [ArgumentError] unknown id (Session::AmbiguousId for a prefix of several)
      # @raise [OwnedByTUI] a one-turn chi run owns it (never stopped from here)
      # @raise [DeleteRefused] a worker owns it or is being started for it
      #   (the starting marker) and +stop+ is false, or it outlived the wait
      # @param purge_runs [Boolean] also delete System 1's saved runs of it and
      #   its candidate-log lines; a session a worker left empty has none worth
      #   the read
      def delete_session(id_or_prefix, state_dir: nil, stop: false, wait: STOP_WAIT, purge_runs: true)
        sd = state_dir || Session.default_state_dir
        given = id_or_prefix.to_s
        # Only a plain id: anything else could name a path outside the state dir.
        raise Session::NotFound, given unless Session.valid_id?(given)

        id = Session.resolve_id(given, state_dir: sd)
        path = Session.session_file(id, state_dir: sd)
        dir = Session.session_dir(id, state_dir: sd)
        # A folder with no file left is still deleted (not resolve!).
        raise Session::NotFound, given unless File.exist?(path) || Dir.exist?(dir)

        presence = WorkerPresence.read(id, state_dir: sd, owner: session_owner(id, state_dir: sd))
        raise OwnedByTUI, id if presence.tui_owned?

        held = presence.owned? || presence.starting?
        if held
          raise DeleteRefused.new(id, :worker_running) unless stop
          raise DeleteRefused.new(id, :still_stopping) unless stop_held(id, state_dir: sd, wait: wait)
        end

        removed = remove_session_files(id, path, dir, state_dir: sd)
        PluginSessionState.remove(id)
        removed.concat(ContextSources.remove_session(id, state_dir: sd))
        Participants.end_sessions([id], by: "delete", state_dir: sd)
        if purge_runs
          purge_session_runs(id, sd)
          ContextCandidatesLog.purge_session(id, state_dir: sd)
        end
        { id: id, removed: removed, stopped: held }
      end

      # The session's file and directory, removed while this process holds
      # its owner lock (kind deleting, which a stop never signals), so no
      # worker takes the session in the middle; the starting marker is read
      # again under it (a resume that claimed the start since the caller's
      # check keeps the session; one after it sees the lock held). Taken
      # without waiting: one that took it since the check keeps the session.
      # The lock file goes with the directory; a worker starting after that
      # makes a new one, and finds no session (Session.load). The delete and
      # the retention sweep remove through here.
      # @return [Array<String>] the paths removed
      # @raise [DeleteRefused] a worker took the lock, or a start was
      #   claimed, after the caller's check
      def remove_session_files(id, path, dir, state_dir:)
        lock = Dir.exist?(dir) ? OwnerLock.acquire(dir, kind: OwnerLock::DELETING, wait: 0) : nil
        raise DeleteRefused.new(id, :worker_running) if Dir.exist?(dir) && lock.nil?
        raise DeleteRefused.new(id, :worker_running) if StartingMarker.fresh?(id, state_dir: state_dir)

        removed = []
        if File.exist?(path)
          FileUtils.rm_f(path)
          removed << path
        end
        if Dir.exist?(dir)
          FileUtils.rm_rf(dir)
          removed << dir
        end
        removed
      ensure
        lock&.release
      end

      # Stop the worker that owns +id+ or is being started for it (the stop
      # marker: one that takes the lock leaves at once), and wait for both to
      # be gone.
      # @return [Boolean] whether no owner and no start was left within +wait+
      private def stop_held(id, state_dir:, wait:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait.to_f
        return false unless stop_session(id, state_dir: state_dir, wait: wait)

        while StartingMarker.fresh?(id, state_dir: state_dir) || session_owner(id, state_dir: state_dir)
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep(OwnerLock::RETRY_INTERVAL)
        end
        true
      end

      # Never a reason a delete fails: one warn, and the sweep ages them out.
      private def purge_session_runs(id, state_dir)
        SystemOne::Runs.purge_session(id, sessions_dir: state_dir)
      rescue StandardError => e
        Log.warn(:worker, "session_runs_purge_failed", sid: id, error: e.class.name, msg: e.message.to_s[0, 200])
      end
    end

    extend RemovalPart
  end
end
