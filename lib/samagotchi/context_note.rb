# frozen_string_literal: true

require "time"
require_relative "paths"
require_relative "message_time"

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
    # (ContextAbsorber), so the UIs can tie it to its chip. A note's wall
    # time (MessageTime::KEY) is every entry's, kept beside these.
    # objectives: the list an objectives note carries (Objectives), string
    # keys inside.
    KEYS = %i[kind note_id source from_session from_cwd context_source objectives].freeze
    HEADER = "CONTEXT NOTE"
    # A finished background task's note (TaskFinishNote): a header of its own.
    TASK_HEADER = "TASK FINISHED"
    # The session's objectives (Objectives): a frame that instructs by itself,
    # so a session with no list sends no line about them.
    OBJECTIVES_HEADER = "OBJECTIVES"
    OBJECTIVES_FRAME = "[#{OBJECTIVES_HEADER}, set by the user. What the user wants this session to achieve; " \
                       "replaces any earlier list. Keep work on it. Say when something falls outside it. " \
                       "Don't change it yourself.]".freeze
    HEADERS = [HEADER, TASK_HEADER, OBJECTIVES_HEADER].freeze

    FRAME_HEAD = /\A\[(?:#{HEADERS.map { |h| Regexp.escape(h) }.join("|")})[^\n]*\n/

    module_function

    # Takes SessionInbox.read_note's keys. +turn_start+ / +turn_id+: the
    # note starts a turn chi runs for it (a context wake), as a wake turn's
    # delegate report does (Steer.turn_prompt?). +header+: the frame's
    # (HEADERS), not kept as a key: the content carries it. Its wall time
    # (MessageTime::KEY) is +created_at+'s, else now. +objectives+: an
    # objectives note's payload (Objectives::List#to_payload).
    # @return [Hash] the conversation message
    def message(note_id:, text:, source:, created_at: nil, from_session: nil, from_cwd: nil, context_source: nil,
                turn_start: nil, turn_id: nil, header: HEADER, objectives: nil, **)
      { role: "system", kind: KIND, note_id: note_id, source: source, from_session: from_session,
        from_cwd: from_cwd, context_source: context_source, objectives: objectives,
        turn_start: (true if turn_start == true), turn_id: turn_id,
        content: frame(text, source: source, created_at: created_at, from_session: from_session,
                             from_cwd: from_cwd, header: header),
        MessageTime::KEY => MessageTime.iso_of(created_at) || MessageTime.iso(MessageTime.now) }.compact
    end

    def frame(text, source:, created_at: nil, from_session: nil, from_cwd: nil, header: HEADER)
      return "#{OBJECTIVES_FRAME}\n#{text}\n[END NOTE]" if header == OBJECTIVES_HEADER

      time = clock(created_at)
      from = label(source: source, from_session: from_session, from_cwd: from_cwd)
      "[#{header || HEADER} from #{from}#{", #{time}" if time}]\n#{text}\n[END NOTE]"
    end

    # Who sent a note: its source, or the sending session and its folder.
    def label(source:, from_session: nil, from_cwd: nil)
      return source.to_s unless from_session

      "session #{from_session.to_s[0, 6]}#{" (#{Paths.tilde(from_cwd)})" if from_cwd}"
    end

    def label_of(message)
      label(source: fetch(message, :source), from_session: fetch(message, :from_session), from_cwd: fetch(message, :from_cwd))
    end

    # The note's own text, without its frame.
    def text_of(message)
      fetch(message, :content).to_s.sub(FRAME_HEAD, "").delete_suffix("\n[END NOTE]")
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
  end
end
