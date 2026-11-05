# frozen_string_literal: true

require "time"
require_relative "answer_tail"
require_relative "config"
require_relative "log"
require_relative "output_formatter"
require_relative "session"
require_relative "session_inbox"
require_relative "steer"
require_relative "recap_store"

module Samagotchi
  # Session chains: a session that continues an earlier one (Session#continues),
  # "the next run of the same routine". The chain is derived, never stored:
  # follow +continues+ back for the earlier links, forward (the session whose
  # +continues+ names this one) for the later ones. A link is continued at
  # most once (SessionManager.continue_session refuses a second), so the
  # chain's latest link is the one nobody continues.
  module SessionChain
    # `--continues last:<id>`: the latest link of the chain <id> is in.
    LAST_PREFIX = "last:"
    # Who the carry note is from (ContextNote's label: "note from session chain").
    NOTE_SOURCE = "session chain"
    # The most of the previous link's recap a note takes; a recap is a few
    # sentences. Characters, not bytes: #note_text holds the carry note to
    # SessionInbox::NOTE_MAX_BYTES itself.
    RECAP_CHARS = 8000
    # The most of the previous link's last answer the carry note takes. A
    # wrap-up closes on what comes next, so a longer one keeps its end.
    LAST_ANSWER_CHARS = 4000
    LAST_ANSWER_HEAD = "\n\nIts last answer:\n"
    # The "…" that marks a cut, in bytes.
    CUT_MARK_BYTES = 3

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
    # from when, that session's recap with its time, when it has one, and
    # its last answer (#last_answer; session.carry_last_answer). No other transcript. Never over
    # SessionInbox::NOTE_MAX_BYTES, whatever the session holds: the inbox
    # rejects a longer note, and a continue writes it after the archive. The
    # answer gets what the rest leaves.
    # @param previous [Session] the answer is read fresh from its file
    # @param recap [Hash, nil] RecapStore.read's
    # @return [String]
    def note_text(previous, recap:, state_dir:)
      head = "This session continues #{previous.id[0, 8]} (#{clock(previous.created_at) || previous.created_at}), the previous link of its chain."
      text = keep_start("#{head}#{recap_text(recap)}", SessionInbox::NOTE_MAX_BYTES)
      room = SessionInbox::NOTE_MAX_BYTES - text.bytesize - LAST_ANSWER_HEAD.bytesize
      answer = carried_answer(previous, room: room, state_dir: state_dir)
      answer ? "#{text}#{LAST_ANSWER_HEAD}#{answer}" : text
    end

    # The last answer as the carry note takes it, in at most +room+ bytes;
    # nil with session.carry_last_answer off, when there is none, when a
    # review link has it (a continue copies review: but not the grants, so
    # the next link's participants could differ) or when the session can't
    # be read: this runs inside a continue's rollback, and a note without it
    # is still a good note.
    # @return [String, nil]
    def carried_answer(previous, room:, state_dir:)
      return nil if previous.review? || !Config.get("session.carry_last_answer")

      text = last_answer(Session.load(previous.id, state_dir: state_dir).messages)
      text && keep_end(text, room)
    rescue StandardError => e
      Log.warn(:worker, "continue_last_answer_failed", sid: previous.id, error: e.class.name, msg: e.message)
      nil
    end

    # The session's last word: the text of AnswerTail's newest bubble, with
    # the wire-format markup stripped, unless that bubble is a step of a
    # turn (it asked for tools) or old text a later turn never replaced
    # (one that failed or was cut before it answered). A cut reply keeps
    # its "[interrupted]": that is what happened.
    # @param messages [Array<Hash>]
    # @return [String, nil]
    def last_answer(messages)
      found = AnswerTail.find(messages)
      return nil unless found && found[:content].is_a?(String) && Array(found[:tool_calls]).empty?

      at = messages.rindex { |m| m.equal?(found) }
      return nil if messages[(at + 1)..].any? { |m| m[:role].to_s == "tool_response" || later_turn?(m) }

      OutputFormatter.strip_markup(found[:content].scrub)
    end

    # A turn's opening, not a `!shell` line: a command the user ran after
    # the answer leaves it the last word.
    def later_turn?(message)
      Steer.turn_opening?(message)
    end

    # At most +max+ bytes of +text+'s start, cut on a character.
    def keep_start(text, max)
      return text if text.bytesize <= max

      "#{text.byteslice(0, max - CUT_MARK_BYTES).scrub("")}…"
    end

    # +text+'s end: at most LAST_ANSWER_CHARS characters and +max+ bytes,
    # with the "…" of a cut; nil when no character fits.
    def keep_end(text, max)
      return nil if max <= CUT_MARK_BYTES

      text = "…#{text[(1 - LAST_ANSWER_CHARS)..]}" if text.length > LAST_ANSWER_CHARS
      return text if text.bytesize <= max

      kept = text.byteslice(-(max - CUT_MARK_BYTES), max - CUT_MARK_BYTES).scrub("")
      kept.empty? ? nil : "…#{kept}"
    end

    # +recap+ as a note's tail: " Its recap, as of <time>:\n<text>" (cut
    # to RECAP_CHARS), or " It left no recap."
    # @param recap [Hash, nil] RecapStore.read's
    # @return [String]
    def recap_text(recap)
      text = recap && recap[:text].to_s.strip
      return " It left no recap." if text.nil? || text.empty?

      text = "#{text[0, RECAP_CHARS - 1]}…" if text.length > RECAP_CHARS
      as_of = clock(recap[:created_at])
      " Its recap#{", as of #{as_of}" if as_of}:\n#{text}"
    end

    # What web `continue →` prefills in +previous+'s next link: +previous+'s
    # own first typed message when +previous+ is itself a continuation (so a
    # chain's opener comes back on every link, edited once for all later
    # ones), else nil (a chain's first link's first message is its task; the
    # page falls back to its constant). Typed means a user message with text
    # and no kind: Engine#turn_messages' (turn_id), or a checkpointed prompt
    # (none); a stored `!shell` line ("!(cmd)\n<output>", no turn_id) is not.
    # @param previous [Session]
    # @return [String, nil]
    def opener_for(previous)
      return nil unless previous.continues

      previous.messages.each do |msg|
        next unless msg[:role] == "user" && msg[:kind].nil?

        text = msg[:content]
        next unless text.is_a?(String) && !text.strip.empty?
        next if Steer.shell_line?(msg)

        return text.strip
      end
      nil
    end

    def clock(iso)
      iso && Time.iso8601(iso.to_s).localtime.strftime("%Y-%m-%d %H:%M")
    rescue ArgumentError
      nil
    end
  end
end
