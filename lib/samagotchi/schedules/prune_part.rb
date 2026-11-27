# frozen_string_literal: true

require "time"
require_relative "../archive_store"
require_relative "../log"
require_relative "../session"
require_relative "../session_manager"
require_relative "../session_transition"

module Samagotchi
  class Schedules
    # The chain prune after a firing (docs/scheduling.md, "Keeping the chain
    # short"): the links behind a chain entry's keep_links window go, oldest
    # first, each under the transition locks of it and the link after it.
    # A link that can't go now holds the prune there (never skipped past:
    # the chain is not deleted around it); the entry records where and why
    # (PRUNE_WAITING, shown by chi schedule list/show), and every tick
    # tries again until it goes.
    module PrunePart
      # The entry's extra key for where its prune waits: {"link", "reason",
      # "at"} (since when it waits at that link). No history row: it is
      # state, cleared once the prune gets past it.
      PRUNE_WAITING = "prune_waiting"

      # Where an entry's prune waits.
      Waiting = Data.define(:link, :reason, :at)

      # @return [Waiting, nil]
      def self.waiting(entry)
        value = entry.extra[PRUNE_WAITING]
        return nil unless value.is_a?(Hash) && Session.valid_id?(value["link"])

        Waiting.new(link: value["link"], reason: value["reason"].to_s, at: value["at"])
      end

      private

      # The entries a tick prunes: the chain entries it fired, then every
      # enabled one whose prune waits at a link (#prune tries it again).
      def prunes_due(fired, listed)
        waiting = listed.select do |entry|
          entry.enabled && entry.mode == CHAIN && entry.keep_links.positive? && PrunePart.waiting(entry) &&
            fired.none? { |done| done.id == entry.id }
        end
        fired + waiting
      end

      # The links behind the kept window, with the delegates that hung under
      # them: archiving a link archives its descendants, and archived sessions
      # are outside the retention sweep, so the delegate pile is the bulk of the
      # archived count. Oldest link first, and within a link its children first
      # (deepest first) and the link last. A link already gone (the one an
      # earlier prune deleted: the walk back from the head ends on its id) is
      # skipped, not a stop, or every prune after the first would stall
      # there. The anchor is never pruned: `last:<anchor>` must keep resolving
      # (SessionChain::Links forwards it over the gap to the head), and it is
      # the id the user remembers. Any other link that can't go now
      # (#prune_hold, or its or the next link's transition lock held) stops
      # the prune below it, recorded (#note_waiting); a schedule failure it
      # is not.
      def prune(entry, links)
        chain = chain_back(entry, links)
        older = chain[entry.keep_links..] || []
        note_waiting(entry, older.empty? ? nil : prune_links(entry, chain, older))
      rescue Session::NotFound => e
        Log.warn(:worker, "prune_missing", id: entry.id, msg: e.message)
      end

      # The chain from the head back to the anchor, head first.
      def chain_back(entry, links)
        chain = []
        id = entry.head
        while id && !chain.include?(id)
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
        chain
      end

      # +older+ deleted oldest first, each link under the exclusive
      # transition locks (kind :delete, one try) of it and the link after
      # it, its hold checked again under them.
      # @return [Array(String, String), nil] the link the prune stopped at
      #   and why, nil when it got through
      def prune_links(entry, chain, older)
        older.reverse_each do |link|
          next if link == entry.anchor || link_gone?(link)

          reason = prune_hold(link)
          return [link, reason] if reason

          following = chain[chain.index(link) - 1]
          stopped = SessionTransition.exclusive([link, following], kind: :delete, state_dir: @state_dir, deadline: 0) do
            reason = prune_hold(link)
            next [link, reason] if reason

            tree = SessionManager.delete_tree_ids(link, @state_dir)
            # Children first (deepest first), the link last: if a delete is
            # refused partway, nothing above it has gone, so the next try
            # finds the same set instead of children under a deleted link.
            SessionManager.delete_ids(tree, state_dir: @state_dir)
            Log.info(:worker, "pruned_link", sid: link, id: entry.id, links: tree.size)
            nil
          end
          return stopped if stopped
        rescue SessionTransition::Busy => e
          return [link, e.message]
        rescue SessionManager::DeleteRefused => e
          return [link, e.session_id == link ? e.message : "#{e.session_id.to_s[0, 8]}: #{e.message}"]
        end
        nil
      end

      # Why +link+ (behind the window) can't go now, nil when it can: not
      # archived (a user brought it back), a schedule's anchor, head or
      # target in its subtree (another entry anchored inside the chain), a
      # live worker in it, or a descendant not archived. The whole subtree
      # must be ready: never half a tree.
      def prune_hold(link)
        return "it is not archived" unless ArchiveStore.archived?(Session.session_dir(link, state_dir: @state_dir))

        tree = SessionManager.delete_tree_ids(link, @state_dir)
        tree.reverse_each do |sid|
          SessionManager.refuse_protected!(sid, @state_dir)
        rescue SessionManager::DeleteRefused => e
          return sid == link ? e.message : "its delegate #{sid[0, 8]}: #{e.message}"
        end
        owned = tree.select { |sid| SessionManager.session_owner(sid, state_dir: @state_dir) }
        return "a worker runs in it: #{owned.map { |sid| sid[0, 8] }.join(", ")}" unless owned.empty?

        open = tree[0...-1].reject { |sid| ArchiveStore.archived?(Session.session_dir(sid, state_dir: @state_dir)) }
        "its delegates are not archived: #{open.map { |sid| sid[0, 8] }.join(", ")}" unless open.empty?
      end

      # Record where +entry+'s prune waits (+waiting+: [link, reason]) or
      # that it waits nowhere (nil), under the file's lock, on the stored
      # entry; logged (prune_waiting) once per link it waits at, not every
      # tick. Nothing is written when the entry's record (read with it)
      # says the same.
      def note_waiting(entry, waiting)
        link, reason = waiting
        was = PrunePart.waiting(entry)
        return if was.nil? && link.nil?
        return if was && was.link == link && was.reason == reason

        logged = false
        write_under_lock do |file|
          position = file.entries.index { |candidate| candidate.is_a?(Entry) && candidate.id == entry.id }
          next unless position

          stored = file.entries[position]
          before = PrunePart.waiting(stored)
          extra = stored.extra.except(PRUNE_WAITING)
          if link
            at = before&.link == link ? before.at : @clock.call.utc.iso8601
            extra = extra.merge(PRUNE_WAITING => { "link" => link, "reason" => reason, "at" => at })
            logged = before&.link != link
          end
          file.entries[position] = stored.with(extra: extra)
        end
        Log.warn(:worker, "prune_waiting", sid: link, id: entry.id, msg: reason) if logged
      end

      # Neither a session file nor a folder: nothing left to delete.
      def link_gone?(link)
        !File.exist?(Session.session_file(link, state_dir: @state_dir)) &&
          !File.directory?(Session.session_dir(link, state_dir: @state_dir))
      end
    end
  end
end
