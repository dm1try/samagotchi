# frozen_string_literal: true

require "json"
require_relative "links"
require_relative "../archive_store"
require_relative "../child_move"
require_relative "../continue_intent"
require_relative "../continued_from"
require_relative "../owner_lock"
require_relative "../session"
require_relative "../starting_marker"
require_relative "../worker_presence"

module Samagotchi
  # Loaded on first use: session_manager loads this file from its delete
  # (a require cycle otherwise), and session_continue requires session_manager.
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)
  autoload :SessionContinue, File.expand_path("../session_continue", __dir__)
  autoload :Schedules, File.expand_path("../schedules", __dir__)

  module SessionChain
    # A user's delete of a link of a session chain (the CLI, the web, the
    # TUI's /exit --delete: SessionManager.delete_session's revive_previous:
    # and refuse_continuing:), and of the whole chain (.chain:
    # SessionManager.delete_chain). A session in no chain is deleted as
    # before (SessionManager.delete_resolved). The scratch cleanup, the
    # empty-session discard, the failed-continue rollback and the prune
    # never come here.
    #
    # - The chain's newest link (not archived itself, its previous link
    #   archived, nobody continuing it) is undone (D2/D5): the delegates its
    #   continue moved go back to the previous link, with the notes waiting
    #   in it, and the previous link and what the continue archived with it
    #   come back to the lists (ContinuedFrom's record; without one, the
    #   previous link alone). The previous link is not started.
    # - Any other link (a middle one splits the chain) is deleted alone.
    # - Either way the link's own delegates follow DELEGATES (D7).
    module Delete
      # What DELEGATES does with a link's delegates: +delete+ (deepest
      # first, before the link) and +leave+ (running, with their whole
      # subtrees: they go on without a parent, their files untouched).
      Plan = Data.define(:delete, :leave)

      # D7, hard-coded for the chain deletes for now (one place, so that a
      # policy for every delete can move it into SessionManager later): a
      # delegate is running when a worker owns it or is being started for
      # it (a one-turn chi run too, which can't be stopped from here). A
      # saved status running with no worker is a crashed run: it goes. A running one is left with its whole subtree;
      # every other node under the link (no running node between it and the
      # link) is deleted.
      class DelegateRule
        # @param except [Array<String>] the link's children left out with
        #   their subtrees (the ones the undo gives back)
        # @return [Plan]
        def plan(link, state_dir:, except: [])
          delete = []
          leave = []
          queue = [link]
          until queue.empty?
            SessionManager.children_of(queue.shift, state_dir: state_dir).each do |row|
              next if row.id == link || except.include?(row.id) || delete.include?(row.id) || leave.include?(row.id)

              if running?(row, state_dir)
                leave.concat([row.id, *SessionManager.descendant_ids(row.id, state_dir)] - leave)
              else
                delete << row.id
                queue << row.id
              end
            end
          end
          Plan.new(delete: delete.reverse, leave: leave)
        end

        private

        def running?(row, state_dir)
          presence = WorkerPresence.read(row.id, state_dir: state_dir,
                                                 owner: SessionManager.session_owner(row.id, state_dir: state_dir))
          presence.owned? || presence.starting?
        end
      end

      DELEGATES = DelegateRule.new.freeze

      module_function

      # Delete the link +id+ (a full id that exists), inside a shared hold
      # of its continue lock (and the previous link's when it would come
      # back), so no continue of either starts meanwhile.
      # @return [Hash] {id:, removed:, stopped:, unarchived:, moved_back:,
      #   deleted: (its delegates deleted and it), left_running:}
      # @raise [SessionManager::DeleteRefused] :continuing, :scheduled,
      #   :delegate_unmovable, :worker_running, :still_stopping
      # @raise [SessionManager::OwnedByTUI]
      def link(id, state_dir:, stop:, wait:, revive_previous:, refuse_continuing:)
        ContinueIntent.hold(id, state_dir: state_dir) do |held|
          raise SessionManager::DeleteRefused.new(id, :continuing) if refuse_continuing && !held

          links = Links.new(state_dir: state_dir)
          previous = links.continues(id)
          return plain(SessionManager.delete_resolved(id, state_dir: state_dir, stop: stop, wait: wait)) unless previous || links.next_of(id)

          unless revive_previous && previous && revivable?(id, previous, links)
            return delete_link(id, previous: nil, state_dir: state_dir, stop: stop, wait: wait)
          end

          # Taken before the link's file goes: after it, a continue of the
          # previous link would no longer be refused.
          ContinueIntent.hold(previous, state_dir: state_dir) do |previous_held|
            raise SessionManager::DeleteRefused.new(previous, :continuing) unless previous_held

            again = revivable?(id, previous, Links.new(state_dir: state_dir))
            return delete_link(id, previous: again ? previous : nil, state_dir: state_dir, stop: stop, wait: wait)
          end
        end
      end

      # D2's conditions: +id+ is the chain's end and not archived itself,
      # and the link before it is there and archived.
      def revivable?(id, previous, links)
        !links.gone?(previous) && links.next_of(id).nil? && !links.archived?(id) && links.archived?(previous)
      end

      def plain(result) = result.merge(unarchived: [], moved_back: [], deleted: [result[:id]], left_running: [])

      # Every refusal first, then the link's worker stopped, then the owner
      # lock (kind deleting, no wait) on the link and every D7 delegate that
      # goes, and only under those locks the delegates' files, then either the
      # undo (+previous+ given: D5) or the link's files. So a refusal (a
      # schedule on a delegate, a one-turn run, a worker that took the link
      # or a delegate after the checks) leaves every session in place.
      def delete_link(id, previous:, state_dir:, stop:, wait:)
        SessionManager.refuse_scheduled!(id, state_dir)
        moved = previous ? moved_ids(id, previous, state_dir) : []
        refuse_unmovable!(id, moved, state_dir)
        plan = DELEGATES.plan(id, state_dir: state_dir, except: moved)
        precheck!(plan.delete, state_dir)
        stopped = SessionManager.release_for_delete!(id, state_dir: state_dir, stop: stop, wait: wait)
        path = Session.session_file(id, state_dir: state_dir)
        dir = Session.session_dir(id, state_dir: state_dir)
        revive = previous ? revive_ids(id, previous, state_dir) : []
        removed = locked([*plan.delete, id], state_dir) do
          remove_locked(plan.delete, state_dir)
          if previous
            SessionContinue.undo_deleted_link(from: previous, link: id, moved: moved, state_dir: state_dir) do
              SessionManager.remove_files(id, path, dir, state_dir: state_dir, purge_runs: false, locked: true)
            end
          else
            SessionManager.remove_files(id, path, dir, state_dir: state_dir, purge_runs: false, locked: true)
          end
        end
        SessionManager.purge_removal_stores([*plan.delete, id], state_dir: state_dir)
        unarchived = revive.select { |sid| ArchiveStore.unarchive(sid, state_dir: state_dir) }
        { id: id, removed: removed, stopped: stopped, unarchived: unarchived, moved_back: moved,
          deleted: [*plan.delete, id], left_running: plan.leave }
      end

      # The refusals of every id a batch would delete, before the first
      # goes: a schedule's target, anchor or head (the refusal names that
      # delegate), a one-turn run.
      # @raise [SessionManager::DeleteRefused, SessionManager::OwnedByTUI]
      def precheck!(ids, state_dir)
        ids.each do |sid|
          SessionManager.refuse_scheduled!(sid, state_dir)
          raise SessionManager::OwnedByTUI, sid if SessionManager.session_owner(sid, state_dir: state_dir)&.tui?
        end
      end

      # The block under the owner lock (kind deleting, taken without
      # waiting) of every id with a folder, the starting marker read again
      # under each, held until the block returns: a worker that holds one,
      # or a start claimed meanwhile, refuses before anything goes, and
      # none takes one midway.
      # @raise [SessionManager::DeleteRefused] :worker_running
      def locked(ids, state_dir)
        locks = []
        ids.each do |sid|
          dir = Session.session_dir(sid, state_dir: state_dir)
          next unless Dir.exist?(dir)

          lock = OwnerLock.acquire(dir, kind: OwnerLock::DELETING, wait: 0)
          raise SessionManager::DeleteRefused.new(sid, :worker_running) unless lock

          locks << lock
          raise SessionManager::DeleteRefused.new(sid, :worker_running) if StartingMarker.fresh?(sid, state_dir: state_dir)
        end
        yield
      ensure
        locks.each(&:release)
      end

      # +ids+' files, in order, each locked by the caller (#locked); the
      # session logs are the caller's to purge, once.
      # @return [Array<String>] the paths removed
      def remove_locked(ids, state_dir)
        ids.flat_map do |sid|
          SessionManager.remove_files(sid, Session.session_file(sid, state_dir: state_dir), Session.session_dir(sid, state_dir: state_dir),
                                      state_dir: state_dir, purge_runs: false, locked: true)
        end
      end

      # The delegates the continue +previous+ → +id+ moved that are still
      # +id+'s: by ContinuedFrom's record (a nested undo needs it: an earlier
      # one rewrote parent.json's from), else +id+'s children whose
      # parent.json says they came from +previous+.
      # @return [Array<String>]
      def moved_ids(id, previous, state_dir)
        children = SessionManager.children_of(id, state_dir: state_dir).map(&:id)
        record = ContinuedFrom.read(id, state_dir: state_dir)
        return record.moved_ids & children if record&.previous_id == previous

        children.select { |child| moved_from(child, state_dir) == previous }
      end

      # What comes back to the lists: what the continue archived, else the
      # previous link alone (its archived delegates stay archived).
      def revive_ids(id, previous, state_dir)
        record = ContinuedFrom.read(id, state_dir: state_dir)
        record&.previous_id == previous ? (record.archived_ids | [previous]) : [previous]
      end

      # parent.json's +from+, nil without one.
      def moved_from(child, state_dir)
        data = JSON.parse(File.read(File.join(Session.session_dir(child, state_dir: state_dir), Session::PARENT_FILE)))
        data.is_a?(Hash) ? data["from"] : nil
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def refuse_unmovable!(id, moved, state_dir)
        stuck = moved.filter_map { |child| (why = ChildMove.unmovable(child, state_dir: state_dir)) && [child, why] }
        return if stuck.empty?

        raise SessionManager::DeleteRefused.new(id, :delegate_unmovable, ids: stuck.map(&:first),
                                                                         detail: stuck.map { |c, why| "#{c[0, 8]} #{why}" }.join("; "))
      end

      # Delete every link connected to +id+ on its branch (past a gap, only
      # the part after it is reached), newest first, each with its D7
      # delegates. Refused before anything goes when a schedule is on the
      # chain or on a delegate that would go, a link or such a delegate is in
      # a one-turn chi run, a continue of a link is under way, a link has a
      # worker (without +stop+), or a stopped link's worker outlives the
      # wait: every link is checked and stopped before the first is
      # deleted. Each link then goes under the owner locks of it and its
      # delegates (#locked); a link refused there (a worker took it after
      # the stop) leaves it and the earlier links whole, its new end back in
      # the lists as D2 says (no undo).
      # @return [Hash] {id:, deleted:, left:, left_running:, unarchived:,
      #   stopped:, cut_off:, refusal:} (cut_off: a deleted link cuts off
      #   earlier ones; refusal: the message of a part-way refusal, or nil)
      # @raise [SessionManager::DeleteRefused, SessionManager::OwnedByTUI]
      #   nothing was deleted
      def chain(id, state_dir:, stop:, wait:)
        links = Links.new(state_dir: state_dir)
        ids = links.live_links(id)
        cut_off = links.gone?(links.chain(id).first)
        plans = ids.to_h { |link| [link, DELEGATES.plan(link, state_dir: state_dir)] }
        refuse_chain!(id, ids, state_dir, stop: stop)
        precheck!(plans.values.flat_map(&:delete), state_dir)
        hold_all(ids, state_dir) do
          stopped = ids.select { |link| SessionManager.release_for_delete!(link, state_dir: state_dir, stop: stop, wait: wait) }
          delete_links(id, ids.reverse, plans, links, state_dir).merge(stopped: stopped, cut_off: cut_off)
        end
      end

      def refuse_chain!(id, ids, state_dir, stop:)
        schedule = Schedules.new(state_dir: state_dir).for_chain(id).first
        raise SessionManager::DeleteRefused.new(id, :chain_scheduled, schedule_id: schedule.id) if schedule

        ids.each do |link|
          presence = WorkerPresence.read(link, state_dir: state_dir, owner: SessionManager.session_owner(link, state_dir: state_dir))
          raise SessionManager::OwnedByTUI, link if presence.tui_owned?
          raise SessionManager::DeleteRefused.new(link, :worker_running) if !stop && (presence.owned? || presence.starting?)
        end
      end

      # The block inside a shared continue hold of every id.
      # @raise [SessionManager::DeleteRefused] :continuing, the first one a continue holds
      def hold_all(ids, state_dir, &block)
        return yield if ids.empty?

        ContinueIntent.hold(ids.first, state_dir: state_dir) do |held|
          raise SessionManager::DeleteRefused.new(ids.first, :continuing) unless held

          hold_all(ids.drop(1), state_dir, &block)
        end
      end

      # Each link with its delegates under their locks, newest first; a
      # refused one keeps it and every earlier link whole.
      def delete_links(id, newest_first, plans, links, state_dir)
        done = { id: id, deleted: [], left: [], left_running: [], unarchived: [], refusal: nil }
        record = nil
        newest_first.each_with_index do |link, at|
          plan = plans.fetch(link)
          batch = [*plan.delete, link]
          deleted_record = ContinuedFrom.read(link, state_dir: state_dir)
          begin
            locked(batch, state_dir) { remove_locked(batch, state_dir) }
          rescue SessionManager::DeleteRefused, SessionManager::OwnedByTUI, Session::NotFound => e
            raise if done[:deleted].empty?

            done[:left] = newest_first[at..].reverse
            done[:refusal] = e.message
            done[:unarchived] = revive_left_end(newest_first[at - 1], record, link, links, state_dir)
            break
          ensure
            SessionManager.purge_removal_stores(batch.reject { |sid| on_disk?(sid, state_dir) }, state_dir: state_dir)
          end
          # The record of the link just deleted, read before it went: the
          # next link's revive takes what its continue archived.
          record = deleted_record
          done[:deleted].concat(batch)
          done[:left_running].concat(plan.leave)
        end
        done
      end

      # D2 on what a part-way refusal left: its end comes back to the lists
      # (with what the deleted successor's continue archived) unless that
      # successor was archived itself. The successor's record was read
      # before it went.
      def revive_left_end(successor, record, left_end, links, state_dir)
        return [] if links.archived?(successor) || !links.archived?(left_end)

        ids = record&.previous_id == left_end ? (record.archived_ids | [left_end]) : [left_end]
        ids.select { |sid| ArchiveStore.unarchive(sid, state_dir: state_dir) }
      end

      def on_disk?(id, state_dir)
        File.exist?(Session.session_file(id, state_dir: state_dir)) || Dir.exist?(Session.session_dir(id, state_dir: state_dir))
      end
    end
  end
end
