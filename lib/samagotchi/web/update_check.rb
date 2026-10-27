# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "../atomic_file"
require_relative "../config"
require_relative "../gem_update"
require_relative "../installed_gem"
require_relative "../installed_versions"
require_relative "../log"
require_relative "../paths"
require_relative "../version"

module Samagotchi
  module Web
    # Checks RubyGems away from the session hub's Monitor and publishes the
    # result as chi web's version state. The state file preserves cooldowns
    # and version-level notice deduplication across chi web restarts.
    class UpdateCheck
      FIRST_CHECK = 30

      def initialize(hub:, enabled: Config.get("update.notify") == "on",
                     check_hours: Config.get("update.check_hours"),
                     min_age_hours: Config.get("update.min_age_hours"),
                     fetcher: -> { GemUpdate.new.releases }, clock: -> { Time.now },
                     state_file: File.join(Paths.state_dir, "update_check.json"),
                     gem_spec: InstalledGem.spec, bundler: nil, gem_dir: Gem.dir,
                     installed_versions: InstalledVersions.new)
        @hub = hub
        @enabled = enabled
        @check_seconds = [check_hours.to_i, 1].max * 3600
        @min_age_seconds = [min_age_hours.to_i, 0].max * 3600
        @fetcher = fetcher
        @clock = clock
        @state_file = state_file
        @gem_spec = gem_spec
        @bundler = bundler.nil? ? (defined?(::Bundler) || !ENV["BUNDLE_GEMFILE"].to_s.empty?) : bundler
        @gem_dir = gem_dir
        @installed_versions = installed_versions
        @state = load_state
        @blocked = blocked_reason
        @checking = Mutex.new
        @wakeup = Queue.new
        @thread = nil
        @stopped = false
      end

      def start
        return self unless @enabled
        return self if @thread&.alive?

        @stopped = false
        @hub.update_available(available: @state[:available], blocked: @blocked)
        @thread = Thread.new { run_loop }
        self
      end

      def stop
        @stopped = true
        @wakeup << :stop
        thread = @thread
        @thread = nil
        thread&.join(6.0)
        nil
      end

      # @return [Boolean] whether a check was due and completed
      def check
        return false unless @enabled

        @checking.synchronize do
          now = @clock.call
          return false unless due?(now)

          releases = @fetcher.call
          available = available_release(releases, now)&.version
          notified = @state[:notified]
          notify = available && !notified.include?(available)
          next_state = { checked_at: now.iso8601, available: available,
                         notified: notify ? (notified + [available]) : notified }
          persist(next_state)
          @hub.update_available(available: available, blocked: @blocked, notify: !!notify)
          true
        rescue StandardError => e
          Log.warn(:web, "update_check_failed", error: e.class.name, msg: e.message)
          persist(@state.merge(checked_at: now.iso8601)) if now
          false
        end
      end

      private

      def run_loop
        wait = FIRST_CHECK
        until @stopped
          break if @wakeup.pop(timeout: wait) == :stop

          check
          wait = @check_seconds
        end
      rescue StandardError => e
        Log.warn(:web, "update_check_failed", error: e.class.name, msg: e.message)
      end

      def due?(now)
        checked_at = parsed_time(@state[:checked_at])
        checked_at.nil? || now >= checked_at + @check_seconds
      end

      def available_release(releases, now)
        installed = @installed_versions.newest
        floor = [VERSION, installed].compact.select { |version| Gem::Version.correct?(version) }
                                   .map { |version| Gem::Version.new(version) }.max
        releases.select do |release|
          version = Gem::Version.new(release.version)
          !release.prerelease && version > floor && now - release.created_at >= @min_age_seconds
        end.max_by { |release| Gem::Version.new(release.version) }
      end

      def blocked_reason
        return "checkout" unless @gem_spec
        return "bundler" if @bundler
        return "gem_dir_not_writable" unless File.writable?(@gem_dir)

        nil
      end

      def load_state
        return { checked_at: nil, available: nil, notified: [] } unless File.file?(@state_file)

        data = JSON.parse(File.read(@state_file))
        {
          checked_at: data["checked_at"],
          available: data["available"],
          notified: Array(data["notified"]).select { |version| version.is_a?(String) }
        }
      rescue JSON::ParserError, SystemCallError => e
        Log.warn(:web, "update_check_failed", error: e.class.name, msg: e.message)
        { checked_at: nil, available: nil, notified: [] }
      end

      def persist(state)
        FileUtils.mkdir_p(File.dirname(@state_file))
        AtomicFile.write(@state_file, JSON.generate(state), perm: 0o600)
        @state = state
      end

      def parsed_time(value)
        Time.iso8601(value) if value
      rescue ArgumentError
        nil
      end
    end
  end
end
