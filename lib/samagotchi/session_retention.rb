# frozen_string_literal: true

require "fileutils"
require "time"
require_relative "session"
require_relative "archive_store"
require_relative "config"
require_relative "log"
require_relative "model_profile"
require_relative "session_manager"

module Samagotchi
  # Which sessions go: `chi sessions prune` / `clean` (.prune) and the lazy
  # sweep chi web runs at most once a day (.sweep_if_due). Age
  # (session.retention_days), count (session.max_count, counting only the
  # sessions that stay), statuses kept (session.keep_status), sessions left
  # empty (SessionManager.discardable?, an hour on), leftover scratch
  # sessions and skeleton-only directories; a session with a live owner
  # always stays.
  module SessionRetention
    # The session.retention_days / max_count / keep_status defaults.
    DEFAULT_RETENTION_DAYS = 14
    DEFAULT_MAX_COUNT = 500
    # status is turn state; a live owner (the prune alive_check) is what
    # protects a session in use, so no status is kept by default: a
    # "running" left by a crashed worker must not keep it forever.
    DEFAULT_KEEP_STATUS = [].freeze

    # How long a session may sit empty before the sweep takes it: its
    # worker (or a REPL) deletes it as it leaves, so the sweep only catches
    # those killed first (a reboot, kill -9).
    EMPTY_GRACE_SECONDS = 3600

    # The settings (or the caller's flags) applied, with live owners kept and
    # sessions left empty an hour taken (unless session.keep_empty).
    # @return [Hash] { deleted: [ids], kept: [ids], skipped: [ids] }
    def self.prune(state_dir: nil, days: nil, max_count: nil, keep_status: nil, dry_run: false, test_only: false,
                   any_age: false)
      sd = state_dir || Session.default_state_dir
      days = resolve_days(days)
      max_count = resolve_max_count(max_count)
      keep_status = resolve_keep_status(keep_status)
      discard = SessionManager.discard_empty?
      default_model = discard ? (begin ModelProfile.required_model_name(nil) rescue nil end) : nil
      result = apply(
        state_dir: sd,
        days: days,
        max_count: max_count,
        keep_status: keep_status,
        dry_run: dry_run,
        test_only: test_only,
        any_age: any_age,
        alive_check: ->(sid) { !SessionManager.session_owner(sid, state_dir: sd).nil? },
        empty_check: discard ? ->(sid) { left_empty?(sid, state_dir: sd, default_model: default_model) } : nil
      )
      result[:deleted].concat(prune_orphan_dirs(sd, dry_run: dry_run)) if discard && !test_only
      result
    end

    private_class_method def self.left_empty?(session_id, state_dir:, default_model:)
      path = File.join(state_dir, "#{session_id}#{Session::FILE_EXT}")
      Time.now - File.mtime(path) > EMPTY_GRACE_SECONDS &&
        SessionManager.discardable?(session_id, state_dir: state_dir, default_model: default_model)
    rescue SystemCallError
      false
    end

    # Directories with no session file and nothing but the skeleton, nobody
    # owning them: a REPL killed before its first save, or a worker woken
    # just as its session was discarded.
    # @return [Array<String>] their ids
    private_class_method def self.prune_orphan_dirs(state_dir, dry_run:)
      return [] unless Dir.exist?(state_dir)

      Dir.children(state_dir).filter_map do |name|
        dir = File.join(state_dir, name)
        next unless name.match?(/\A[\w-]+\z/) && File.directory?(dir)
        next if File.exist?(File.join(state_dir, "#{name}#{Session::FILE_EXT}"))
        next unless Time.now - File.mtime(dir) > EMPTY_GRACE_SECONDS && SessionManager.empty_session_dir?(dir)
        next if SessionManager.session_owner(name, state_dir: state_dir)

        FileUtils.rm_rf(dir) unless dry_run
        name
      rescue SystemCallError
        nil
      end
    end

    # Lazy sweep guard: runs prune at most once per SWEEP_INTERVAL_HOURS
    # (session.sweep_interval_hours).
    MARKER = ".last_retention"
    SWEEP_INTERVAL_HOURS = 24

    def self.sweep_if_due(state_dir: nil)
      sd = state_dir || Session.default_state_dir
      return unless Dir.exist?(sd)

      hours = Samagotchi::Config.get("session.sweep_interval_hours").to_i
      interval = (hours.positive? ? hours : SWEEP_INTERVAL_HOURS) * 3600
      marker = File.join(sd, MARKER)
      if File.exist?(marker)
        age = Time.now - File.mtime(marker)
        return if age < interval
      end
      result = prune(state_dir: sd)
      FileUtils.touch(marker)
      if result[:deleted].any?
        Log.info(:worker, "retention_pruned", echo: "[retention] pruned #{result[:deleted].size} sessions (kept #{result[:kept].size})", deleted: result[:deleted].size, kept: result[:kept].size)
      end
      result
    rescue StandardError => e
      Log.warn(:worker, "retention_failed", echo: "[retention] sweep failed: #{e.class}: #{e.message}", error: e.class.name)
      nil
    end

    # The caller's value (a sessions prune flag) or session.retention_days.
    private_class_method def self.resolve_days(val)
      return val.to_i if !val.nil? && val.to_s.strip != ""

      Samagotchi::Config.get("session.retention_days").to_i
    end

    private_class_method def self.resolve_max_count(val)
      return val.to_i if !val.nil? && val.to_s.strip != ""

      Samagotchi::Config.get("session.max_count").to_i
    end

    # A comma list of statuses never pruned; "" keeps none.
    private_class_method def self.resolve_keep_status(val)
      raw = !val.nil? && val.to_s.strip != "" ? val.to_s : Samagotchi::Config.get("session.keep_status").to_s
      raw.split(",").map(&:strip).reject(&:empty?)
    end

    # Apply the retention policy to the sessions on disk.
    #
    # Only deletes when the json file exists — orphan dirs without json are never removed.
    # Honors keep_status and live-worker guard.
    # A session is kept only if it is NOT expired by age AND within max_count;
    # either expiry or overflow triggers deletion (unless protected).
    #
    # +empty_check+ (id → Boolean) marks a session left empty: it goes
    # whatever its age and the count (.prune).
    #
    # +any_age+ makes every session eligible, whatever its age and the
    # count (`chi sessions clean` with no --days: test runs are throwaway).
    #
    # A scratch session nobody owns (its REPL was killed) goes whatever its
    # age, its status and the count; +test_only+ takes it too.
    #
    # +max_count+ counts the sessions that stay: one deleted whatever its
    # place (scratch, left empty, expired, +any_age+) takes no slot.
    #
    # Archived sessions are not in Session.list, so they are neither deleted nor
    # counted. One unarchived is aged from when it was unarchived, if later.
    #
    # @return [Hash] { deleted: [ids], kept: [ids], skipped: [ids] }
    def self.apply(state_dir: Session.default_state_dir, days: DEFAULT_RETENTION_DAYS, max_count: DEFAULT_MAX_COUNT,
                   keep_status: DEFAULT_KEEP_STATUS, dry_run: false, test_only: false, alive_check: nil,
                   empty_check: nil, any_age: false)
      keep_status = Array(keep_status).map(&:to_s)
      # Fetch all sessions sorted newest-first for count logic
      all = Session.list(state_dir: state_dir, sort: "updated_at", order: "desc")
      # Filter test_only if requested
      if test_only
        all = all.select { |session| session.test_run || session.scratch }
      end

      now = Time.now
      cutoff = days.to_i.positive? ? now - days.to_i * 86_400 : nil
      max = max_count.to_i

      deleted = []
      kept = []
      skipped = []
      passed_over = 0

      all.each_with_index do |session, idx|
        path = File.join(state_dir, "#{session.id}#{Session::FILE_EXT}")
        # Only when json present
        unless File.exist?(path)
          skipped << session.id
          next
        end

        # Protected by keep_status
        if keep_status.include?(session.status.to_s) && !session.scratch
          kept << session.id
          next
        end

        # Protected by live worker
        if alive_check
          begin
            if alive_check.call(session.id)
              kept << session.id
              next
            end
          rescue StandardError
            nil
          end
        end

        left_empty = begin
          empty_check&.call(session.id)
        rescue StandardError
          false
        end

        # Determine expiry and overflow
        expired = false
        if cutoff
          begin
            updated = Time.iso8601(session.updated_at.to_s)
          rescue ArgumentError
            updated = File.mtime(path) rescue now
          end
          unarchived = ArchiveStore.unarchived_at(Session.session_dir(session.id, state_dir: state_dir))
          updated = unarchived if unarchived && unarchived > updated
          expired = updated < cutoff
        end

        # A session deleted whatever its place (scratch, left empty,
        # expired, any_age) takes no max_count slot: the count is of the
        # sessions ahead that stay.
        overflow = max.positive? && idx - passed_over >= max
        passed_over += 1 if expired || left_empty || any_age || session.scratch

        # retain forever when both disabled
        if max.zero? && cutoff.nil? && !left_empty && !any_age && !session.scratch
          kept << session.id
          next
        end

        # If neither expired nor overflow, keep
        unless expired || overflow || left_empty || any_age || session.scratch
          kept << session.id
          next
        end

        # Eligible for deletion
        if dry_run
          deleted << session.id
        else
          begin
            FileUtils.rm_f(path)
            sidecar = File.join(state_dir, session.id)
            FileUtils.rm_rf(sidecar) if File.exist?(sidecar)
            deleted << session.id
          rescue StandardError
            skipped << session.id
          end
        end
      end

      { deleted: deleted, kept: kept, skipped: skipped }
    end
  end
end
