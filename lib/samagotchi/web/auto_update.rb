# frozen_string_literal: true

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
    # The run's record lives in update_check.json (UpdateCheck#save_auto),
    # so a chi web restart finds it. See docs/architecture.md.
    class AutoUpdate
      # Seconds between steps, and before the first (the checker's first
      # check is at 30).
      POLL = 300
      FIRST = 60

      # @param hub [SessionHub]
      # @param ops [UpdateOps]
      # @param check [UpdateCheck] the answer and the record
      # @param auto [String] update.auto
      # @param restart [String] update.restart (idle or never)
      # @param poll [Numeric] seconds between steps
      def initialize(hub:, ops:, check:, auto: Config.get("update.auto"), restart: Config.get("update.restart"),
                     poll: POLL, first: FIRST)
        @hub = hub
        @ops = ops
        @check = check
        @auto = auto
        @restart = restart
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

        version = @check.available
        return unless version
        return if @check.auto_failed?(version) || tried?(version)
        return if @ops.blocked_reason || @ops.running? || busy_turn?

        install(version)
      end

      private

      def run_loop
        wait = @first
        until @stopped
          break if @wakeup.pop(timeout: wait) == :stop

          step
          wait = @poll
        end
      rescue StandardError => e
        Log.exception(:web, "auto_update_failed", e)
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
        record = { version: version, from: VERSION, kept: kept_files(rows) }
        if result[:state] == "done"
          Log.info(:web, "auto_update_installed", version: version, kept: record[:kept].size)
          installed(record)
        else
          failed(record, rows)
        end
      end

      # Installed, and nothing restarts here yet: the phone is told, and the
      # owner's toast and idle exit carry chi web and the workers over.
      def installed(record)
        @hub.publish_notice(kind: "installed", version: record[:version], kept: record[:kept].size)
        @check.save_auto(record.merge(phase: "done", pushed: true))
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
