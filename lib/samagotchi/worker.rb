# frozen_string_literal: true

require "fileutils"

require_relative "session"
require_relative "worker_idle_exit"
require_relative "session_manager"

module Samagotchi
  # The loop of a background session worker, once it owns the session (see
  # SessionManager.run_session_loop, which takes the OwnerLock around #run).
  #
  # It runs the session's Engine and Bridge, takes queued prompts from the
  # input dir one turn at a time, and returns when nobody has used it for the
  # idle-exit timeout. A stop marked on disk exits the process; an error
  # outside the Engine's own handling marks the session and exits with 1.
  #
  # The file IPC stays behind SessionManager's class methods
  # (find_new_input_files, claim_input_file, start_bridge, ...), which specs
  # stub as seams.
  #
  # The loop sleeps on a Waker, which the Bridge wakes when it queues a turn
  # and the reminder callback when it queues one. A fallback tick picks up
  # input written by another process (the web's write_turn_input fallback)
  # and runs the stop-on-disk and idle-exit checks.
  class Worker
    FALLBACK_TICK_SECONDS = 5

    # Wakes the worker loop. Whoever queues work writes it first and wakes
    # after, and #wait drains every wake before the loop looks for work: a
    # wake drained with the others was for work the loop is about to see,
    # and one that comes later stays queued for the next #wait. So no wake is
    # lost, and a burst of them costs one pass.
    class Waker
      def initialize
        @queue = Thread::Queue.new
      end

      def wake
        @queue << true
        nil
      end

      # @return [Boolean] true when woken, false when the timeout passed
      def wait(timeout)
        woken = !@queue.pop(timeout: timeout).nil?
        @queue.clear
        woken
      end
    end

    # @param idle_exit_minutes [Numeric, nil] nil: session.idle_exit_minutes
    # @param poll_interval [Numeric, nil] seconds between fallback ticks
    def initialize(session_id:, state_dir:, session_dir:, idle_exit_minutes: nil, poll_interval: nil)
      @session_id = session_id
      @state_dir = state_dir
      @session_dir = session_dir
      @idle_exit_minutes = idle_exit_minutes
      @poll_interval = poll_interval || FALLBACK_TICK_SECONDS
      @waker = Waker.new
    end

    # @return [Symbol] :idle_exit
    def run
      @session = Session.load(@session_id, state_dir: @state_dir)
      @engine = build_engine
      # Before the Bridge serves anything: a UI joining a resumed worker's
      # stream gets the session's history and status in its snapshot, not
      # an empty session until the first turn.
      @engine.session = @session
      # Start the shared idle scheduler so the worker can trigger turns when
      # reminders are due (even with no user input).
      @engine.start_idle

      @bridge = SessionManager.start_bridge(engine: @engine, state_dir: @state_dir, session_id: @session_id,
                                            on_input: -> { @waker.wake })
      @idle_exit = WorkerIdleExit.new(
        engine: @engine, bridge: @bridge,
        timeout_minutes: @idle_exit_minutes || SessionManager.config_idle_exit_minutes,
        input_pending: -> { !SessionManager.find_new_input_files(@session_dir).empty? }
      )

      begin
        # A session stopped before this worker took the lock (e.g. a stop
        # right after create) must not run its initial prompt.
        exit(0) if stopped_on_disk?
        loop do
          # Check if the session was externally marked as stopped
          exit(0) if Session.load(@session_id, state_dir: @state_dir).status == Session::STATUS_STOPPED

          if (prompt = take_initial_prompt)
            run_prompt(prompt, nil)
            next
          end

          input_files = SessionManager.find_new_input_files(@session_dir)
          if input_files.empty?
            return :idle_exit if @idle_exit.due? && leave_idle

            @waker.wait(@poll_interval)
            next
          end

          input_files.sort.each do |input_file|
            # A stop between two queued turns leaves the rest queued.
            break if stopped_on_disk?

            run_input_file(input_file)
          end
        end
      rescue StandardError => e
        Session.mark_error(@session_id, reason: e.message, state_dir: @state_dir)
        exit(1)
      ensure
        @bridge&.stop
      end
    end

    private

    def build_engine
      session_id = @session_id
      state_dir = @state_dir
      waker = @waker
      Samagotchi::Engine.new(
        mode: @session.mode.to_sym,
        model_name: @session.model_name,
        reminders: {
          callback: lambda { |_due_names|
            # When a reminder is due, queue a synthetic turn and wake the
            # loop for it.
            SessionManager.write_turn_input(session_id, prompt: "[SYSTEM: Your scheduled reminders are due. Please check them.]",
                                                        client_id: SessionManager::REMINDER_CLIENT_ID, state_dir: state_dir)
            waker.wake
          }
        }
      )
    end

    # spawn_session hands the first prompt over in last_prompt, but
    # last_prompt also records every later turn's prompt (and mark_error's
    # reason), so only a session with no conversation yet has one pending; a
    # resumed session must not replay its last turn. Taken once.
    # @return [String, nil]
    def take_initial_prompt
      return nil if @initial_prompt_taken

      @initial_prompt_taken = true
      return nil unless @session.messages.empty? && !@session.last_prompt.to_s.strip.empty?

      prompt = @session.last_prompt
      @session.last_prompt = ""
      @session.save(state_dir: @state_dir)
      prompt
    end

    def run_input_file(input_file)
      claimed_file = SessionManager.claim_input_file(input_file)
      return unless claimed_file

      begin
        message, origin = SessionManager.read_input(claimed_file)
        run_prompt(message, origin) unless message.to_s.strip.empty?
      ensure
        FileUtils.rm_f(claimed_file)
      end
    end

    def run_prompt(prompt, origin)
      # Show the turn as running to readers of the file (the web's session
      # list); the Engine resets it to idle when it ends.
      @session.status = Session::STATUS_RUNNING
      @session.save(state_dir: @state_dir)
      result = @engine.run_turn(@session, prompt, pending_input: pending_input_drain, origin: origin)
      response = result.respond_to?(:output) ? result.output : nil
      SessionManager.write_output(@session_dir, response) unless response.nil? || response.strip.empty?
      @session.save(state_dir: @state_dir) unless stopped_on_disk?
    end

    # Shared mid-turn steering drain: claims any input files that arrive
    # while a turn is running and hands them to the agentic loop so
    # follow-ups merge at the next iteration boundary instead of waiting
    # for the turn to end. claim_input_file is atomic (rename), so a file
    # consumed mid-turn simply fails the outer loop's later claim with
    # ENOENT → nil. No double-processing risk.
    #
    # Runs on the turn thread; it announces who sent the merged input so
    # every live UI can attribute it.
    def pending_input_drain
      @pending_input_drain ||= lambda do
        merged = SessionManager.find_new_input_files(@session_dir).sort.filter_map do |input_file|
          claimed_file = SessionManager.claim_input_file(input_file)
          next unless claimed_file

          begin
            prompt, origin = SessionManager.read_input(claimed_file)
            prompt = prompt.to_s.strip
            prompt.empty? ? nil : [prompt, origin]
          ensure
            FileUtils.rm_f(claimed_file)
          end
        end
        unless merged.empty?
          @engine.announce(type: :input_merged, count: merged.size, origins: merged.filter_map(&:last))
        end
        merged.map(&:first)
      end
    end

    # Check again with the event log held, which the Bridge holds while it
    # queues a POST /turn, then close the Bridge so no client can queue one
    # after the check, and stop the idle jobs (reminder callback, recap).
    # A client connecting from here on finds no worker: `chi --attach` fails
    # and the web stream answers 503 (a small window, left as is).
    # @return [Boolean] false when something came in since #due?
    def leave_idle
      @engine.synchronize_events do
        next false unless @idle_exit.due?

        @bridge&.stop
        @engine.stop_idle
        log_idle_exit
        true
      end
    end

    def log_idle_exit
      SessionManager.debug_log("[worker] pid #{Process.pid} idle-exits after #{@idle_exit.idle_seconds.round}s unused")
    end

    def stopped_on_disk?
      SessionManager.stopped_on_disk?(@session_id, state_dir: @state_dir)
    end
  end
end
