# frozen_string_literal: true

require_relative "config"
require_relative "log"
require_relative "child_reports"

module Samagotchi
  # A worker's wake budget: turns nobody typed (a delegate report's wake
  # turn, an attached context source's) run only past the start grace, at
  # most session.max_wakes in a row with no human input, and not after a
  # failed one until a human's input (a provider outage doesn't loop).
  # Shared by both kinds of wake; the Worker asks it before each and tells
  # it what happened. It also holds the reports a delegate wake turn was
  # started for until the turn's first boundary takes them (#hand_over,
  # #take_handed).
  class WorkerWakes
    # @param grace [Numeric] seconds after the start with no wake turn
    # @param clock [#call] monotonic seconds
    # @param max [#call, nil] the budget; nil reads session.max_wakes
    def initialize(grace:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, max: nil)
      @grace = grace
      @clock = clock
      @max = max
      @started_at = clock.call
      @in_a_row = 0
      @paused = false
      @budget_noticed = false
      @handed = nil
    end

    # Wake turns run since the last human input.
    attr_reader :in_a_row

    def paused? = @paused

    def grace_left = @grace - (@clock.call - @started_at)

    def in_grace? = grace_left.positive?

    def max
      return @max.call if @max

      value = Integer(Config.get(ChildRing::MAX_WAKES_KEY), exception: false)
      value&.positive? ? value : ChildRing::MAX_WAKES_DEFAULT
    rescue StandardError
      ChildRing::MAX_WAKES_DEFAULT
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

    # A wake turn starts. @return [Integer] the wake turns in a row now
    def count! = @in_a_row += 1

    # A wake turn failed: none starts again until a human's input.
    def pause!
      @paused = true
    end

    # A human's input resets the budget, the pause and the budget notice.
    def human_input!
      @in_a_row = 0
      @paused = false
      @budget_noticed = false
    end

    # @return [Boolean] true the first time the budget is spent since the
    #   last human input: the UIs hear it once
    def notice_budget!
      return false if @budget_noticed

      @budget_noticed = true
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
