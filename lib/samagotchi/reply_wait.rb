# frozen_string_literal: true

require_relative "session"
require_relative "turn_note"
require_relative "session_inbox"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires KernelLoop and so the tools that use this (a require cycle
  # otherwise).
  autoload :SessionManager, File.expand_path("session_manager", __dir__)

  # Waiting for a session's next reply. A reply is the worker's
  # output/<timestamp>.txt file (one per turn that ended with visible text,
  # written just before its idle save), so "next" means a filename past the
  # cursor the caller holds: the newest one it already has, or nil for any.
  # The delegate tools and `chi send --wait` wrap it in their own words.
  module ReplyWait
    POLL_INTERVAL = 0.5

    # @!attribute status [Symbol] :done, :waiting_for_answer, :no_reply,
    #   :error, :stopped, :canceled, :timeout or :worker_gone
    # @!attribute text [String, nil] the reply (:done) or the worker's error
    #   (:error)
    # @!attribute file [String, nil] the reply's filename, the next cursor
    # @!attribute question [Hash, nil] the pending question
    #   (:waiting_for_answer)
    # @!attribute outcome [String, nil] how the turn ended when it left no
    #   reply (:no_reply): "failed", "canceled", "completed" (empty),
    #   "exhausted" (it ran out of iterations, with nobody asked whether to
    #   continue) or "not_continued" (a Stop answered the step-limit
    #   question; no turn ran), from the session's last_turn; nil when unknown. With
    #   "failed", text is the failure's summary when the turn note has one.
    # @!attribute limit [Integer, nil] the iteration limit an "exhausted"
    #   turn ran out at
    # @!attribute error_kind [String, nil] a "failed" turn's provider error
    #   kind (credits, server, auth, …), from last_turn
    # @!attribute retryable [Boolean, nil] whether that error may pass on a
    #   retry
    # @!attribute cancel_reason [String, nil] a "canceled" turn's reason
    #   (user, hook, ctrl_c, manual)
    # @!attribute stopped_by [String, nil] the hook that canceled it
    #   (loop-guard)
    # @!attribute session [Session, nil] the session as the look that
    #   decided the outcome loaded it (a caller's next baseline); nil for
    #   :canceled and :timeout
    Result = Struct.new(:status, :text, :file, :question, :outcome, :limit, :error_kind, :retryable, :cancel_reason,
                        :stopped_by, :kept_steps, :session, keyword_init: true)

    module_function

    # @param id [String] the session's full id
    # @param state_dir [String]
    # @param cursor [String, nil] the newest reply filename already had
    # @param timeout [Numeric, nil] seconds; nil waits with no limit
    # @param poll_interval [Float]
    # @param cancelled [#call] true stops the wait (:canceled)
    # @param baseline [Hash, nil] {messages:, question_id:} as the session
    #   was before the message went in. With it, a turn that grew the
    #   messages (a failed, canceled or empty one leaves its note) and went
    #   idle again ends the wait even if it was never seen running, and a
    #   question already pending then is not the answer's. A nil
    #   messages: skips the count. last_turn: (the session's
    #   last_turn["ended_at"] then, maybe nil) ends the wait on any turn
    #   that ended since, idle again, however fast it ran (a failure after
    #   a failure replaces the note and leaves the count as it was), and
    #   with it the count isn't used: a note between turns grows it too.
    # @param owner_grace [Numeric, nil] seconds with no live worker before
    #   :worker_gone (one that died before its rescue leaves it running)
    # @param interject [#call, nil] called once a poll, before the sleep
    #   (the delegate wait relays other children's approvals there); the
    #   time it takes doesn't count against +timeout+
    # @return [Result]
    # @raise [ArgumentError] no such session
    def call(id, state_dir:, cursor:, timeout: nil, poll_interval: POLL_INTERVAL, cancelled: -> { false },
             baseline: nil, owner_grace: nil, interject: nil)
      deadline = timeout && (monotonic + timeout.to_f)
      seen_running = false
      gone_since = nil

      loop do
        session = Session.load(id, state_dir: state_dir)

        if (reply = reply_past(id, state_dir: state_dir, cursor: cursor))
          reply.session = settled(session, id, state_dir: state_dir)
          return reply
        end

        case session.status
        when Session::STATUS_ERROR
          return Result.new(status: :error, text: session.last_prompt.to_s.strip, session: session)
        when Session::STATUS_STOPPED
          return Result.new(status: :stopped, session: session)
        end

        # Only a question a live worker holds waits for an answer (the
        # lists' rule): one a dead worker left waits for no one, and a chi
        # REPL's is answered there.
        pending = session.pending_question
        if pending && !(baseline && pending[:id] == baseline[:question_id]) &&
           session.waiting_question(live: SessionManager.worker_live?(id, state_dir: state_dir))
          return Result.new(status: :waiting_for_answer, question: pending, session: session)
        end

        return Result.new(status: :canceled) if cancelled.call

        if session.status == Session::STATUS_RUNNING
          seen_running = true
        elsif seen_running || turn_ended_since?(session, baseline)
          # It ran and is idle again with no new reply: canceled, failed or
          # empty. Before it was ever seen running, idle means a
          # file-delivered message its worker has not picked up yet.
          # The worker writes the reply before its idle save, so the read
          # above has it; one more look costs nothing should that change.
          return reply_past(id, state_dir: state_dir, cursor: cursor)&.tap { |r| r.session = session } ||
                 no_reply(session, baseline)
        end

        if owner_grace
          if SessionManager.session_owner(id, state_dir: state_dir)
            gone_since = nil
          elsif monotonic - (gone_since ||= monotonic) > owner_grace
            return Result.new(status: :worker_gone, session: session)
          end
        end

        return Result.new(status: :timeout) if deadline && monotonic > deadline

        if interject
          started = monotonic
          interject.call
          deadline += monotonic - started if deadline
          next if cancelled.call
        end
        sleep(poll_interval)
      end
    end

    # The session as it was before a message went in (call's baseline:):
    # its messages, the question pending then, and when its last turn
    # ended, so a turn that ends before the first look still ends the wait.
    # @return [Hash]
    def baseline_of(session, question_id: session.pending_question&.dig(:id))
      last = session.last_turn.is_a?(Hash) ? session.last_turn["ended_at"] : nil
      { messages: session.messages.size, question_id: question_id, last_turn: last }
    end

    # An idle session whose turn ended after the baseline was taken: its
    # last_turn moved on. Every turn's end records last_turn as it goes
    # idle (Engine#end_turn), so with one in the baseline that alone
    # decides: messages also grow between turns (a new worker's context
    # note, a chi note) with no turn run. A baseline without it falls back
    # to the count (a turn's note).
    def turn_ended_since?(session, baseline)
      return false unless baseline

      if baseline.key?(:last_turn)
        ended = session.last_turn.is_a?(Hash) ? session.last_turn["ended_at"] : nil
        return !ended.nil? && ended != baseline[:last_turn]
      end
      !!(baseline[:messages] && session.messages.size > baseline[:messages])
    end

    # @return [Result] :no_reply with the outcome the session's last_turn
    #   records, when it is the turn waited for
    def no_reply(session, baseline)
      last = session.last_turn.is_a?(Hash) ? session.last_turn : {}
      fresh = baseline.nil? || !baseline.key?(:last_turn) || (last["ended_at"] && last["ended_at"] != baseline[:last_turn])
      outcome = fresh ? last["outcome"] : nil
      if fresh && last["exhausted"]
        return Result.new(status: :no_reply, outcome: "exhausted", limit: last["limit"], session: session)
      end

      text = outcome == "failed" ? TurnNote.failure_summary(session.messages) : nil
      why = fresh ? last.slice("error_kind", "retryable", "cancel_reason", "stopped_by", "kept_steps").transform_keys(&:to_sym) : {}
      Result.new(status: :no_reply, outcome: outcome, text: text, session: session, **why)
    end

    SETTLE_SECONDS = 1.0

    # The session after the turn that wrote a reply was saved. The worker
    # writes the reply just before that save, so a look between the two
    # loaded the session still running, with the turn before's last_turn: a
    # baseline from it would read the reply's own turn as a later one that
    # left no reply. Loads again (briefly) until it shows idle or its
    # last_turn moved on; a session running a next turn by then has the
    # reply's turn as its last_turn, which is right too.
    def settled(session, id, state_dir:)
      return session unless session.status == Session::STATUS_RUNNING

      before = session.last_turn.is_a?(Hash) ? session.last_turn["ended_at"] : nil
      deadline = monotonic + SETTLE_SECONDS
      loop do
        sleep(0.02)
        fresh = Session.load(id, state_dir: state_dir)
        ended = fresh.last_turn.is_a?(Hash) ? fresh.last_turn["ended_at"] : nil
        return fresh if fresh.status != Session::STATUS_RUNNING || ended != before || monotonic > deadline
      end
    rescue ArgumentError
      session
    end

    # @return [Result, nil] :done with the newest reply past the cursor
    def reply_past(id, state_dir:, cursor:)
      file = newest_reply(id, state_dir: state_dir)
      return nil unless file && newer?(file, cursor)

      Result.new(status: :done, text: File.read(File.join(reply_dir(id, state_dir: state_dir), file)), file: file)
    end

    # @return [String, nil] the newest reply filename (sortable timestamps)
    def newest_reply(id, state_dir:)
      dir = reply_dir(id, state_dir: state_dir)
      return nil unless Dir.exist?(dir)

      Dir.children(dir).select { |f| f.end_with?(".txt") }.max
    end

    def reply_dir(id, state_dir:)
      File.join(Session.session_dir(id, state_dir: state_dir), SessionInbox::OUTPUT_DIR)
    end

    def newer?(file, cursor)
      cursor.nil? || file > cursor
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
