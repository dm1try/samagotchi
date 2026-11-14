# frozen_string_literal: true

require_relative "../archive_store"
require_relative "../log"
require_relative "../session"

module Samagotchi
  module SessionChain
    # The one walker of "who continues whom": every chain walk (SessionChain.latest
    # and .next_of, SessionInbox::Head, Schedules' tick) goes through one of
    # these. Built over one Session.list (archived ones too, created_at asc),
    # made on the first question that needs it, so asking only #archived? of
    # one id lists nothing. A link's successor is the earliest session that
    # continues it (a fork a hand edit or an old race made keeps the first);
    # a walk that comes back to a link it passed (a loop a hand-edited file
    # could make) ends where it would repeat. A walk stops where no listed
    # session continues the link: past a deleted middle link nothing is
    # reached.
    #
    # The walks, and who uses which (not unified on purpose: a schedule
    # firing must continue the chain's end, SessionContinue refuses a link
    # already continued; input from a person goes to the first link still
    # live, and a send un-archives an archived end, a schedule never does):
    # - #latest: the chain's end (SessionChain.latest, `last:<id>`, Schedules)
    # - #first_live: the first link not archived, or the end (Head: send, note)
    # - #root: back to the first link (Schedules' one firing per chain)
    # - #chain / #live_links: every link of +id+'s branch, root to end
    #   (Schedules#chain_of, the chain delete)
    #
    # The listing is a snapshot: one Links per question, or per tick.
    class Links
      attr_reader :state_dir

      def initialize(state_dir:)
        @state_dir = state_dir
        @by_id = nil
        @nexts = nil
        @archived = {}
      end

      # The listed session +id+ (a Session summary), or nil.
      def session(id) = by_id[id]

      # Not in the listing (pruned, deleted, never existed).
      def gone?(id) = by_id[id].nil?

      # Whether +id+ is archived: from the listing once it is made (it read
      # the flags), else one ArchiveStore check, kept.
      def archived?(id)
        return @archived[id] if @archived.key?(id)
        return @archived[id] = by_id[id]&.archived || false if @by_id

        @archived[id] = Session.valid_id?(id) && ArchiveStore.archived?(Session.session_dir(id, state_dir: @state_dir))
      end

      # The session +id+ continues, or nil (a first link, or not listed).
      def continues(id) = by_id[id]&.continues

      # The session that continues +id+, or nil. Archived ones count: an
      # archived link is still a link.
      def next_of(id) = nexts[id]

      # The chain's end from +id+ on: +id+ itself when nobody continues it.
      def latest(id) = walk(id).last

      # From +id+ forward over archived links: +id+ when it is not archived,
      # else the first link after it that is not, or the chain's end. Only an
      # archived +id+ makes the listing.
      def first_live(id)
        return id unless archived?(id)

        walk(id) { |link| !archived?(link) }.last
      end

      # The chain's first link: back through `continues` to a link with no
      # predecessor listed. A predecessor that is gone ends the walk on its
      # id, so every link after it names the same root.
      def root(id)
        seen = [id]
        while (previous = continues(seen.last)) && !seen.include?(previous)
          seen << previous
        end
        seen.last
      end

      # Every link of +id+'s chain, root to end: from #latest(id) back
      # through `continues`, reversed, so the walk stays on +id+'s own branch
      # of a fork. A gone predecessor ends it on its id (as #root does: a
      # schedule's anchor or head may name a deleted root); a loop ends where
      # it would repeat.
      # @return [Array<String>]
      def chain(id)
        ids = [latest(id)]
        while (previous = continues(ids.last)) && !ids.include?(previous)
          ids << previous
        end
        log_forks(ids)
        ids.reverse
      end

      # #chain without the gone ids: the links that still have a file.
      # @return [Array<String>]
      def live_links(id) = chain(id).reject { |link| gone?(link) }

      private

      # +id+ and the links after it, in order, until none follows, a link
      # would repeat, or the block says stop at the one just reached.
      def walk(id)
        seen = [id]
        while (following = nexts[seen.last]) && !seen.include?(following)
          seen << following
          break if block_given? && yield(following)
        end
        seen
      end

      def by_id
        @by_id ||= Session.list(state_dir: @state_dir, sort: "created_at", order: "asc", include_archived: true)
                          .to_h { |session| [session.id, session] }
      end

      # id → the session that continues it: the earliest created.
      def nexts
        @nexts ||= by_id.each_value.with_object({}) do |session, nexts|
          nexts[session.continues] ||= session.id if session.continues
        end
      end

      # continues id → the sessions that continue it, from the one listing.
      def successors
        @successors ||= by_id.each_value.select(&:continues).group_by(&:continues)
      end

      # A link continued twice (a hand edit, an old race): #chain follows
      # +ids+' own branch and the other keeps a gap. Logged, not handled.
      def log_forks(ids)
        ids.each do |link|
          others = Array(successors[link]).map(&:id) - ids
          next if others.empty?

          Log.debug(:worker, "chain_fork", sid: link[0, 8], others: others.map { |sid| sid[0, 8] })
        end
      end
    end
  end
end
