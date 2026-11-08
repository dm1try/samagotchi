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
        owners = tree.to_h { |sid| [sid, session_owner(sid, state_dir: state_dir)] }
        tree.each do |sid|
          refusal = archive_refusal(sid, owners[sid], state_dir)
          raise ArchiveRefused.new(id, sid == id ? refusal : :"#{refusal}_child", busy_id: sid) if refusal
        end
        [tree, owners]
      end

      # What keeps +sid+ (in an archive's tree) from being archived: :busy (a
      # turn runs), :queued (input/ holds a prompt, which outlives the stop and
      # runs on a resume, live worker or not), :offer (a live worker's continue
      # offer, which the stop would drop), or nil.
      # @raise [OwnedByTUI] a one-turn chi run owns it
      private def archive_refusal(sid, owner, state_dir)
        raise OwnedByTUI, sid if owner&.tui?

        session = owner && Session.load(sid, state_dir: state_dir)
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
      # @raise [DeleteRefused] a worker owns it and +stop+ is false, or it
      #   outlived the wait
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

        owner = refuse_tui!(id, state_dir: sd)
        if owner
          raise DeleteRefused.new(id, :worker_running) unless stop
          raise DeleteRefused.new(id, :still_stopping) unless stop_session(id, state_dir: sd, wait: wait)
        end

        removed = []
        if File.exist?(path)
          FileUtils.rm_f(path)
          removed << path
        end
        if Dir.exist?(dir)
          FileUtils.rm_rf(dir)
          removed << dir
        end
        PluginSessionState.remove(id)
        removed.concat(ContextSources.remove_session(id, state_dir: sd))
        Participants.end_sessions([id], by: "delete", state_dir: sd)
        if purge_runs
          purge_session_runs(id, sd)
          ContextCandidatesLog.purge_session(id, state_dir: sd)
        end
        { id: id, removed: removed, stopped: !owner.nil? }
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
