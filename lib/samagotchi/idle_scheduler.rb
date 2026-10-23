# frozen_string_literal: true

require "monitor"
require_relative "log"

module Samagotchi
  # Shared background poller for all Engine-owned idle subsystems
  # (currently: IdleReminders and the optional IdleRecap).
  #
  # Previously each subsystem ran its own 0.5s polling thread against the
  # Engine's `last_activity_at` / `activity_seq` / `turn_running?` seam.
  # Now a single thread steps every registered job in turn, so the whole
  # idle layer polls the Engine seam from one loop.
  #
  # Jobs must implement `tick`. Each job keeps its own eligibility guard
  # (e.g. `should_fire?` / `should_check?`, including the `turn_running?`
  # check) and its own internal state (generation ids, latches). A job that
  # raises is logged and isolated — the remaining jobs keep polling.
  class IdleScheduler
    POLL_INTERVAL_SECONDS = 0.5
    # How long #stop waits for the thread to finish its tick before it
    # kills it.
    STOP_JOIN_SECONDS = 1.0
    THREAD_NAME = "idle_scheduler"

    attr_reader :engine, :jobs, :interval

    # +interval+: the pause between ticks (a spec passes a long one, so its
    # own #tick is the only one after the first).
    def initialize(engine:, jobs: [], interval: POLL_INTERVAL_SECONDS)
      raise ArgumentError, "IdleScheduler requires an engine" unless engine

      @engine = engine
      @jobs = jobs.compact.freeze
      @interval = interval
      # The loop's pause: a pop with the interval as its timeout, which
      # #stop ends at once by pushing.
      @wake = Queue.new
      @thread = nil
      # The thread a stop(join: false) left to finish its tick.
      @unjoined = nil
      @stopped = false
    end

    # Spawn the polling thread (idempotent; no-op when there are no jobs).
    # A stopped scheduler doesn't start again.
    def start
      return self if running? || @jobs.empty?

      @thread = Thread.new { run_loop }
      @thread.name = THREAD_NAME
      self
    end

    def running?
      !@thread.nil? && @thread.alive? && !@stopped
    end

    # Stop the polling thread (idempotent): it ticks no more and its pause
    # ends at once. +join+: wait up to STOP_JOIN_SECONDS for a tick under
    # way to finish, then kill the thread. A caller holding a lock a tick
    # may take (Worker#leave_idle holds the event log, which a recap's emit
    # takes) passes join: false: the thread finishes its tick and exits by
    # itself, and a later joining stop (Engine#shutdown, the worker's
    # teardown) still joins it. From the scheduler's own thread (a job's
    # tick) it never joins.
    def stop(join: true)
      @stopped = true
      @wake << :stop
      thread = @thread || @unjoined
      @thread = nil
      @unjoined = join ? nil : thread
      return if thread.nil? || !join || thread == Thread.current

      thread.kill unless thread.join(STOP_JOIN_SECONDS)
      nil
    end

    # Swap the job +old+ for +new+ (Engine#session= rebuilding the recap):
    # nil +old+ adds +new+, nil +new+ drops +old+. The list is replaced
    # whole, so a tick on the thread steps the old list or the new one; a
    # running scheduler keeps its one thread, and one with no jobs yet
    # starts it once #start is called.
    def replace_job(old, new)
      jobs = if @jobs.any? { |job| job.equal?(old) }
               @jobs.map { |job| job.equal?(old) ? new : job }
             else
               @jobs + [new]
             end
      @jobs = jobs.compact.freeze
      self
    end

    # One step across all jobs. Public so specs can drive it deterministically.
    def tick
      return if @stopped

      @jobs.each do |job|
        job.tick
      rescue StandardError => e
        Log.exception(:idle, "tick_failed", e, echo: "[IdleScheduler] #{job.class} tick failed: #{e.class}: #{e.message}", job: job.class.name)
      end
    end

    private

    def run_loop
      until @stopped
        tick
        @wake.pop(timeout: @interval)
      end
    rescue StandardError => e
      Log.exception(:idle, "scheduler_crashed", e, echo: "[IdleScheduler] scheduler thread crashed: #{e.class}: #{e.message}")
    end
  end
end
