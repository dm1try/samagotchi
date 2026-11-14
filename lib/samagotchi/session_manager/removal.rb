# frozen_string_literal: true

require_relative "../session_stores"

module Samagotchi
  class SessionManager
    # A delete that can't happen now, one message per reason:
    # :worker_running (not asked to stop it), :still_stopping (stopped, but
    # the worker outlived the wait), :changed (the caller's +still:+ check,
    # read again under the owner lock, no longer holds), :scheduled (an
    # enabled schedule's target, anchor or head: +schedule_id+),
    # :continuing (a continue of +session_id+ is in flight: this link, or
    # the previous one a delete would bring back), :delegate_unmovable (a
    # delegate the deleted link's continue moved can't go back: +ids+,
    # +detail+ says why), :chain_scheduled (a schedule is on the chain a
    # chain delete would take: +schedule_id+).
    class DeleteRefused < StandardError
      attr_reader :session_id, :reason, :schedule_id, :ids

      def initialize(session_id, reason, message: nil, schedule_id: nil, ids: [], detail: nil)
        @session_id = session_id
        @reason = reason
        @schedule_id = schedule_id
        @ids = ids
        super(message || refused_message(detail))
      end

      private

      def refused_message(detail)
        short = @session_id.to_s[0, 8]
        cancel = "; cancel it with chi schedule cancel #{@schedule_id}" if @schedule_id
        case @reason
        when :worker_running then "session #{@session_id}'s worker is running"
        when :still_stopping then "session #{@session_id}'s worker is still shutting down"
        when :changed then "session #{@session_id} changed since it was checked"
        when :scheduled then "this session is the target of an enabled schedule#{cancel}"
        when :continuing then "a continue of #{short} is under way; try again in a moment"
        when :delegate_unmovable
          "#{@ids.map { |id| id[0, 8] }.join(", ")}, moved here by the continue, can't go back to the previous link" \
            "#{": #{detail}" if detail}"
        when :chain_scheduled then "an enabled schedule runs on this chain#{cancel}"
        else "session #{@session_id} can't be deleted now (#{@reason})"
        end
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

    # Every store with session-scoped state. Deletion, retention and failed
    # continuation cleanup all pass through this registry.
    SESSION_STATE_STORES = SessionStores.removal_stores

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
      # @param allow_scheduled [Boolean] internal rollback of a failed continue
      # @param revive_previous [Boolean] a user's delete (CLI, web, TUI) of a
      #   chain's newest link brings the previous one back to the lists and
      #   undoes the continue (SessionChain::Delete.link, D2/D5); any chained
      #   link's own delegates follow SessionChain::Delete::DELEGATES. The
      #   result then also has unarchived:, moved_back:, deleted: and
      #   left_running: (ids)
      # @param refuse_continuing [Boolean] a user's delete refuses
      #   (:continuing) while a continue of the session is in flight
      # @raise [DeleteRefused] also :scheduled for a schedule's anchor or
      #   head, and with the keywords :continuing and :delegate_unmovable
      def delete_session(id_or_prefix, state_dir: nil, stop: false, wait: STOP_WAIT, purge_runs: true,
                         allow_scheduled: false, revive_previous: false, refuse_continuing: false)
        sd = state_dir || Session.default_state_dir
        given = id_or_prefix.to_s
        # Only a plain id: anything else could name a path outside the state dir.
        raise Session::NotFound, given unless Session.valid_id?(given)

        id = Session.resolve_id(given, state_dir: sd)
        path = Session.session_file(id, state_dir: sd)
        dir = Session.session_dir(id, state_dir: sd)
        # A folder with no file left is still deleted (not resolve!).
        raise Session::NotFound, given unless File.exist?(path) || Dir.exist?(dir)

        if revive_previous || refuse_continuing
          require_relative "../session_chain/delete"
          return SessionChain::Delete.link(id, state_dir: sd, stop: stop, wait: wait, revive_previous: revive_previous,
                                               refuse_continuing: refuse_continuing)
        end

        delete_resolved(id, state_dir: sd, stop: stop, wait: wait, purge_runs: purge_runs, allow_scheduled: allow_scheduled)
      end

      # Delete every link of +id+'s chain with their delegates
      # (SessionChain::Delete.chain, D4/D7): all or nothing for the
      # refusals, newest link first.
      # @param stop [Boolean] stop the links' live workers first (the web
      #   always does; the CLI's --force)
      # @return [Hash] SessionChain::Delete.chain's
      # @raise [ArgumentError] unknown id (Session::AmbiguousId for a prefix of several)
      # @raise [DeleteRefused, OwnedByTUI] nothing was deleted
      def delete_chain(id_or_prefix, state_dir: nil, stop: false, wait: STOP_WAIT)
        sd = state_dir || Session.default_state_dir
        given = id_or_prefix.to_s
        raise Session::NotFound, given unless Session.valid_id?(given)

        id = Session.resolve_id(given, state_dir: sd)
        raise Session::NotFound, given unless Session.exist?(id, state_dir: sd)

        require_relative "../session_chain/delete"
        SessionChain::Delete.chain(id, state_dir: sd, stop: stop, wait: wait)
      end

      # #delete_session's checks and removal for a full id that exists:
      # the schedule refusal, the one-turn run, the worker (stopped with
      # +stop+), then #remove_files. SessionChain::Delete's last step.
      # @return [Hash] {id:, removed:, stopped:}
      def delete_resolved(id, state_dir:, stop: false, wait: STOP_WAIT, purge_runs: true, allow_scheduled: false)
        sd = state_dir
        path = Session.session_file(id, state_dir: sd)
        dir = Session.session_dir(id, state_dir: sd)
        refuse_scheduled!(id, sd) unless allow_scheduled

        held = release_for_delete!(id, state_dir: sd, stop: stop, wait: wait)
        removed = remove_files(id, path, dir, state_dir: sd, purge_runs: purge_runs)
        { id: id, removed: removed, stopped: held }
      end

      # +id+ free for a delete: a one-turn run refuses, a worker that owns it
      # or is being started for it is stopped with +stop+ (else refused).
      # @return [Boolean] whether there was one to stop
      # @raise [OwnedByTUI, DeleteRefused] :worker_running, :still_stopping
      def release_for_delete!(id, state_dir:, stop:, wait:)
        presence = WorkerPresence.read(id, state_dir: state_dir, owner: session_owner(id, state_dir: state_dir))
        raise OwnedByTUI, id if presence.tui_owned?

        held = presence.owned? || presence.starting?
        if held
          raise DeleteRefused.new(id, :worker_running) unless stop
          raise DeleteRefused.new(id, :still_stopping) unless stop_held(id, state_dir: state_dir, wait: wait)
        end
        held
      end

      # Delete these ids safely, in this order: #delete_session for each (it
      # re-checks the one-turn run, the starting marker and the owner lock),
      # and the expensive session-scoped logs (#purge_removal_stores) once
      # for the batch, for the ids deleted even when a later one is refused.
      # No eligibility policy: each caller (Schedules#prune, the chain
      # delete) decides which ids, and keeps its own checks and log tags.
      # @param ids [Array<String>] full ids, in the order to delete them
      # @return [Array<Hash>] #delete_session's result for each
      # @raise [DeleteRefused, OwnedByTUI, Session::NotFound] the first
      #   refusal; the ids before it are deleted
      def delete_ids(ids, state_dir: nil, stop: false, wait: STOP_WAIT)
        sd = state_dir || Session.default_state_dir
        results = []
        # Not a map: the ids deleted before a refusal must reach the ensure's purge.
        ids.each do |id| # rubocop:disable Style/MapIntoArray
          results << delete_session(id, state_dir: sd, stop: stop, wait: wait, purge_runs: false)
        end
        results
      ensure
        purge_removal_stores(results.map { |result| result[:id] }, state_dir: sd) if results
      end

      # +id+'s delegate subtree and +id+, in the order a delete takes them:
      # the descendants deepest first, +id+ last. A delete refused part-way
      # leaves nothing above what it took, so a retry finds the same tree.
      # @return [Array<String>]
      def delete_tree_ids(id, state_dir) = [*descendant_ids(id, state_dir).reverse, id]

      # DeleteRefused :scheduled when an enabled schedule's target, anchor
      # or head is +id+: deleting a head would make the schedule fall back to
      # an archived link and lose the links after it.
      def refuse_scheduled!(id, state_dir)
        require_relative "../schedules"
        schedule = Schedules.new(state_dir: state_dir).protecting_link(id)
        raise DeleteRefused.new(id, :scheduled, schedule_id: schedule.id) if schedule
      end

      # Remove every store with state scoped to +id+. The file and sidecar
      # directory keep the deleting owner lock; the other stores have their
      # own locking where they need it. +still+, when given, is the caller's
      # own check, read again under that lock (the session files go first, so
      # a refusal leaves every store as it was).
      # @return [Array<String>] the session file, sidecar and context paths removed
      # @raise [DeleteRefused] see #remove_session_files
      # @param locked [Boolean] the caller holds +id+'s owner lock (kind
      #   deleting) already: SessionChain::Delete, across its undo
      def remove_files(id, path, dir, state_dir:, purge_runs: true, still: nil, locked: false)
        removed = []
        SESSION_STATE_STORES.each do |store|
          case store
          when :session_files
            removed.concat(remove_session_files(id, path, dir, state_dir: state_dir, still: still, locked: locked))
          when :plugin_session_state
            PluginSessionState.remove(id)
          when :context_sources
            removed.concat(ContextSources.remove_session(id, state_dir: state_dir))
          when :participants
            Participants.end_sessions([id], by: "delete", state_dir: state_dir)
          when :system_one_runs
            next
          when :context_candidates_log
            next
          else
            raise ArgumentError, "no cleanup for session store #{store.inspect}"
          end
        end
        purge_removal_stores([id], state_dir: state_dir) if purge_runs
        removed
      end

      # The session-scoped logs are expensive to scan; callers removing a
      # batch purge them once after the session files are gone.
      def purge_removal_stores(ids, state_dir:)
        return if ids.empty?

        purge_session_runs(ids, state_dir)
        ContextCandidatesLog.purge_sessions(ids, state_dir: state_dir)
      end

      # The session's file and directory, removed while this process holds
      # its owner lock (kind deleting, which a stop never signals), so no
      # worker takes the session in the middle; the starting marker is read
      # again under it (a resume that claimed the start since the caller's
      # check keeps the session; one after it sees the lock held). Taken
      # without waiting: one that took it since the check keeps the session.
      # The lock file goes with the directory; a worker starting after that
      # makes a new one, and finds no session (Session.load). The delete and
      # the retention sweep and failed-continue cleanup use #remove_files.
      # @return [Array<String>] the paths removed
      # @raise [DeleteRefused] a worker took the lock, or a start was
      #   claimed, after the caller's check, or +still+ no longer holds
      def remove_session_files(id, path, dir, state_dir:, still: nil, locked: false)
        lock = !locked && Dir.exist?(dir) ? OwnerLock.acquire(dir, kind: OwnerLock::DELETING, wait: 0) : nil
        raise DeleteRefused.new(id, :worker_running) if !locked && Dir.exist?(dir) && lock.nil?
        raise DeleteRefused.new(id, :worker_running) if StartingMarker.fresh?(id, state_dir: state_dir)
        raise DeleteRefused.new(id, :changed) if still && !still.call

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
      private def purge_session_runs(ids, state_dir)
        SystemOne::Runs.purge_sessions(ids, sessions_dir: state_dir)
      rescue StandardError => e
        Log.warn(:worker, "session_runs_purge_failed", sid: ids.first, error: e.class.name, msg: e.message.to_s[0, 200])
      end
    end

    extend RemovalPart
  end
end
