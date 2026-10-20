# frozen_string_literal: true

require_relative "session"
require_relative "turn_note"
require_relative "session_inbox"
require_relative "turn_checkpoint"
require_relative "worker_sidecar"

module Samagotchi
  # Loaded on first use: this autoload keeps SessionManager and its ~80
  # files unloaded until the delegate/session path needs them.
  autoload :SessionManager, File.expand_path("session_manager", __dir__)

  # Waiting for a session's next reply. A reply is the worker's
  # output/<timestamp>.txt file (one per turn that ended with visible text,
  # written just before its idle save), so "next" means a filename past the
  # cursor the caller holds: the newest one it already has, or nil for any.
  # A wait for one input's turn (turn:, a queued message) looks for that
  # turn's own file instead (output/<timestamp>-<enqueued_id>.txt).
  # The delegate tools and `chi send --wait` wrap it in their own words.
  module ReplyWait
    POLL_INTERVAL = 0.5
    # A worker's sidecar feature (Bridge::FEATURES): its running turn's
    # checkpoint mark (InterruptedTurn#enqueued_id), a continue turn and a
    # Stop's last_turn carry the turn's enqueued_id (#own_turn).
    TURN_IDS_FEATURE = "turn_ids"

    # @!attribute status [Symbol] :done, :waiting_for_answer, :no_reply,
    #   :error, :stopped, :canceled, :timeout or :worker_gone
    # @!attribute text [String, nil] the reply (:done) or the worker's error
    #   (:error)
    # @!attribute file [String, nil] the reply's filename, the next cursor
    # @!attribute question [PendingQuestion, nil] the pending question
    #   (:waiting_for_answer)
    # @!attribute outcome [String, nil] how the turn ended when it left no
    #   reply (:no_reply): "failed", "canceled", "completed" (empty turn or
    #   file-delivered command ran without a turn),
    #   "exhausted" (it ran out of iterations, with nobody asked whether to
    #   continue), "not_continued" (a Stop answered the step-limit
    #   question; no turn ran), from the session's last_turn, or "removed"
    #   (turn:'s queued input was taken back before it ran, its tombstone:
    #   SessionInbox.removed?; no turn ran); nil when unknown. With
    #   "failed", text is the failure's summary when the turn note has one.
    # @!attribute limit [Integer, nil] the iteration limit an "exhausted"
    #   turn ran out at
    # @!attribute error_kind [String, nil] a "failed" turn's provider error
    #   kind (credits, server, auth, …), from last_turn
    # @!attribute retryable [Boolean, nil] whether that error may pass on a
    #   retry
    # @!attribute cancel_reason [String, nil] a "canceled" turn's reason
    #   (user, hook, ctrl_c, manual, session_stopped: the session was
    #   stopped mid-turn; worker_stopped: turn:'s worker died in it and the
    #   next one settled it, TurnCheckpoint.settled_turn), passed through
    #   as the worker saved it; any reason is a "canceled" outcome
    # @!attribute stopped_by [String, nil] the hook that canceled it
    #   (loop-guard)
    # @!attribute session [Session, nil] the session as the look that
    #   decided the outcome loaded it (a caller's next baseline); nil for
    #   :canceled and :timeout
    # @!attribute turn_id [String, nil] the id of the turn this result is
    #   about, when known
    # @!attribute origin [String, nil] "command" for a :no_reply that a
    #   file-delivered session command settled (no turn ran:
    #   TurnCheckpoint.record_command_outcome); nil otherwise
    Result = Struct.new(:status, :text, :file, :question, :outcome, :limit, :error_kind, :retryable, :cancel_reason,
                        :stopped_by, :kept_steps, :session, :turn_id, :origin, keyword_init: true)

    # The session as it was before a message went in (call's baseline:,
    # #baseline_of): its message count, the question pending then, and when
    # its last turn ended (+last_turn+, last_turn.ended_at, maybe nil).
    # Every turn's end records last_turn as it goes idle (Engine#end_turn),
    # so +last_turn+ alone says whether a turn ended since: messages also
    # grow between turns (a new worker's context note, a chi note) with no
    # turn run. +messages+ is kept for a delegate's cursor (DelegateCursor:
    # nil there means no baseline taken).
    Baseline = Data.define(:messages, :question_id, :last_turn) do
      def initialize(messages: nil, question_id: nil, last_turn: nil) = super

      # Whether +session+'s last turn ended since: its last_turn moved on.
      def turn_ended_since?(session)
        ended = session.last_turn&.ended_at
        !ended.nil? && ended != last_turn
      end

      # Whether +ended_at+ is the end of the turn that was last at the
      # baseline (a turn that ended before it).
      def ended_at?(ended_at) = ended_at == last_turn

      # Whether +question_id+ was pending at the baseline (not the answer's).
      def question?(question_id) = question_id == self.question_id
    end

    module_function

    # @param id [String] the session's full id
    # @param state_dir [String]
    # @param cursor [String, nil] the newest reply filename already had
    # @param timeout [Numeric, nil] seconds; nil waits with no limit
    # @param poll_interval [Float]
    # @param cancelled [#call] true stops the wait (:canceled)
    # @param baseline [Baseline, nil] the session as it was before the
    #   message went in (#baseline_of). With it, any turn that ended since
    #   (its last_turn moved on) and went idle again ends the wait, even if
    #   it was never seen running, however fast it ran, and a question
    #   already pending then is not the answer's.
    # @param owner_grace [Numeric, nil] seconds with no live worker before
    #   :worker_gone (one that died before its rescue leaves it running)
    # @param interject [#call, nil] called once a poll, before the sleep
    #   (the delegate wait relays other children's approvals there); the
    #   time it takes doesn't count against +timeout+
    # @param turn [String, nil] the enqueued_id of the input whose turn is
    #   waited for (a queued message, which runs after the turn running
    #   now). With it only that turn ends the wait: its reply file
    #   (SessionInbox.reply_for), or an idle session whose last_turn has
    #   that enqueued_id (failed, canceled, empty: #no_reply). Other turns'
    #   replies and ends are not its, and a pending question counts only
    #   when it is that turn's (#own_question?). A last_turn that ended
    #   before the baseline's (the turn whose continue offer was just
    #   answered) is not the end. An input a running turn merged as a
    #   steer (taken, never run as its own) is waited for as without turn:
    #   (that turn's reply or question). A turn seen running, then past
    #   (another turn runs or ended, last_turn not it): :no_reply, outcome
    #   unknown.
    # @param queued [Boolean] the turn: input was sent as a queue (or with
    #   images), which a running turn never merges: no fallback, even when
    #   its file was taken before the first look
    # @param ended_before [Boolean] a last_turn that ended before the
    #   baseline (chi send --wait with no message, on a session that went
    #   idle in the gap between waits) is the turn's end too: with the
    #   session idle and its last_turn still the baseline's, its end is
    #   the answer — its reply, or its no-reply outcome. Its reply file
    #   sorts at the cursor, not past it, and its end precedes the
    #   baseline, so without it the wait would time out "running" again.
    #   Not for a turn: wait (chi answer) whose own end it waits for.
    # @return [Result]
    # @raise [ArgumentError] no such session
    def call(id, state_dir:, cursor:, timeout: nil, poll_interval: POLL_INTERVAL, cancelled: -> { false },
             baseline: nil, owner_grace: nil, interject: nil, turn: nil, queued: false, ended_before: false)
      deadline = timeout && (monotonic + timeout.to_f)
      seen_running = false
      gone_since = nil
      turn = turn.to_s.empty? ? nil : turn.to_s
      session_dir = Session.session_dir(id, state_dir: state_dir) if turn
      # Whether the turn's input file has been taken (latched): looked at
      # before each load, so a running session seen after it is that turn
      # or a later one, never the turn that ran when the message was sent.
      claimed = false
      # Its input runs a turn of its own (a queue, images: +queued+, or seen
      # waiting as one): never merged into another turn.
      own_turn_input = queued
      # The turn was seen running (its mark's id), and last_turn's ended_at
      # then: a later end that isn't its is a turn after it.
      seen_own = false
      own_base = nil

      loop do
        if turn && !claimed
          waiting = SessionInbox.waiting_input(session_dir, turn)
          own_turn_input ||= waiting == :turn_end
          claimed = waiting.nil?
        end
        session = Session.load(id, state_dir: state_dir)
        # Taken back before it ran (POST turn/dequeue): no turn will come.
        # A tombstone with the claimed file still there is a removal not
        # done yet (or one a turn's claim beat): looked at again next poll.
        # One whose turn ran anyway (its reply, or last_turn its own) is a
        # stray: a worker killed between the tombstone and the claim left
        # it, or a short turn won the claim and ended before the removal
        # took it back.
        if turn && claimed && !seen_own && SessionInbox.removed?(session_dir, turn) &&
           !SessionInbox.claimed_input?(session_dir, turn) &&
           session.last_turn&.enqueued_id != turn && !SessionInbox.reply_for(session_dir, turn)
          return Result.new(status: :no_reply, outcome: "removed", session: session)
        end

        if turn && !seen_own && session.status == Session::STATUS_RUNNING && session.interrupted_turn&.enqueued_id == turn
          seen_own = true
          own_base = session.last_turn&.ended_at
        end
        # Taken but never run as a turn of its own: a running turn's drain
        # merged it as a steer, so that turn's reply (or question) is its
        # answer. Waited for as the next reply past the cursor, as without
        # turn:, never as a turn that will not come.
        if turn && claimed && !seen_own && !own_turn_input && merged_elsewhere?(session, turn, baseline, session_dir)
          turn = nil
          seen_running = session.status == Session::STATUS_RUNNING
        end

        if (reply = turn ? reply_for_turn(id, state_dir: state_dir, turn: turn) : reply_past(id, state_dir: state_dir, cursor: cursor))
          reply.session = settled(session, id, state_dir: state_dir)
          return reply
        end
        # Its worker died in it and the next one settled it, or an input
        # command finished without a turn. After the reply check: a worker
        # killed between writing the reply and its idle save left the reply.
        if turn && (settled = TurnCheckpoint.settled_turn(session_dir, turn))
          return Result.new(status: :no_reply, outcome: settled.outcome, session: session, origin: settled.origin,
                            **settled.stop_facts)
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
        if pending && !baseline&.question?(pending.id) &&
           (turn.nil? || own_question?(session, turn, claimed)) &&
           session.waiting_question(live: SessionManager.worker_live?(id, state_dir: state_dir))
          return Result.new(status: :waiting_for_answer, question: pending, session: session)
        end

        return Result.new(status: :canceled) if cancelled.call

        # The turn that ended before this wait (ended_before: chi send
        # --wait with no message, on a session that went idle in the gap
        # between waits): its last_turn still stands, the session is idle,
        # so its end is the answer, not a wait that times out "running"
        # again. Its reply file sorts at the cursor (the newest), not past
        # it: it is the turn's when it is at least as new as the turn's
        # end (the worker writes it after recording the ended_at), else the
        # turn left no reply and an earlier turn's file is not its.
        if ended_before && turn.nil? && session.status == Session::STATUS_IDLE &&
           (ended = session.last_turn&.ended_at) && !ended.to_s.empty? && baseline&.ended_at?(ended)
          file = newest_reply(id, state_dir: state_dir)
          path = File.join(reply_dir(id, state_dir: state_dir), file) if file
          if file && reply_is_turns?(path, ended)
            reply = Result.new(status: :done, text: File.read(path), file: file)
            reply.session = settled(session, id, state_dir: state_dir)
            return reply
          end

          return no_reply(session, baseline, fresh: true)
        end

        if ended_before && turn && session.last_turn&.enqueued_id == turn &&
           !(session.status == Session::STATUS_RUNNING && session.interrupted_turn&.enqueued_id == turn) &&
           (ended = session.last_turn&.ended_at) && !ended.to_s.empty? && baseline&.ended_at?(ended)
          # The turn-specific reply lookup above already found its file, if
          # one exists. Without it, don't use the newest file as a fallback:
          # it could belong to another turn.
          return no_reply(session, baseline, fresh: true)
        end

        if turn
          # Only the turn's own end: the session runs another turn when the
          # wait starts, and that one's end is not the answer. A last_turn
          # with its id is its end, even with a next queued turn running
          # by now (the look between the two missed the idle).
          # Only an end after the baseline: a continue offer answered from
          # idle leaves the exhausted turn's last_turn, with the same id,
          # until the continue turn (or a Stop) records its own.
          if session.last_turn&.enqueued_id == turn && ended_since_baseline?(session, baseline)
            return reply_for_turn(id, state_dir: state_dir, turn: turn)&.tap { |r| r.session = session } ||
                   no_reply(session, baseline, fresh: true)
          end
          # Seen running, and now another turn runs or a later turn ended
          # while last_turn (looked at first) isn't its: lost (its worker
          # died), or it ended with no reply and a next turn ran and ended
          # between two looks. Waiting on would sit through those turns.
          return Result.new(status: :no_reply, session: session) if seen_own && past_own?(session, turn, own_base)
        elsif session.status == Session::STATUS_RUNNING
          seen_running = true
        elsif (seen_running && baseline.nil?) || turn_ended_since?(session, baseline)
          # It ran and is idle again with no new reply: canceled, failed or
          # empty. Before it was ever seen running, idle means a
          # file-delivered message its worker has not picked up yet. With
          # a baseline only a turn that ended since counts:
          # a session left running by a worker that died goes idle when the
          # next worker settles that turn (TurnCheckpoint.settle), before
          # the sent message's turn runs.
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
    # @return [Baseline]
    def baseline_of(session, question_id: session.pending_question&.id)
      Baseline.new(messages: session.messages.size, question_id: question_id, last_turn: session.last_turn&.ended_at)
    end

    # A session whose turn ended after the baseline was taken (Baseline#
    # turn_ended_since?); false with no baseline.
    def turn_ended_since?(session, baseline) = baseline ? baseline.turn_ended_since?(session) : false

    # The turn a caller that sent nothing means (chi answer, chi send --wait
    # with no message): the one running now (its checkpoint mark's
    # enqueued_id), or, idle, the turn whose continue offer stands (its
    # last_turn's), when the worker's sidecar says it ties a continue turn
    # to that id (TURN_IDS_FEATURE). nil otherwise (no id known, a worker
    # from before): the caller waits for the next reply as before.
    # @param session [Session] the session as loaded now
    # @return [String, nil] an enqueued_id for call's turn:
    def own_turn(session, session_dir:)
      if session.status == Session::STATUS_RUNNING
        # Only a worker that writes it has one: no feature check.
        return session.interrupted_turn&.enqueued_id
      end

      pending = session.pending_question
      return nil unless pending && pending.kind.to_s == "continue"
      return nil unless turn_ids?(session_dir)

      session.last_turn&.enqueued_id
    end

    # Whether +turn+ is a turn the caller can wait for: running now, queued
    # as its own turn, or the last one to have ended.
    def known_turn?(session, session_dir:, turn:)
      id = turn.to_s
      return false if id.empty?

      running = session.status == Session::STATUS_RUNNING && session.interrupted_turn&.enqueued_id == id
      queued = SessionInbox.waiting_input(session_dir, id) == :turn_end
      ended = session.last_turn&.enqueued_id == id || !TurnCheckpoint.settled_turn(session_dir, id).nil?
      running || queued || ended
    end

    # Whether the session's worker sidecar names TURN_IDS_FEATURE.
    def turn_ids?(session_dir)
      WorkerSidecar.read(session_dir)&.features&.include?(TURN_IDS_FEATURE) || false
    end

    # A pending question is a turn: wait's (its enqueued_id) only when that
    # turn asked it. While a turn runs its checkpoint mark says which turn
    # that is (a continue turn carries its offer turn's id); a mark with no
    # id (a worker from before) falls back to the claimed rule (its input
    # claimed, the session running, last_turn not already it). Idle: only
    # its own continue offer (last_turn has the id). Any other is another
    # turn's, whose questions are the user's: the wait goes on.
    def own_question?(session, turn, claimed)
      ended = session.last_turn&.enqueued_id == turn
      return ended unless session.status == Session::STATUS_RUNNING

      running_id = session.interrupted_turn&.enqueued_id
      return running_id == turn if running_id

      # Ended, running again: a next turn.
      !ended && claimed
    end

    # The turn's end, after the baseline was taken (with no baseline, any).
    def ended_since_baseline?(session, baseline)
      return true unless baseline

      !baseline.ended_at?(session.last_turn&.ended_at)
    end

    # A turn: wait's taken input ran in another turn (a steer its drain
    # merged): that turn runs (its mark has another id, or none from a
    # worker that writes ids), or, idle, a turn not its ended since the
    # baseline. last_turn or a reply file being its own is never that, nor
    # an input with a tombstone (a removal's, written before its claim).
    def merged_elsewhere?(session, turn, baseline, session_dir)
      return false if session.last_turn&.enqueued_id == turn || SessionInbox.reply_for(session_dir, turn)
      return false if SessionInbox.removed?(session_dir, turn)

      if session.status == Session::STATUS_RUNNING
        running_id = session.interrupted_turn&.enqueued_id
        return running_id != turn if running_id

        return turn_ids?(session_dir)
      end
      turn_ended_since?(session, baseline)
    end

    # A turn seen running (+own_base+: last_turn's ended_at then) is past:
    # last_turn isn't its, and another turn runs (a mark with another id)
    # or a turn ended since.
    def past_own?(session, turn, own_base)
      return false if session.last_turn&.enqueued_id == turn

      running_id = session.status == Session::STATUS_RUNNING ? session.interrupted_turn&.enqueued_id : nil
      return true if running_id && running_id != turn

      ended = session.last_turn&.ended_at
      !ended.nil? && ended != own_base
    end

    # @return [Result, nil] :done with the reply of the turn that ran the
    #   input +turn+ (its enqueued_id)
    def reply_for_turn(id, state_dir:, turn:)
      file = SessionInbox.reply_for(Session.session_dir(id, state_dir: state_dir), turn)
      return nil unless file

      Result.new(status: :done, text: File.read(File.join(reply_dir(id, state_dir: state_dir), file)), file: file)
    end

    # @param fresh [Boolean, nil] the last_turn is known to be the turn
    #   waited for (a turn: wait); nil decides it from the baseline
    # @return [Result] :no_reply with the outcome the session's last_turn
    #   records, when it is the turn waited for
    def no_reply(session, baseline, fresh: nil)
      last = session.last_turn || LastTurn.new
      fresh = baseline.nil? || (last.ended_at && !baseline.ended_at?(last.ended_at)) if fresh.nil?
      outcome = fresh ? last.outcome : nil
      return Result.new(status: :no_reply, outcome: "exhausted", limit: last.limit, session: session) if fresh && last.exhausted

      text = outcome == "failed" ? TurnNote.failure_summary(session.messages) : nil
      # Every stop fact the turn has: Result takes them by name.
      why = fresh ? last.stop_facts : {}
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

      before = session.last_turn&.ended_at
      deadline = monotonic + SETTLE_SECONDS
      loop do
        sleep(0.02)
        fresh = Session.load(id, state_dir: state_dir)
        ended = fresh.last_turn&.ended_at
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

    # Whether the reply file at +path+ is the turn that ended at +ended_at+'s,
    # not an earlier turn's: the worker records ended_at before writing the
    # reply, so its mtime is at least the turn's end and earlier replies'
    # mtimes precede it. Unlike the filename, mtime is independent of TZ.
    def reply_is_turns?(path, ended_at)
      File.mtime(path) >= Time.parse(ended_at.to_s)
    rescue ArgumentError, SystemCallError
      false
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
