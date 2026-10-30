# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "../atomic_file"
require_relative "../chi_home"
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
    # and version-level notice deduplication across chi web restarts, and
    # keeps AutoUpdate's record (the run in progress, the versions it gave
    # up on) beside them.
    #
    # It runs when update.notify is on, or when update.auto is install
    # (AutoUpdate needs the answer): with notify off the page and the phone
    # are told nothing, the hub's `available` stays nil.
    class UpdateCheck
      FIRST_CHECK = 30
      # A failed check (offline at start) tries again this soon, not a whole check_hours later.
      RETRY = 3600

      # @param enabled [Boolean] update.notify: the answer goes to the page
      # @param auto [Boolean] update.auto is install: check even when +enabled+ is not
      def initialize(hub:, enabled: Config.get("update.notify") == "on",
                     auto: Config.get("update.auto") == "install",
                     check_hours: Config.get("update.check_hours"),
                     min_age_hours: Config.get("update.min_age_hours"),
                     fetcher: -> { GemUpdate.new.releases }, clock: -> { Time.now },
                     state_file: File.join(Paths.state_dir, "update_check.json"),
                     gem_spec: InstalledGem.spec, bundler: nil, gem_dir: ChiHome.gem_dir(gem_spec: gem_spec),
                     installed_versions: InstalledVersions.new)
        @hub = hub
        @notify = enabled
        @enabled = enabled || auto
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
        @failed = false
      end

      def start
        return self unless @enabled
        return self if @thread&.alive?

        @stopped = false
        @hub.update_available(available: @notify ? still_newer(@state[:available]) : nil, blocked: @blocked)
        @thread = Thread.new { run_loop }
        self
      end

      def stop
        @stopped = true
        @wakeup << :stop
        thread = @thread
        @thread = nil
        thread&.join(11.0) # a fetch may take its 5 s open + 5 s read
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
          notify = @notify && available && !notified.include?(available)
          next_state = @state.merge(checked_at: now.iso8601, available: available,
                                    notified: notify ? (notified + [available]) : notified)
          persist(next_state)
          @hub.update_available(available: @notify ? available : nil, blocked: @blocked, notify: !!notify)
          @failed = false
          true
        rescue StandardError => e
          Log.warn(:web, "update_check_failed", error: e.class.name, msg: e.message)
          @failed = true
          false
        end
      end

      # The release the last check found and this chi (and the installed
      # ones) are still behind, whether or not the page was told.
      # @return [String, nil]
      def available
        still_newer(@state[:available])
      end

      # AutoUpdate's record of the run it started: {version:, from:, phase:,
      # kept:, workers:, pushed:, detail:} (symbol keys), nil when none.
      # @return [Hash, nil]
      def auto_state
        @checking.synchronize { @state[:auto]&.dup }
      end

      # Whether AutoUpdate already tried +version+ and failed (one automatic
      # try per version).
      def auto_failed?(version)
        @checking.synchronize { @state[:auto_failed].include?(version) }
      end

      # Saves AutoUpdate's record (nil clears it); +failed+ adds a version to
      # the ones it gave up on.
      def save_auto(auto, failed: nil)
        @checking.synchronize do
          failed_list = failed && !@state[:auto_failed].include?(failed) ? @state[:auto_failed] + [failed] : @state[:auto_failed]
          persist(@state.merge(auto: auto, auto_failed: failed_list))
        end
        nil
      end

      # Why chi web can't install a gem here (the notice's and POST /api/update's
      # one answer), or nil: a source checkout, a Bundler run, a gem dir it
      # can't write.
      # @return [String, nil]
      def self.blocked_reason(gem_spec: InstalledGem.spec, bundler: nil, gem_dir: ChiHome.gem_dir(gem_spec: gem_spec))
        bundler = defined?(::Bundler) || !ENV["BUNDLE_GEMFILE"].to_s.empty? if bundler.nil?
        return "checkout" unless gem_spec
        return "bundler" if bundler
        return "gem_dir_not_writable" unless File.writable?(gem_dir)

        nil
      end

      private

      def run_loop
        wait = FIRST_CHECK
        until @stopped
          break if @wakeup.pop(timeout: wait) == :stop

          check
          wait = next_wait(@clock.call)
        end
      rescue StandardError => e
        Log.warn(:web, "update_check_failed", error: e.class.name, msg: e.message)
      end

      # Until the check is due again (at least FIRST_CHECK), or RETRY after a failure.
      def next_wait(now)
        return [RETRY, @check_seconds].min if @failed

        checked_at = parsed_time(@state[:checked_at])
        return FIRST_CHECK unless checked_at

        [checked_at + @check_seconds - now, FIRST_CHECK].max
      end

      def due?(now)
        checked_at = parsed_time(@state[:checked_at])
        checked_at.nil? || now >= checked_at + @check_seconds
      end

      def available_release(releases, now)
        floor = version_floor
        releases.select do |release|
          version = Gem::Version.new(release.version)
          !release.prerelease && version > floor && now - release.created_at >= @min_age_seconds
        end.max_by { |release| Gem::Version.new(release.version) }
      end

      # The newest of this chi and the installed ones: a release counts only above it.
      def version_floor
        [VERSION, @installed_versions.newest].compact.select { |version| Gem::Version.correct?(version) }
                                             .map { |version| Gem::Version.new(version) }.max
      end

      # A saved answer the owner has since installed (or passed) is no longer available.
      def still_newer(version)
        version if version && Gem::Version.correct?(version) && Gem::Version.new(version) > version_floor
      end

      def blocked_reason = self.class.blocked_reason(gem_spec: @gem_spec, bundler: @bundler, gem_dir: @gem_dir)

      def load_state
        return empty_state unless File.file?(@state_file)

        data = JSON.parse(File.read(@state_file))
        {
          checked_at: data["checked_at"],
          available: data["available"],
          notified: strings(data["notified"]),
          auto: data["auto"].is_a?(Hash) ? data["auto"].transform_keys(&:to_sym) : nil,
          auto_failed: strings(data["auto_failed"])
        }
      rescue JSON::ParserError, SystemCallError => e
        Log.warn(:web, "update_check_failed", error: e.class.name, msg: e.message)
        empty_state
      end

      def empty_state = { checked_at: nil, available: nil, notified: [], auto: nil, auto_failed: [] }

      def strings(list) = Array(list).select { |version| version.is_a?(String) }

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
