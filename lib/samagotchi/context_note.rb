# frozen_string_literal: true

require "time"

module Samagotchi
  # A context note: background text pushed into a session from outside (the
  # user's `chi note`, or another session's send_note). It is kept in the
  # conversation as a tail system message marked kind: "note", framed so the
  # model reads it as information, not as a request.
  module ContextNote
    KIND = "note"
    # The message keys a note carries besides role and content; everything
    # that copies messages field by field must keep them.
    KEYS = %i[kind note_id source from_session from_cwd].freeze

    module_function

    # Takes SessionManager.read_note's keys.
    # @return [Hash] the conversation message
    def message(note_id:, text:, source:, created_at: nil, from_session: nil, from_cwd: nil, **)
      { role: "system", kind: KIND, note_id: note_id, source: source, from_session: from_session,
        from_cwd: from_cwd, content: frame(text, source: source, created_at: created_at,
                                                 from_session: from_session, from_cwd: from_cwd) }.compact
    end

    def frame(text, source:, created_at: nil, from_session: nil, from_cwd: nil)
      from = from_session ? "session #{from_session.to_s[0, 6]}" : source.to_s
      from += " (#{home_relative(from_cwd)})" if from_session && from_cwd
      time = clock(created_at)
      "[CONTEXT NOTE from #{from}#{", #{time}" if time}]\n#{text}\n[END NOTE]"
    end

    def note?(message)
      (message[:kind] || message["kind"]).to_s == KIND
    end

    # The conversation with +system_message+ at its head: an old system
    # prompt there is replaced, anything else (a note that arrived before the
    # first turn included) stays and the prompt goes before it.
    def with_system_head(messages, system_message)
      first = messages.first
      replace = first && (first[:role] || first["role"]).to_s == "system" && !note?(first)
      [system_message] + (replace ? messages.drop(1) : messages)
    end

    def clock(created_at)
      created_at && Time.iso8601(created_at.to_s).localtime.strftime("%H:%M")
    rescue ArgumentError
      nil
    end

    def home_relative(path)
      home = Dir.home
      path.to_s.start_with?("#{home}/") || path.to_s == home ? path.to_s.sub(home, "~") : path.to_s
    end
  end
end
