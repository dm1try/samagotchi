# frozen_string_literal: true

require_relative "config"
require_relative "context_fetch"
require_relative "context_sources"
require_relative "log"

module Samagotchi
  # A session worker's thread that keeps its attached context fresh: every
  # TICK_SECONDS it runs each command source (the session's and its
  # project's, not muted here) whose last try is older than its interval
  # (--every, else context.every_seconds), and calls +on_change+ after a
  # new text or a failure so the loop absorbs it at once. The first pass,
  # right after the worker starts, runs every source not tried in the last
  # MIN_EVERY_SECONDS: a woken worker's first absorb says what changed while
  # it was away.
  #
  # Polling isn't activity: it never holds the worker up (WorkerIdleExit),
  # and it stops with it (#stop kills a running command's group). Project
  # sources are shared by the project's workers; ContextFetch's lock and a
  # second freshness check under it make one fetch per interval.
  class ContextPoller
    TICK_SECONDS = 5

    # @param project_root [String, nil] Session#project_root
    # @param cwd [String] the session's folder (a session source runs there)
    # @param on_change [#call] after a fetch brought a new text or failed
    def initialize(session_id:, state_dir:, project_root:, cwd:, on_change:, tick: TICK_SECONDS)
      @session_id = session_id
      @state_dir = state_dir
      @project_root = project_root
      @cwd = cwd
      @on_change = on_change
      @tick = tick
      @own = ContextSources.session_location(session_id, state_dir: state_dir)
      @queue = Thread::Queue.new
      @stopping = false
    end

    def start
      @thread ||= Thread.new do
        Thread.current.name = "context-poller"
        run
      end
      self
    end

    # Stops the loop and kills a command it is running; returns once it has.
    def stop
      @stopping = true
      @queue << :stop
      @thread&.join((ContextFetch::KILL_GRACE_SECONDS * 3) + @tick)
      @thread = nil
    end

    # One pass (the thread's loop body; specs call it).
    # @param first [Boolean] the worker's first pass
    def poll(first: false)
      ContextSources.attached(@session_id, project_root: @project_root, state_dir: @state_dir).each do |attached|
        break if @stopping
        next if attached.source.push? || @own.muted?(attached.name)

        interval = first ? ContextSources::MIN_EVERY_SECONDS : interval_of(attached.source)
        age = attached.snapshot.age
        next if age && age < interval

        outcome = ContextFetch.fetch(attached, cwd: cwd_for(attached), fresh_within: interval, cancelled: -> { @stopping })
        @on_change.call if %i[new error].include?(outcome.status)
      rescue StandardError => e
        Log.exception(:context, "poll_failed", e, name: attached.name)
      end
    end

    private

    def run
      first = true
      until @stopping
        poll(first: first)
        first = false
        @queue.pop(timeout: @tick)
      end
    rescue StandardError => e
      Log.exception(:context, "poller_crashed", e)
    end

    def interval_of(source)
      seconds = source.every_seconds || Config.get("context.every_seconds").to_i
      [seconds, ContextSources::MIN_EVERY_SECONDS].max
    end

    # A session's source runs in the session's folder, a project's in the
    # project root (the session's folder when the root isn't one).
    def cwd_for(attached)
      return @cwd if attached.location.session?

      @project_root && Dir.exist?(@project_root) ? @project_root : @cwd
    end
  end
end
