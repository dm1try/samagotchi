# frozen_string_literal: true

require_relative "../archive_store"
require_relative "../log"
require_relative "../session"
require_relative "../session_manager"

module Samagotchi
  class Schedules
    # The chain prune after a firing (docs/scheduling.md, "Keeping the chain
    # short"): the links behind a chain entry's keep_links window go.
    module PrunePart
      private

      # The links behind the kept window, with the delegates that hung under
      # them: archiving a link archives its descendants, and archived sessions
      # are outside the retention sweep, so the delegate pile is the bulk of the
      # archived count. Oldest link first, and within a link its children first
      # (deepest first) and the link last. The walk stops at a link that is not
      # archived, one whose subtree has a live worker, or one with a descendant
      # still unarchived: nothing is deleted in that case, and the next firing
      # retries (a schedule failure it is not). The anchor is never pruned:
      # `last:<anchor>` must keep resolving, and it is the id the user remembers.
      def prune(entry, links)
        chain = []
        id = entry.head
        seen = []
        while id && !seen.include?(id)
          seen << id
          chain << id
          # The walk stops at the anchor: the links before it are the user's own
          # history, made before this schedule existed, and the anchor itself is
          # the id `last:<anchor>` and the user remember.
          break if id == entry.anchor

          # The link a firing just made is not in the tick's listing; every
          # older one is.
          session = links.session(id) || (File.exist?(Session.session_file(id, state_dir: @state_dir)) ? Session.load(id, state_dir: @state_dir) : nil)
          id = session&.continues
        end
        older = chain[entry.keep_links..] || []
        return if older.empty?

        older.reverse_each do |link|
          next if link == entry.anchor
          break unless ArchiveStore.archived?(Session.session_dir(link, state_dir: @state_dir))

          tree = SessionManager.delete_tree_ids(link, @state_dir)
          descendants = tree[0...-1]
          # The whole subtree must be ready: a live worker anywhere in it, or a
          # link's descendant that is not archived, stops the walk here rather
          # than half-deleting a tree.
          owned = tree.select { |sid| SessionManager.session_owner(sid, state_dir: @state_dir) }
          unless owned.empty?
            Log.warn(:worker, "prune_waiting", sid: link, id: entry.id, owned: owned.map { |sid| sid[0, 8] })
            break
          end

          open = descendants.reject { |sid| ArchiveStore.archived?(Session.session_dir(sid, state_dir: @state_dir)) }
          unless open.empty?
            Log.warn(:worker, "prune_open_children", sid: link, id: entry.id, open: open.map { |sid| sid[0, 8] })
            break
          end

          # Children first (deepest first), the link last: if a delete is
          # refused partway, nothing above it has gone, so the next firing
          # retries the same set instead of leaving children under a link that
          # is already deleted.
          SessionManager.delete_ids(tree, state_dir: @state_dir)
          Log.info(:worker, "pruned_link", sid: link, id: entry.id, links: descendants.size + 1)
        end
      rescue SessionManager::DeleteRefused => e
        Log.warn(:worker, "prune_stopped", sid: e.session_id, id: entry.id, msg: e.message)
      rescue Session::NotFound => e
        Log.warn(:worker, "prune_missing", id: entry.id, msg: e.message)
      end
    end
  end
end
