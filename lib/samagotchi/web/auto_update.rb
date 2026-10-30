# frozen_string_literal: true

require "rubygems/version"
require "time"
require_relative "../config"
require_relative "../log"
require_relative "../version"

module Samagotchi
  module Web
    # With update.auto: install, installs the release UpdateCheck found when
    # no turn runs anywhere, and tells the owner's phone how it went. Its own
    # thread beside the checker; every POLL it takes the next step, so what
    # stops it (a turn, another operation) only delays it.
    #
    # The gate: the install isn't blocked (a checkout, Bundler, an unwritable
    # gem dir), no update operation runs, no session's turn runs or waits on
    # a question (`chi update` merges shipped bundles that live workers
    # read), and the release isn't one this already failed on (one automatic
    # try per release: the Update button or a newer release tries again).
    #
    # With update.restart: idle (the default) the install is followed by:
    # 1. the stale workers, only those idle and quiet for QUIET seconds (the
    #    worker still refuses atomically when it isn't), the left ones tried
    #    again each step for RETRY_FOR;
    # 2. chi web itself, once no operation and no turn runs: a preflight
    #    (the newest chi must start and say its version) first, then the
    #    exec. The restarted chi web's own AutoUpdate sees phase `web`,
    #    counts the workers once more and says "chi updated": the process
    #    that survives is the one that speaks, and that proves it is up.
    # A preflight that fails leaves chi web as it is and says so.
    # update.restart: never stops after the install.
    #
    # The run's record lives in update_check.json (UpdateCheck#save_auto),
    # so a chi web restart finds it. See docs/architecture.md.
    class AutoUpdate
      # Seconds between steps, and before the first (the checker's first
      # check is at 30).
      POLL = 300
      FIRST = 60
      # The first step of a chi web restarted by this run (it only has to finish).
      FIRST_RESTARTED = 5
      # A worker restarts unattended only when its session was idle and quiet
      # this long (someone may be about to type), by its updated_at.
      QUIET = 600
      # The workers a run couldn't restart are tried again this long.
      RETRY_FOR = 24 * 3600
      # The phases a run is still in.
      OPEN_PHASES = %w[installed workers web].freeze

      # @param hub [SessionHub]
      # @param ops [UpdateOps]
      # @param check [UpdateCheck] the answer and the record
      # @param auto [String] update.auto
      # @param restart [String] update.restart (idle or never)
      # @param preflight [#call, nil] `(version) → nil | String`: whether the
      #   newest chi starts (nil result), or why not (nil: no check)
      # @param clock [#call] the Time now
      # @param poll [Numeric] seconds between steps
      def initialize(hub:, ops:, check:, auto: Config.get("update.auto"), restart: Config.get("update.restart"),
                     preflight: nil, clock: -> { Time.now }, poll: POLL, first: FIRST)
        @hub = hub
        @ops = ops
        @check = check
        @auto = auto
        @restart = restart
        @preflight = preflight
        @clock = clock
        @poll = poll
        @first = first
        @wakeup = Queue.new
        @thread = nil
        @stopped = false
      end

      def start
        return self unless @auto == "install"
        return self if @thread&.alive?

        @stopped = false
        @thread = Thread.new { run_loop }
        self
      end

      def stop
        @stopped = true
        @wakeup << :stop
        thread = @thread
        @thread = nil
        thread&.join(5.0)
        nil
      end

      # One look at what to do next (the thread's step; specs call it).
      def step
        return unless @auto == "install"

        record = @check.auto_state
        return carry_on(record) if record && OPEN_PHASES.include?(record[:phase])

        version = @check.available
        return unless version
        return if @check.auto_failed?(version) || tried?(version)
        return if @ops.blocked_reason || @ops.running? || busy_turn?

        install(version)
      end

      private

      def run_loop
        wait = restarted? ? FIRST_RESTARTED : @first
        until @stopped
          break if @wakeup.pop(timeout: wait) == :stop

          step
          wait = @poll
        end
      rescue StandardError => e
        Log.exception(:web, "auto_update_failed", e)
      end

      # A run that this chi web's start finds on its way to the web restart.
      def restarted?
        @check.auto_state&.dig(:phase) == "web"
      end

      # This release's run is already on record (installed, or given up on).
      def tried?(version)
        @check.auto_state&.dig(:version) == version
      end

      # A turn runs, or a question waits for its answer, in any session.
      def busy_turn?
        @hub.snapshot.any? do |summary|
          summary[:status] == "running" || !summary[:pending_question].nil?
        end
      end

      def install(version)
        Log.info(:web, "auto_update_start", version: version, from: VERSION)
        result = @ops.install(version, wait: true, auto: true)
        return Log.info(:web, "auto_update_deferred", version: version, why: result) if result.is_a?(Symbol)

        rows = result[:rows]
        record = { version: version, from: VERSION, at: @clock.call.iso8601, kept: kept_files(rows) }
        if result[:state] == "done"
          Log.info(:web, "auto_update_installed", version: version, kept: record[:kept].size)
          installed(record)
        else
          failed(record, rows)
        end
      end

      # Installed. With restart: never the phone is told and the owner's
      # toast and idle exit carry chi web and the workers over; else the
      # restarts follow, here and now when nothing holds them.
      def installed(record)
        return carry_on(save(record.merge(phase: "installed"))) unless @restart == "never"

        @hub.publish_notice(kind: "installed", version: record[:version], kept: record[:kept].size)
        save(record.merge(phase: "done", pushed: true))
      end

      # The next step of a run on record.
      def carry_on(record)
        case record[:phase]
        when "installed", "workers" then workers_then_web(record)
        when "web" then finish(record)
        end
      end

      def workers_then_web(record)
        return if @ops.running?

        record = restart_workers(record) if record[:phase] == "installed" || workers_left?(record)
        return unless record

        restart_web(record)
      end

      def workers_left?(record)
        record.dig(:workers, :left).to_i.positive? && @clock.call - recorded_at(record) < RETRY_FOR
      end

      def recorded_at(record)
        Time.iso8601(record[:at].to_s)
      rescue ArgumentError
        @clock.call
      end

      # A pass over the stale workers that are idle and quiet; the counts
      # add up over passes. nil when another operation took the turn.
      def restart_workers(record)
        result = @ops.restart_workers(wait: true, auto: true, select: quiet_filter)
        return if result.is_a?(Symbol)

        states = result[:rows].map { |row| row["state"] }
        restarted = record.dig(:workers, :restarted).to_i + states.count("restarted")
        save(record.merge(phase: "workers", workers: { restarted: restarted, left: states.size - states.count("restarted") }))
      end

      # Idle and quiet: no turn, no question, untouched for QUIET seconds.
      def quiet_filter
        summaries = @hub.snapshot.to_h { |summary| [summary[:id], summary] }
        now = @clock.call
        lambda do |worker|
          summary = summaries[worker.session_id]
          next false unless summary && summary[:status] == "idle" && summary[:pending_question].nil?

          touched = parse_time(summary[:updated_at])
          !touched.nil? && now - touched >= QUIET
        end
      end

      def parse_time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      # chi web itself, once no turn runs anywhere and the newest chi is
      # known to start. The record says `web` before the exec: the process
      # that comes up finishes the run.
      def restart_web(record)
        return if busy_turn?

        problem = @preflight&.call(record[:version])
        return restart_failed(record, problem, "auto_restart_preflight_failed") if problem

        save(record.merge(phase: "web"))
        Log.info(:web, "auto_update_restart", version: record[:version])
        case (answer = @ops.restart_web)
        when :started then nil
        when :busy then save(record.merge(phase: "workers"))
        else restart_failed(record, "chi web can't restart itself here (#{answer})", "auto_restart_refused")
        end
      end

      def restart_failed(record, detail, event)
        Log.warn(:web, event, version: record[:version], detail: detail)
        @hub.publish_notice(kind: "restart_failed", version: record[:version], detail: detail)
        save(record.merge(phase: "failed", detail: detail, pushed: true))
      end

      # In the restarted chi web: on the version, the workers counted once
      # more, "chi updated" said.
      def finish(record)
        if Gem::Version.new(VERSION) < Gem::Version.new(record[:version])
          return restart_failed(record, "chi web came back on #{VERSION}", "auto_restart_wrong_version")
        end

        @hub.scan
        record = restart_workers(record) || record
        workers = record[:workers] || {}
        Log.info(:web, "auto_update_done", version: record[:version], restarted: workers[:restarted], left: workers[:left])
        @hub.publish_notice(kind: "updated", version: record[:version], kept: record[:kept].to_a.size,
                            restarted: workers[:restarted].to_i, left: workers[:left].to_i)
        save(record.merge(phase: "done", pushed: true))
      end

      def save(record)
        @check.save_auto(record)
        record
      end

      def failed(record, rows)
        row = rows.find { |candidate| candidate["failed"] } || rows.first || {}
        detail = row["status"].to_s.lines.first.to_s.strip
        Log.warn(:web, "auto_update_failed_install", version: record[:version], detail: detail)
        gem_installed = rows.any? { |candidate| candidate["component"] == "chi (gem)" && !candidate["failed"] }
        @hub.publish_notice(kind: "failed", version: record[:version], detail: detail.empty? ? nil : detail,
                            installed: gem_installed)
        @check.save_auto(record.merge(phase: "failed", detail: detail, pushed: true), failed: record[:version])
      end

      def kept_files(rows)
        rows.flat_map { |row| Array(row["kept"]).map(&:to_s) }.uniq
      end
    end
  end
end
