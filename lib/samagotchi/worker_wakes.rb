# frozen_string_literal: true

require_relative "config"
require_relative "log"
require_relative "child_reports"

module Samagotchi
  # A worker's wake budget: turns nobody typed (a delegate report's wake
  # turn, a finished background task's, an attached context source's) run
  # only past the start grace, at most session.max_wakes in a row with no
  # human input, and not after a failed one until a human's input (a
  # provider outage doesn't loop). Shared by every kind of wake; the Worker asks it before each and tells
  # it what happened. It also holds the reports a delegate wake turn was
  # started for until the turn's first boundary takes them (#hand_over,
  # #take_handed).
  #
  # A peer agent's answers (PeerSources) have a budget of their own on top:
  # context.peer_turns wake turns in a row, reset only by input typed in the
  # web or a TUI (ClientId.interactive?), not by chi send, which a peer can
  # run (docs/context.md, Waking).
  class WorkerWakes
    PEER_TURNS_KEY = "context.peer_turns"
    PEER_TURNS_DEFAULT = 3

    # @param grace [Numeric] seconds after the start with no wake turn
    # @param clock [#call] monotonic seconds
    # @param max [#call, nil] the budget; nil reads session.max_wakes
    # @param peer_max [#call, nil] the peer budget; nil reads context.peer_turns
    def initialize(grace:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, max: nil, peer_max: nil)
      @grace = grace
      @clock = clock
      @max = max
      @peer_max = peer_max
      @started_at = clock.call
      @in_a_row = 0
      @peer_in_a_row = 0
      @paused = false
      @budget_noticed = false
      @peer_noticed = false
      @handed = nil
    end

    # Wake turns run since the last human input; peer wake turns since the
    # last interactive one.
    attr_reader :in_a_row, :peer_in_a_row

    def grace_left = @grace - (@clock.call - @started_at)

    def in_grace? = grace_left.positive?

    def max
      return @max.call if @max

      value = Integer(Config.get(ChildRing::MAX_WAKES_KEY), exception: false)
      value&.positive? ? value : ChildRing::MAX_WAKES_DEFAULT
    rescue StandardError
      ChildRing::MAX_WAKES_DEFAULT
    end

    # context.peer_turns: 0 (or less) is 0, the peer policy off.
    def peer_max
      return @peer_max.call if @peer_max

      value = Integer(Config.get(PEER_TURNS_KEY), exception: false)
      value ? [value, 0].max : PEER_TURNS_DEFAULT
    rescue StandardError
      PEER_TURNS_DEFAULT
    end

    # The peer wake turns that may run in a row: context.peer_turns, or
    # session.max_wakes when it is lower; 0 when the peer policy is off.
    def peer_turns
      peers = peer_max
      peers.zero? ? 0 : [peers, max].min
    end

    # Whether session.max_wakes holds wake turns now.
    def spent? = @in_a_row >= max

    # Whether a peer's answer may start a wake turn by the peer budget
    # (#context_open? asked first). +name+: the source, for the log line.
    def peer_open?(name:)
      return true if @peer_in_a_row < peer_turns

      Log.info(:worker, "context_wake_held", reason: "peer_turns", names: name)
      false
    end

    # For delegate reports: :due when a wake turn may run now (the block
    # says reports wait; asked only when nothing else holds), :budget when
    # only the budget stops it, nil otherwise. The start grace is the
    # caller's (it shortens the idle sleep instead).
    def delegate_state(awaiting_continue:)
      return nil if @paused || awaiting_continue
      return nil unless yield

      @in_a_row < max ? :due : :budget
    end

    # For an attached context source asking to wake: no continue offer,
    # not paused, past the start grace and under the budget. +names+: the
    # sources asking, for the log line when the budget holds them.
    def context_open?(awaiting_continue:, names:)
      return false if @paused || awaiting_continue || in_grace?

      if @in_a_row >= max
        Log.info(:worker, "context_wake_held", reason: "max_wakes", names: names.join(","))
        return false
      end
      true
    end

    # For a background task that finished unseen (TaskWatch): no continue
    # offer, not paused, past the start grace and under the budget. #count!
    # when its wake turn starts.
    def task_open?(awaiting_continue:)
      !@paused && !awaiting_continue && !in_grace? && @in_a_row < max
    end

    # Whether wakes are paused (a failed wake turn) until a human's input.
    def paused? = @paused

    # A wake turn starts; +peer+: for a peer's answer, which counts toward
    # both budgets. @return [Integer] the wake turns in a row now
    def count!(peer: false)
      @peer_in_a_row += 1 if peer
      @in_a_row += 1
    end

    # A wake turn failed (or was stopped before it got anywhere): none
    # starts again until a human's input.
    def pause!
      @paused = true
    end

    # A human's input resets the budget, the pause and the budget notice;
    # an +interactive+ one (ClientId.interactive?: the web, a TUI) the peer
    # budget and its notice too. chi send isn't: a peer can run it.
    def human_input!(interactive: true)
      @in_a_row = 0
      @paused = false
      @budget_noticed = false
      return unless interactive

      @peer_in_a_row = 0
      @peer_noticed = false
    end

    # @return [Boolean] true the first time the budget is spent since the
    #   last human input: the UIs hear it once
    def notice_budget!
      return false if @budget_noticed

      @budget_noticed = true
    end

    # @return [Boolean] true the first time a peer's answer is held since
    #   the last interactive input: the UIs hear it once
    def notice_peer_budget!
      return false if @peer_noticed

      @peer_noticed = true
    end

    # The idle loop's sleep: +poll+, or less while a wake (the block says
    # one is due) waits out the start grace.
    def idle_wait(poll)
      left = grace_left
      left.positive? && yield ? [left, poll].min : poll
    end

    # The reports a delegate wake turn runs for, until its first boundary
    # takes them (#take_handed); #drop_handed when the turn is over.
    def hand_over(reports)
      @handed = reports
    end

    # @return [Array, nil] the handed reports, once
    def take_handed
      reports = @handed
      @handed = nil
      reports
    end

    def drop_handed
      @handed = nil
    end
  end
end
