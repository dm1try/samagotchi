# frozen_string_literal: true

require "time"
require_relative "session"
require_relative "recap_store"

module Samagotchi
  # Session chains: a session that continues an earlier one (Session#continues),
  # "the next day of the same routine". The chain is derived, never stored:
  # follow +continues+ back for the earlier links, forward (the session whose
  # +continues+ names this one) for the later ones. A link is continued at
  # most once (SessionManager.continue_session refuses a second), so the
  # chain's latest link is the one nobody continues.
  module SessionChain
    # `--continues last:<id>`: the latest link of the chain <id> is in.
    LAST_PREFIX = "last:"
    # Who the carry note is from (ContextNote's label: "note from session chain").
    NOTE_SOURCE = "session chain"
    # The most of the previous link's recap the carry note takes; a recap is
    # a few sentences, this only keeps a runaway one under the note's 16 KiB.
    RECAP_CHARS = 8000

    module_function

    # The session that continues +id+, else nil. Archived ones count: an
    # archived link is still a link.
    # @return [String, nil]
    def next_of(id, state_dir:)
      Session.list(state_dir: state_dir, sort: "created_at", order: "asc", include_archived: true)
             .find { |s| s.continues == id }&.id
    end

    # The chain's latest link from +id+ on: +id+ itself when nobody
    # continues it. One listing, walked forward (a loop a hand-edited file
    # could make ends where it started).
    # @return [String]
    def latest(id, state_dir:)
      nexts = {}
      Session.list(state_dir: state_dir, sort: "created_at", order: "asc", include_archived: true).each do |s|
        nexts[s.continues] ||= s.id if s.continues
      end
      seen = [id]
      while (following = nexts[seen.last]) && !seen.include?(following)
        seen << following
      end
      seen.last
    end

    # A session to continue as the CLI and the web name it: an id, a unique
    # prefix, or `last:<id or prefix>` for that chain's latest link.
    # @return [String] the full id of an existing session
    # @raise [ArgumentError] none such (Session::AmbiguousId for a prefix of several)
    def resolve(ref, state_dir:)
      given = ref.to_s.strip
      last = given.start_with?(LAST_PREFIX)
      given = given.delete_prefix(LAST_PREFIX) if last
      raise ArgumentError, "no session #{ref}" unless Session.valid_id?(given)

      id = Session.resolve_id(given, state_dir: state_dir)
      raise ArgumentError, "no session #{ref}" unless Session.exist?(id, state_dir: state_dir)

      last ? latest(id, state_dir: state_dir) : id
    end

    # The context note a new link starts with: which session it continues,
    # from when, and that session's recap with its time, when it has one.
    # Never more than the recap: no transcript.
    # @param previous [Session]
    # @param recap [Hash, nil] RecapStore.read's
    # @return [String]
    def note_text(previous, recap:)
      head = "This session continues #{previous.id[0, 8]} (#{day(previous.created_at)}), the previous link of its chain."
      text = recap && recap[:text].to_s.strip
      return "#{head} It left no recap." if text.nil? || text.empty?

      text = "#{text[0, RECAP_CHARS - 1]}…" if text.length > RECAP_CHARS
      as_of = clock(recap[:created_at])
      "#{head} Its recap#{", as of #{as_of}" if as_of}:\n#{text}"
    end

    def day(iso)
      Time.iso8601(iso.to_s).localtime.strftime("%Y-%m-%d")
    rescue ArgumentError
      iso.to_s
    end

    def clock(iso)
      iso && Time.iso8601(iso.to_s).localtime.strftime("%Y-%m-%d %H:%M")
    rescue ArgumentError
      nil
    end
  end
end
