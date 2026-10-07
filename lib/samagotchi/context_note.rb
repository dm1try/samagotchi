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
    # context_source: the attached context source a note is about
    # (ContextAbsorber), so the UIs can tie it to its chip.
    KEYS = %i[kind note_id source from_session from_cwd context_source].freeze

    module_function

    # Takes SessionInbox.read_note's keys. +turn_start+ / +turn_id+: the
    # note starts a turn chi runs for it (a context wake), as a wake turn's
    # delegate report does (Steer.turn_prompt?).
    # @return [Hash] the conversation message
    def message(note_id:, text:, source:, created_at: nil, from_session: nil, from_cwd: nil, context_source: nil,
                turn_start: nil, turn_id: nil, **)
      { role: "system", kind: KIND, note_id: note_id, source: source, from_session: from_session,
        from_cwd: from_cwd, context_source: context_source, turn_start: (true if turn_start == true), turn_id: turn_id,
        content: frame(text, source: source, created_at: created_at, from_session: from_session,
                             from_cwd: from_cwd) }.compact
    end

    def frame(text, source:, created_at: nil, from_session: nil, from_cwd: nil)
      time = clock(created_at)
      from = label(source: source, from_session: from_session, from_cwd: from_cwd)
      "[CONTEXT NOTE from #{from}#{", #{time}" if time}]\n#{text}\n[END NOTE]"
    end

    # Who sent a note: its source, or the sending session and its folder.
    def label(source:, from_session: nil, from_cwd: nil)
      return source.to_s unless from_session

      "session #{from_session.to_s[0, 6]}#{" (#{home_relative(from_cwd)})" if from_cwd}"
    end

    def label_of(message)
      label(source: fetch(message, :source), from_session: fetch(message, :from_session), from_cwd: fetch(message, :from_cwd))
    end

    # The note's own text, without its frame.
    def text_of(message)
      fetch(message, :content).to_s.sub(/\A\[CONTEXT NOTE[^\n]*\n/, "").delete_suffix("\n[END NOTE]")
    end

    def fetch(message, key)
      message.key?(key) ? message[key] : message[key.to_s]
    end

    def note?(message)
      fetch(message, :kind).to_s == KIND
    end

    # The conversation with +system_message+ at its head: an old system
    # prompt there (a system message of no kind) is replaced, anything else
    # (a note that arrived before the first turn, a turn note left by a
    # failed first turn) stays and the prompt goes before it.
    def with_system_head(messages, system_message)
      [system_message] + (system_head?(messages.first) ? messages.drop(1) : messages)
    end

    # A system prompt at a conversation's head: a system message of no kind
    # (#with_system_head replaces it).
    def system_head?(message)
      message.is_a?(Hash) && fetch(message, :role).to_s == "system" && fetch(message, :kind).to_s.empty?
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
