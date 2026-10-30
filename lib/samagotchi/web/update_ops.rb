# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require_relative "../child_env"
require_relative "../chi_home"
require_relative "../client_id"
require_relative "../installed_gem"
require_relative "../live_versions"
require_relative "../log"
require_relative "../session"
require_relative "../session_manager"
require_relative "../version"
require_relative "update_check"

module Samagotchi
  module Web
    # The three update operations chi web runs for its owner, one at a time
    # (App's routes ask for them, and so does AutoUpdate): an install
    # (`chi update --to V` in a child), a pass restarting the stale workers,
    # and chi web's own restart. Each answers at once, :started (it runs on
    # its own thread, its progress and result going out as `chi_update`
    # frames) or a refusal; the caller decides what a refusal says.
    class UpdateOps
      # chi update's own words when it printed no rows.
      class UpdateFailed < StandardError; end

      # @param hub [SessionHub, nil] the frames' publisher
      # @param manager [#restart_session] SessionManager
      # @param state_dir [String, nil] the sessions dir (nil: the default)
      # @param runner [#call] `(argv, env:, progress:) → [stdout, success]`
      #   runs the chi update child
      # @param blocked [#call] why this install can't take a gem, or nil
      def initialize(hub:, manager: SessionManager, state_dir: nil, runner: nil, blocked: nil)
        @hub = hub
        @manager = manager
        @state_dir = state_dir
        @runner = runner || method(:run_update_command)
        @blocked = blocked || -> { UpdateCheck.blocked_reason }
        @mutex = Mutex.new
        @running = false
        @restart_web = nil
      end

      # Set by Server.start: the lambda that has chi web restart itself
      # (true; :no_wrapper when there is nothing to exec; false when one was
      # already asked for).
      attr_writer :restart_web

      # Whether the restart lambda is there (a stand-in server has none).
      def restart_web? = !@restart_web.nil?

      # Why a gem can't be installed here (UpdateCheck.blocked_reason), or nil.
      def blocked_reason = @blocked.call

      # Whether an operation runs (or chi web is restarting).
      def running? = @mutex.synchronize { @running }

      # Runs `chi update --to +version+` on a thread.
      # @param wait [Boolean] block until it ends and answer its final
      #   `{state:, rows:}` instead of :started
      # @return [Symbol, Hash] :started, :busy (another operation runs) or
      #   :start_failed (no thread); with wait: the result
      def install(version, wait: false)
        return :busy unless claim

        @hub.publish_update(state: "running", rows: [], operation: "install", version: version)
        thread = Thread.new { perform_install(version) }
        wait ? thread.value : :started
      rescue ThreadError => e
        release
        Log.warn(:web, "update_start_failed", error: e.class.name, msg: e.message)
        @hub&.publish_update(state: "failed", rows: [
          { "component" => "chi update", "status" => "failed (couldn't start update)", "failed" => true, "kept" => [] }
        ], operation: "install")
        :start_failed
      end

      # Restarts every stale worker (the worker refuses atomically when busy).
      # @return [Symbol, Hash] as #install
      def restart_workers(wait: false)
        return :busy unless claim

        @hub.publish_update(state: "running", rows: [], operation: "workers")
        thread = Thread.new { perform_worker_restarts }
        wait ? thread.value : :started
      rescue ThreadError => e
        release
        Log.warn(:web, "worker_restart_start_failed", error: e.class.name, msg: e.message)
        @hub&.publish_update(state: "failed", rows: [
          { "state" => "failed", "reason" => "couldn't start worker restarts" }
        ], operation: "workers")
        :start_failed
      end

      # The exec replaces this process: an update's chi update child (its
      # pipes read here) or a worker restart pass would die mid-way, so
      # neither may run, and none starts once the restart is asked for.
      # @return [Symbol] :unavailable (no restart lambda), :busy, :started,
      #   :no_wrapper or :requested (already restarting)
      def restart_web
        return :unavailable unless @restart_web

        busy = @mutex.synchronize do
          next true if @running

          @running = true # held for good once restarting: the exec ends this process
          false
        end
        return :busy if busy

        case @restart_web.call
        when true then return :started
        when :no_wrapper then answer = :no_wrapper
        else answer = :requested
        end
        release
        answer
      end

      # The chi update child: with a chi home, the home's chi (its gem dirs
      # are what new workers activate); else this Ruby and the wrapper.
      def update_argv(version, home: ChiHome.current)
        args = ["update", "--to", version, "--no-desktop", "--json"]
        return home.boot_argv(run: ChiHome::CHI_BOOT) + ["--", *args] if home

        [RbConfig.ruby, InstalledGem.wrapper, *args]
      end

      private

      def claim
        @mutex.synchronize do
          next false if @running

          @running = true
        end
      end

      def release
        @mutex.synchronize { @running = false }
      end

      def perform_install(version)
        argv = update_argv(version)
        said = nil
        output, success = @runner.call(argv, env: ChildEnv.unbundled,
                                             progress: lambda { |line|
                                               said = line unless line.strip.empty?
                                               @hub.publish_update(state: "running", rows: [], progress: line,
                                                                   operation: "install", version: version)
                                             })
        rows = update_rows(output)
        # No rows (a usage error, a refusal): what the child said is the reason.
        raise UpdateFailed, said || output.lines.map(&:strip).find { |line| !line.empty? } || "chi update printed no rows" unless rows

        # The installed version as of now (the hub's own look is up to a probe interval old), before "done".
        @hub.refresh_installed if success
        state = success ? "done" : "failed"
        @hub.publish_update(state: state, rows: rows, operation: "install", version: version)
        { state: state, rows: rows }
      rescue StandardError => e
        Log.exception(:web, "update_failed", e)
        rows = [{ "component" => "chi update", "status" => "failed (#{e.message.lines.first.to_s.strip})",
                  "failed" => true, "kept" => [] }]
        @hub.publish_update(state: "failed", rows: rows, operation: "install", version: version)
        { state: "failed", rows: rows }
      ensure
        release
      end

      # chi update --json's rows, or nil when it printed none.
      def update_rows(output)
        rows = JSON.parse(output)
        rows if rows.is_a?(Array) && rows.all?(Hash)
      rescue JSON::ParserError
        nil
      end

      def run_update_command(argv, env:, progress:)
        Open3.popen3(env, *argv) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          stderr_thread = Thread.new { stderr.each_line { |line| progress.call(line.chomp) } }
          output = stdout.read
          stderr_thread.value
          [output, wait_thread.value.success?]
        end
      end

      def default_state_dir = @state_dir || Session.default_state_dir

      def perform_worker_restarts
        # Installed now: the hub's own look is up to a full probe old (nil right after chi web started).
        target = @hub.refresh_installed || VERSION
        rows = []
        LiveVersions.stale_workers(target, state_dir: default_state_dir).each do |worker|
          row = begin
            restarted = @manager.restart_session(worker.session_id, state_dir: @state_dir, client_id: ClientId::WEB_RESTART)
            @hub.touch(worker.session_id)
            { "session_id" => restarted.session_id, "state" => "restarted", "from_version" => restarted.from_version,
              "version" => restarted.version }
          rescue SessionManager::RestartRefused => e
            # detail: the refusal's own words (RestartRefused.words), the reason code for clients.
            { "session_id" => worker.session_id, "state" => "refused", "reason" => e.reason.to_s,
              "detail" => e.message, "holds" => e.holds.map(&:to_s) }
          rescue SessionManager::OwnedByTUI => e
            { "session_id" => worker.session_id, "state" => "owned_by_tui", "detail" => e.message }
          rescue StandardError => e
            Log.exception(:web, "worker_restart_failed", e, sid: worker.session_id)
            { "session_id" => worker.session_id, "state" => "failed", "reason" => e.class.name, "detail" => e.message }
          end
          rows << row
          @hub.publish_update(state: "running", rows: rows.dup, operation: "workers")
        end
        state = rows.any? { |row| row["state"] == "failed" } ? "failed" : "done"
        @hub.publish_update(state: state, rows: rows, operation: "workers")
        { state: state, rows: rows }
      rescue StandardError => e
        Log.exception(:web, "worker_restart_failed", e)
        rows = [{ "state" => "failed", "reason" => e.class.name, "detail" => e.message }]
        @hub.publish_update(state: "failed", rows: rows, operation: "workers")
        { state: "failed", rows: rows }
      ensure
        release
      end
    end
  end
end
