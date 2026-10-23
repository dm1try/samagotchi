# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "atomic_file"
require_relative "interrupted_turn"
require_relative "last_turn"
require_relative "log"
require_relative "session"
require_relative "session_inbox"
require_relative "steer"
require_relative "turn_note"

module Samagotchi
  # A worker's running turn, kept on disk at the loop's iteration
  # boundaries, so a worker killed mid-turn (SIGKILL, a crash of the
  # process) loses at most INTERVAL seconds of it instead of all of it.
  #
  # At each boundary (Worker#pending_input_drain, on the turn's thread) the
  # turn's live conversation (Engine#live_conversation) is copied, with the
  # lines that boundary merges (their input files are deleted as they are
  # claimed), into the session's overlay (Session#turn_checkpoint), marked
  # with an InterruptedTurn. Every save while the turn runs writes the
  # overlay instead of the session's messages: this one's, written at the
  # first boundary (the prompt reaches the disk) and then at most every
  # INTERVAL (or when the boundary merged input), and any other save in the
  # turn (a question asked). The session's in-memory messages never change
  # (a Bridge snapshot shows the turn in progress or in the messages, never
  # both). The turn's end saves the real messages without a marker.
  #
  # The copy is what a Stop at that boundary would keep, minus its note, so
  # the history before the turn is never rewritten (prompt caching); later
  # steps of the same turn may still edit their own entries in place.
  class TurnCheckpoint
    INTERVAL = 10.0

    # A session loaded with an InterruptedTurn mark (its worker died in the
    # turn): the turn ends now, as canceled. Its note goes at the tail
    # (append-only: the model reads on its next turn that the previous one
    # was cut, after how long), the status goes idle and the mark goes. The
    # dead turn is not run again. The caller saves.
    #
    # last_turn is left as it was: a new last_turn saved idle here, before
    # the turn a `chi send --wait` started this worker for, would end that
    # wait at once as the sent turn's (ReplyWait compares last_turn), with
    # the dead turn's outcome. A mark with an enqueued_id records the dead
    # turn's end under that id instead (+session_dir+, #settled_turn): only
    # a wait for that very turn (ReplyWait's turn:) reads it.
    # @param session_dir [String, nil] where to record it; nil: nowhere
    # @return [InterruptedTurn, nil] the mark settled, nil when there was none
    def self.settle(session, session_dir: nil)
      mark = session.interrupted_turn
      return nil unless mark

      messages = Array(session.messages)
      # How long it ran up to its last checkpoint (it died later); none
      # when that was its first boundary ("after 0s" would mislead).
      seconds = mark.seconds
      seconds = nil if seconds && seconds < 1
      note = TurnNote.cancelled(:worker_stopped, seconds: seconds, shown: TurnNote.interrupted_tail?(messages))
      session.messages = messages + [note]
      session.status = Session::STATUS_IDLE if session.status == Session::STATUS_RUNNING
      session.interrupted_turn = nil
      record_settled(session_dir, mark, seconds) if session_dir
      mark
    end

    # Where a per-input terminal outcome is kept: input/settled/<enqueued_id>,
    # outside the *.json glob like SessionInbox's removed tombstones.
    SETTLED_DIR = "settled"
    WORKER_STOPPED = "worker_stopped"

    # The terminal outcome recorded for +enqueued_id+.
    # @return [LastTurn, nil] nil when no settle recorded one
    def self.settled_turn(session_dir, enqueued_id)
      id = enqueued_id.to_s
      return nil unless SessionInbox::ENQUEUED_ID_NAME.match?(id)

      raw = File.read(File.join(session_dir, SessionInbox::INPUT_DIR, SETTLED_DIR, id))
      LastTurn.from_file(JSON.parse(raw)) || settled_record(id)
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    rescue JSON::ParserError, SystemCallError
      # The file says the turn was settled even when it can't be read.
      settled_record(id)
    end

    # The settled outcomes past +max_age+ (SessionInbox.prune_old).
    # @return [Integer] how many went
    def self.prune_settled(session_dir, max_age: SessionInbox::TOMBSTONE_MAX_AGE)
      SessionInbox.prune_old(session_dir, SETTLED_DIR, max_age: max_age)
    end

    def self.settled_record(id, ended_at: nil, seconds: nil)
      LastTurn.new(outcome: "canceled", cancel_reason: WORKER_STOPPED, ended_at: ended_at, seconds: seconds, enqueued_id: id)
    end
    private_class_method :settled_record

    # A command's status (its command_ran's) as a settled outcome; any
    # other status (busy, dropped) is a cancel for that reason.
    COMMAND_OUTCOMES = { "ok" => "completed", "error" => "failed" }.freeze
    # Its record's origin: no turn ran (ParentReport says "the command").
    COMMAND_ORIGIN = "command"

    # A file-delivered command ends its sender's wait without running a
    # turn. Keep a terminal outcome under the same per-input settled path:
    # +status+ is its command_ran's ("ok", "error", "busy", "dropped" at a
    # teardown), so the wait reads completed, failed, or canceled with that
    # reason.
    def self.record_command_outcome(session_dir, enqueued_id, status:)
      id = enqueued_id.to_s
      return if id.empty? || !SessionInbox::ENQUEUED_ID_NAME.match?(id)

      outcome = COMMAND_OUTCOMES.fetch(status.to_s, "canceled")
      record = LastTurn.new(outcome: outcome, cancel_reason: (status.to_s if outcome == "canceled"),
                            ended_at: Time.now.iso8601(3), origin: COMMAND_ORIGIN, enqueued_id: id)
      write_settled(session_dir, id, record)
    rescue SystemCallError, IOError => e
      Log.warn(:worker, "command_outcome_write_failed", error: e.class.name, msg: e.message, enqueued_id: id)
    end

    # A participant's queued turn the worker refused (Worker#refuse_participant_turn:
    # +reason+ revoked or cap_reached) ends its sender's wait: no turn ran,
    # canceled for that reason (ParentReport reads it as refused).
    def self.record_refused(session_dir, enqueued_id, reason:)
      id = enqueued_id.to_s
      return unless SessionInbox::ENQUEUED_ID_NAME.match?(id)

      write_settled(session_dir, id, LastTurn.new(outcome: "canceled", cancel_reason: reason.to_s,
                                                  ended_at: Time.now.iso8601(3), enqueued_id: id))
    rescue SystemCallError, IOError => e
      Log.warn(:worker, "refused_turn_write_failed", error: e.class.name, msg: e.message, enqueued_id: id)
    end

    def self.record_settled(session_dir, mark, seconds)
      id = mark.enqueued_id.to_s
      return unless SessionInbox::ENQUEUED_ID_NAME.match?(id)

      write_settled(session_dir, id, settled_record(id, ended_at: Time.now.iso8601(3), seconds: seconds))
    rescue SystemCallError => e
      # The settle goes on; a wait for that turn runs to its timeout.
      Log.warn(:worker, "settled_turn_write_failed", error: e.class.name, msg: e.message)
    end

    def self.write_settled(session_dir, id, record)
      dir = File.join(session_dir, SessionInbox::INPUT_DIR, SETTLED_DIR)
      FileUtils.mkdir_p(dir)
      AtomicFile.write(File.join(dir, id), JSON.generate(record.to_file))
    end
    private_class_method :write_settled
    private_class_method :record_settled

    # @param session [Session] the worker's session (saved as a whole)
    # @param clock [#call] monotonic seconds (specs)
    def initialize(session:, state_dir:, interval: INTERVAL, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @session = session
      @state_dir = state_dir
      @interval = interval
      @clock = clock
      @boundaries = 0
      @written_at = nil
      @started_at = nil
      @enqueued_id = nil
    end

    # A turn begins (before Engine#run_turn and the worker's running save):
    # the overlay starts as the history plus +prompt+ (text only: no
    # images, no turn id), marked at iteration 0, so a worker killed before
    # the loop's first boundary leaves the prompt and a mark the next one
    # settles. A continue turn (no prompt) is the history, marked.
    # Every mark of the turn carries +enqueued_id+ (InterruptedTurn's).
    # @param prompt [String, nil]
    # @param enqueued_id [String, nil] the input the turn runs
    # @param author [Hash] a participant's prompt's author fields
    #   (Engine#author_fields), so a kill before the first boundary leaves
    #   it theirs; {} for the owner's
    def begin_turn(prompt: nil, enqueued_id: nil, author: {})
      @boundaries = 0
      @enqueued_id = enqueued_id.to_s.empty? ? nil : enqueued_id.to_s
      @written_at = nil
      @started_at = Time.now.iso8601(3)
      messages = Array(@session.messages).dup
      messages << { role: "user", content: prompt, **author } unless prompt.to_s.empty?
      @session.turn_checkpoint = { messages: messages, marker: InterruptedTurn.new(started_at: @started_at, at: @started_at, iteration: 0,
                                                                                   enqueued_id: @enqueued_id) }
    end

    # The turn ended (or never began): the session saves its own messages.
    def end_turn
      @session.turn_checkpoint = nil
    end

    # An iteration boundary of the running turn.
    # @param conversation [Array<Hash>, nil] the loop's live conversation;
    #   nil (no turn): nothing
    # @param merging [Array<Steer::Line>] the lines this boundary merges
    #   (appended after the conversation, as Steer.inject! will)
    # @param turn_id [String, nil]
    # @return [Boolean] whether the session file was written
    def boundary(conversation, merging: [], turn_id: nil)
      return false unless conversation

      @boundaries += 1
      merged = merging.empty? ? [] : Steer.merge(merging).messages
      # One level deep: the loop may edit an entry in place later (a
      # forget stub) while a save on another thread serializes this one.
      messages = conversation.map { |message| message.is_a?(Hash) ? message.dup : message } + merged
      marker = InterruptedTurn.new(id: turn_id, started_at: @started_at, at: Time.now.iso8601(3), iteration: @boundaries,
                                   enqueued_id: @enqueued_id)
      @session.turn_checkpoint = { messages: messages, marker: marker }
      return false unless due? || !merged.empty?

      write
    end

    private

    def due? = @written_at.nil? || @clock.call - @written_at >= @interval

    def write
      @session.save(state_dir: @state_dir)
      @written_at = @clock.call
      true
    rescue StandardError => e
      # The turn goes on; the next boundary tries again.
      Log.warn(:worker, "checkpoint_failed", error: e.class.name, msg: e.message)
      false
    end
  end
end
