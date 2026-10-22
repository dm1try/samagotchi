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

    attr_reader :engine, :jobs

    def initialize(engine:, jobs: [])
      raise ArgumentError, "IdleScheduler requires an engine" unless engine

      @engine = engine
      @jobs = jobs.compact.freeze
      @thread = nil
      @stopped = false
    end

    # Spawn the polling thread (idempotent; no-op when there are no jobs).
    def start
      return self if running? || @jobs.empty?

      @thread = Thread.new { run_loop }
      self
    end

    def running?
      !@thread.nil? && @thread.alive? && !@stopped
    end

    # Stop the polling thread (idempotent).
    def stop
      @stopped = true
      @thread&.kill
      @thread = nil
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
      loop do
        break if @stopped

        tick
        sleep(POLL_INTERVAL_SECONDS)
      end
    rescue StandardError => e
      Log.exception(:idle, "scheduler_crashed", e, echo: "[IdleScheduler] scheduler thread crashed: #{e.class}: #{e.message}")
    end
  end
end
