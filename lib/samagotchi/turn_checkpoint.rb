# frozen_string_literal: true

require "time"
require_relative "interrupted_turn"
require_relative "log"
require_relative "steer"

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
    end

    # A turn begins (before Engine#run_turn and the worker's running save):
    # the overlay starts as the history plus +prompt+ (text only: no
    # images, no turn id), marked at iteration 0, so a worker killed before
    # the loop's first boundary leaves the prompt and a mark the next one
    # settles. A continue turn (no prompt) is the history, marked.
    # @param prompt [String, nil]
    def begin_turn(prompt: nil)
      @boundaries = 0
      @written_at = nil
      @started_at = Time.now.iso8601(3)
      messages = Array(@session.messages).dup
      messages << { role: "user", content: prompt } unless prompt.to_s.empty?
      @session.turn_checkpoint = { messages: messages, marker: InterruptedTurn.new(started_at: @started_at, at: @started_at, iteration: 0) }
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
      marker = InterruptedTurn.new(id: turn_id, started_at: @started_at, at: Time.now.iso8601(3), iteration: @boundaries)
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
