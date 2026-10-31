# frozen_string_literal: true

require_relative "context_sources"
require_relative "session_inbox"
require_relative "log"

module Samagotchi
  # Movable context on its two paths, a continue (SessionContinue) and a
  # plugin fork (ctx.sessions.fork): from SessionManager.spawn_session's
  # before_spawn, once the new session and its first note are saved and
  # before its worker starts, so its first absorb sees the sources.
  module ContextMove
    # What the new session's note says it is from.
    NOTE_SOURCE = "attached context"

    # ContextSources.move, then a second note in the new session saying what
    # moved and what stayed (named by time, it sorts after the first). Best
    # effort: a failure is logged and the session starts without (its start
    # must not be undone for it).
    # @return [ContextSources::Moved]
    def self.call(from:, to:, mode:, state_dir:, seed: nil)
      moved = ContextSources.move(from: from, to: to, mode: mode, seed: seed, state_dir: state_dir)
      text = moved.note_text(from)
      SessionInbox.write_note(to, text: text, source: NOTE_SOURCE, state_dir: state_dir) if text
      moved
    rescue StandardError => e
      Log.warn(:context, "context_move_failed", sid: to, from: from, error: e.class.name, msg: e.message.to_s[0, 200])
      ContextSources::Moved.none
    end
  end
end
