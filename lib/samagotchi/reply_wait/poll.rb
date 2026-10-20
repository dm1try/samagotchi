# frozen_string_literal: true

require_relative "../session"
require_relative "../session_inbox"
require_relative "../turn_checkpoint"

module Samagotchi
  module ReplyWait
    # One ReplyWait.call: what the wait learned so far (the turn's input
    # claimed, its turn seen running, any turn seen running, the worker
    # gone since) and one look at the session per poll. Each check returns
    # a Result that ends the wait, or nil to go on, in the order #look runs
    # them. ReplyWait.call's parameters say what each means.
    class Poll
      def initialize(id, state_dir:, cursor:, timeout:, poll_interval:, cancelled:, baseline:, owner_grace:, interject:,
                     turn:, queued:, ended_before:)
        @id = id
        @state_dir = state_dir
        @cursor = cursor
        @poll_interval = poll_interval
        @cancelled = cancelled
        @baseline = baseline
        @owner_grace = owner_grace
        @interject = interject
        @ended_before = ended_before
        @deadline = timeout && (ReplyWait.monotonic + timeout.to_f)
        @turn = turn.to_s.empty? ? nil : turn.to_s
        @session_dir = Session.session_dir(id, state_dir: state_dir) if @turn
        # Whether the turn's input file has been taken (latched): looked at
        # before each load, so a running session seen after it is that turn
        # or a later one, never the turn that ran when the message was sent.
        @claimed = false
        # Its input runs a turn of its own (a queue, images: +queued+, or
        # seen waiting as one): never merged into another turn.
        @own_turn_input = queued
        # The turn was seen running (its mark's id), and last_turn's
        # ended_at then: a later end that isn't its is a turn after it.
        @seen_own = false
        @own_base = nil
        @seen_running = false
        @gone_since = nil
      end

      # @return [Result]
      def run
        loop do
          result = look
          return result if result

          if @interject
            started = ReplyWait.monotonic
            @interject.call
            @deadline += ReplyWait.monotonic - started if @deadline
            next if @cancelled.call
          end
          sleep(@poll_interval)
        end
      end

      private

      # One poll: the input file, then the session as loaded now.
      # @return [Result, nil]
      def look
        look_at_input
        session = Session.load(@id, state_dir: @state_dir)
        if (result = removed(session))
          return result
        end

        note_own_running(session)
        follow_merge(session)
        reply(session) || settled_turn(session) || status_end(session) || question(session) || canceled ||
          ended_before_reply(session) || ended_before_turn(session) || turn_end(session) || owner_gone(session) ||
          timed_out
      end

      def look_at_input
        return unless @turn && !@claimed

        waiting = SessionInbox.waiting_input(@session_dir, @turn)
        @own_turn_input ||= waiting == :turn_end
        @claimed = waiting.nil?
      end

      # Taken back before it ran (POST turn/dequeue): no turn will come. A
      # tombstone with the claimed file still there is a removal not done
      # yet (or one a turn's claim beat): looked at again next poll. One
      # whose turn ran anyway (its reply, or last_turn its own) is a stray:
      # a worker killed between the tombstone and the claim left it, or a
      # short turn won the claim and ended before the removal took it back.
      def removed(session)
        return nil unless @turn && @claimed && !@seen_own && SessionInbox.removed?(@session_dir, @turn)
        return nil if SessionInbox.claimed_input?(@session_dir, @turn) || turn_ran?(session)

        Result.new(status: :no_reply, outcome: "removed", session: session)
      end

      def turn_ran?(session)
        session.last_turn&.enqueued_id == @turn || !SessionInbox.reply_for(@session_dir, @turn).nil?
      end

      def note_own_running(session)
        return unless @turn && !@seen_own && own_running?(session)

        @seen_own = true
        @own_base = session.last_turn&.ended_at
      end

      # Taken but never run as a turn of its own: a running turn's drain
      # merged it as a steer, so that turn's reply (or question) is its
      # answer. Waited for as the next reply past the cursor, as without
      # turn:, never as a turn that will not come.
      def follow_merge(session)
        return unless @turn && @claimed && !@seen_own && !@own_turn_input &&
                      ReplyWait.merged_elsewhere?(session, @turn, @baseline, @session_dir)

        @turn = nil
        @seen_running = running?(session)
      end

      def reply(session)
        reply = if @turn
                  ReplyWait.reply_for_turn(@id, state_dir: @state_dir, turn: @turn)
                else
                  ReplyWait.reply_past(@id, state_dir: @state_dir, cursor: @cursor)
                end
        return nil unless reply

        reply.session = ReplyWait.settled(session, @id, state_dir: @state_dir)
        reply
      end

      # Its worker died in it and the next one settled it, or an input
      # command finished without a turn. After the reply check: a worker
      # killed between writing the reply and its idle save left the reply.
      def settled_turn(session)
        settled = @turn && TurnCheckpoint.settled_turn(@session_dir, @turn)
        return nil unless settled

        Result.new(status: :no_reply, outcome: settled.outcome, session: session, origin: settled.origin,
                   **settled.stop_facts)
      end

      def status_end(session)
        case session.status
        when Session::STATUS_ERROR then Result.new(status: :error, text: session.last_prompt.to_s.strip, session: session)
        when Session::STATUS_STOPPED then Result.new(status: :stopped, session: session)
        end
      end

      # Only a question a live worker holds waits for an answer (the lists'
      # rule): one a dead worker left waits for no one, and a chi REPL's is
      # answered there.
      def question(session)
        pending = session.pending_question
        return nil unless pending && !@baseline&.question?(pending.id) &&
                          (@turn.nil? || ReplyWait.own_question?(session, @turn, @claimed)) &&
                          session.waiting_question(live: SessionManager.worker_live?(@id, state_dir: @state_dir))

        Result.new(status: :waiting_for_answer, question: pending, session: session)
      end

      def canceled = @cancelled.call ? Result.new(status: :canceled) : nil

      # The turn that ended before this wait (ended_before: chi send --wait
      # with no message, on a session that went idle in the gap between
      # waits): its last_turn still stands, the session is idle, so its end
      # is the answer, not a wait that times out "running" again. Its reply
      # file sorts at the cursor (the newest), not past it: it is the
      # turn's when it is at least as new as the turn's end (the worker
      # writes it after recording the ended_at), else the turn left no
      # reply and an earlier turn's file is not its.
      def ended_before_reply(session)
        return nil unless @ended_before && @turn.nil? && session.status == Session::STATUS_IDLE && baseline_end?(session)

        file = ReplyWait.newest_reply(@id, state_dir: @state_dir)
        path = File.join(ReplyWait.reply_dir(@id, state_dir: @state_dir), file) if file
        if file && ReplyWait.reply_is_turns?(path, session.last_turn.ended_at)
          reply = Result.new(status: :done, text: File.read(path), file: file)
          reply.session = ReplyWait.settled(session, @id, state_dir: @state_dir)
          return reply
        end

        ReplyWait.no_reply(session, @baseline, fresh: true)
      end

      # The same for a turn: wait whose turn is that last one (not running
      # again). The turn's own reply lookup (#reply) already found its file,
      # if one exists; without it the newest file is no fallback: it could
      # be another turn's.
      def ended_before_turn(session)
        return nil unless @ended_before && @turn && session.last_turn&.enqueued_id == @turn && !own_running?(session) &&
                          baseline_end?(session)

        ReplyWait.no_reply(session, @baseline, fresh: true)
      end

      def turn_end(session)
        return own_turn_end(session) if @turn

        if running?(session)
          @seen_running = true
          return nil
        end
        # It ran and is idle again with no new reply: canceled, failed or
        # empty. Before it was ever seen running, idle means a
        # file-delivered message its worker has not picked up yet. With a
        # baseline only a turn that ended since counts: a session left
        # running by a worker that died goes idle when the next worker
        # settles that turn (TurnCheckpoint.settle), before the sent
        # message's turn runs.
        return nil unless (@seen_running && @baseline.nil?) || ReplyWait.turn_ended_since?(session, @baseline)

        # The worker writes the reply before its idle save, so the read
        # above has it; one more look costs nothing should that change.
        ReplyWait.reply_past(@id, state_dir: @state_dir, cursor: @cursor)&.tap { |r| r.session = session } ||
          ReplyWait.no_reply(session, @baseline)
      end

      # Only the turn's own end: the session runs another turn when the
      # wait starts, and that one's end is not the answer. A last_turn with
      # its id is its end, even with a next queued turn running by now (the
      # look between the two missed the idle). Only an end after the
      # baseline: a continue offer answered from idle leaves the exhausted
      # turn's last_turn, with the same id, until the continue turn (or a
      # Stop) records its own.
      def own_turn_end(session)
        if session.last_turn&.enqueued_id == @turn && ReplyWait.ended_since_baseline?(session, @baseline)
          return ReplyWait.reply_for_turn(@id, state_dir: @state_dir, turn: @turn)&.tap { |r| r.session = session } ||
                 ReplyWait.no_reply(session, @baseline, fresh: true)
        end
        # Seen running, and now another turn runs or a later turn ended
        # while last_turn (looked at first) isn't its: lost (its worker
        # died), or it ended with no reply and a next turn ran and ended
        # between two looks. Waiting on would sit through those turns.
        return Result.new(status: :no_reply, session: session) if @seen_own && ReplyWait.past_own?(session, @turn, @own_base)

        nil
      end

      def owner_gone(session)
        return nil unless @owner_grace

        if SessionManager.session_owner(@id, state_dir: @state_dir)
          @gone_since = nil
        elsif ReplyWait.monotonic - (@gone_since ||= ReplyWait.monotonic) > @owner_grace
          return Result.new(status: :worker_gone, session: session)
        end
        nil
      end

      def timed_out = @deadline && ReplyWait.monotonic > @deadline ? Result.new(status: :timeout) : nil

      # Whether the session's last turn is the one that had ended at the
      # baseline (its ended_at set and unchanged).
      def baseline_end?(session)
        ended = session.last_turn&.ended_at
        (!ended.to_s.empty? && @baseline&.ended_at?(ended)) || false
      end

      def running?(session) = session.status == Session::STATUS_RUNNING

      def own_running?(session) = running?(session) && session.interrupted_turn&.enqueued_id == @turn
    end
  end
end
