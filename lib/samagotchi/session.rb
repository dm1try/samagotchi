# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module Samagotchi
  class Session
    METADATA_VERSION = 3
    STATE_SUBDIR = File.join("samagotchi", "sessions")
    FILE_EXT = ".json"

    STATUS_IDLE = "idle"
    STATUS_RUNNING = "running"
    STATUS_COMPLETED = "completed"
    STATUS_ERROR = "error"
    STATUS_STOPPED = "stopped"

    # Retention / ordering defaults (14 days, 500 sessions) — env overrides in SessionManager.
    DEFAULT_RETENTION_DAYS = 14
    DEFAULT_MAX_COUNT = 500
    # status is turn state; a live owner (the prune alive_check) is what
    # protects a session in use, so no status is kept by default.
    DEFAULT_KEEP_STATUS = [].freeze
    SORT_KEYS = %w[created_at updated_at].freeze
    SORT_ORDERS = %w[asc desc].freeze

    attr_accessor :id, :metadata_version, :mode, :model_name, :working_directory, :messages,
                   :created_at, :updated_at, :status, :last_prompt, :first_preview, :test_run,
                   :pending_question, :used_memory_names

    def initialize(id:, mode:, model_name:, working_directory:, messages:, created_at:, updated_at:,
                   metadata_version: METADATA_VERSION, status: STATUS_IDLE, last_prompt: "",
                   first_preview: "", test_run: false, pending_question: nil,
                   used_memory_names: [])
      @id = id
      @metadata_version = metadata_version
      @mode = mode
      @model_name = model_name
      @working_directory = working_directory
      @messages = messages
      @created_at = created_at
      @updated_at = updated_at
      @status = status
      @last_prompt = last_prompt
      @first_preview = first_preview
      @test_run = !!test_run
      @pending_question = pending_question
      @used_memory_names = Array(used_memory_names).map(&:to_s).reject(&:empty?).uniq
    end

    # Build a new, unsaved session.
    def self.new_session(mode:, model_name:, working_directory:, test_run: nil)
      now = Time.now.iso8601(3)
      resolved_test = if test_run.nil?
                        test_session_env?
                      else
                        !!test_run
                      end
      new(
        id: SecureRandom.uuid,
        mode: mode.to_s,
        model_name: model_name.to_s,
        working_directory: working_directory.to_s,
        messages: [],
        created_at: now,
        updated_at: now,
        status: STATUS_IDLE,
        first_preview: "",
        test_run: resolved_test
      )
    end

    def self.test_session_env?(env: ENV)
      env["SAMAGOTCHI_ENV"].to_s == "test" || env["RACK_ENV"].to_s == "test" || !env["CI"].to_s.strip.empty?
    end

    # Load a persisted session by its UUID.
    def self.load(session_id, state_dir: default_state_dir)
      path = session_path(session_id, state_dir: state_dir)
      raise ArgumentError, "Session not found: #{session_id}" unless File.exist?(path)

      data = JSON.parse(File.read(path))
      messages = (data["messages"] || []).map { |msg| symbolize_message_keys(msg) }
      pending = data["pending_question"]
      pending = symbolize_message_keys(pending) if pending.is_a?(Hash)
      used_mems = data["used_memory_names"] || data["used_memories"] || []
      new(
        id: data.fetch("id"),
        metadata_version: data.fetch("metadata_version", 1),
        mode: data.fetch("mode"),
        model_name: data.fetch("model_name"),
        working_directory: data.fetch("working_directory"),
        messages: messages,
        created_at: data.fetch("created_at"),
        updated_at: data.fetch("updated_at"),
        status: data.fetch("status", STATUS_IDLE),
        last_prompt: data.fetch("last_prompt", ""),
        first_preview: data.fetch("first_preview", ""),
        test_run: data.fetch("test_run", false),
        pending_question: pending,
        used_memory_names: Array(used_mems)
      )
    rescue JSON::ParserError => e
      raise ArgumentError, "Session file corrupted (#{session_id}): #{e.message}"
    end

    # Return all saved sessions sorted by updated_at desc by default (newest first).
    # Supports sort: created_at|updated_at and order: asc|desc.
    def self.list(state_dir: default_state_dir, sort: "updated_at", order: "desc", limit: nil, offset: 0)
      return [] unless Dir.exist?(state_dir)

      sort_key = SORT_KEYS.include?(sort.to_s) ? sort.to_s : "updated_at"
      sort_order = SORT_ORDERS.include?(order.to_s) ? order.to_s : "desc"

      sessions = Dir.glob(File.join(state_dir, "*#{FILE_EXT}")).filter_map do |path|
        data = JSON.parse(File.read(path))
        used_mems = data["used_memory_names"] || data["used_memories"] || []
        new(
          id: data.fetch("id"),
          metadata_version: data.fetch("metadata_version", 1),
          mode: data.fetch("mode"),
          model_name: data.fetch("model_name"),
          working_directory: data.fetch("working_directory"),
          messages: [],
          created_at: data.fetch("created_at"),
          updated_at: data.fetch("updated_at"),
          status: data.fetch("status", STATUS_IDLE),
          last_prompt: data.fetch("last_prompt", ""),
          first_preview: data.fetch("first_preview", ""),
          test_run: data.fetch("test_run", false),
          used_memory_names: Array(used_mems)
        )
      rescue JSON::ParserError, KeyError
        nil
      end

      sorted = sessions.sort_by do |s|
        val = sort_key == "created_at" ? s.created_at : s.updated_at
        begin
          Time.iso8601(val.to_s)
        rescue ArgumentError
          Time.at(0)
        end
      end
      sorted.reverse! if sort_order == "desc"
      # Apply offset/limit if given
      off = offset.to_i
      sorted = sorted.drop(off) if off.positive?
      if limit && limit.to_i.positive?
        sorted = sorted.first(limit.to_i)
      end
      sorted
    end

    # Prune old sessions according to retention policy.
    #
    # Only deletes when the json file exists — orphan dirs without json are never removed.
    # Honors keep_status and live-worker guard.
    # A session is kept only if it is NOT expired by age AND within max_count;
    # either expiry or overflow triggers deletion (unless protected).
    #
    # @return [Hash] { deleted: [ids], kept: [ids], skipped: [ids] }
    def self.prune(state_dir: default_state_dir, days: DEFAULT_RETENTION_DAYS, max_count: DEFAULT_MAX_COUNT,
                   keep_status: DEFAULT_KEEP_STATUS, dry_run: false, test_only: false, alive_check: nil)
      keep_status = Array(keep_status).map(&:to_s)
      # Fetch all sessions sorted newest-first for count logic
      all = list(state_dir: state_dir, sort: "updated_at", order: "desc")
      # Filter test_only if requested
      if test_only
        all = all.select(&:test_run)
      end

      now = Time.now
      cutoff = days.to_i.positive? ? now - days.to_i * 86_400 : nil
      max = max_count.to_i

      deleted = []
      kept = []
      skipped = []

      all.each_with_index do |session, idx|
        path = File.join(state_dir, "#{session.id}#{FILE_EXT}")
        # Only when json present
        unless File.exist?(path)
          skipped << session.id
          next
        end

        # Protected by keep_status
        if keep_status.include?(session.status.to_s)
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

        # Determine expiry and overflow
        expired = false
        if cutoff
          begin
            updated = Time.iso8601(session.updated_at.to_s)
          rescue ArgumentError
            updated = File.mtime(path) rescue now
          end
          expired = updated < cutoff
        end

        overflow = max.positive? && idx >= max

        # retain forever when both disabled
        if max.zero? && cutoff.nil?
          kept << session.id
          next
        end

        # If neither expired nor overflow, keep
        unless expired || overflow
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

    # Persist the session atomically. Updates +updated_at+ in place.
    def save(state_dir: self.class.default_state_dir)
      @updated_at = Time.now.iso8601(3)
      # Persist with current metadata version so new flag is written
      @metadata_version = METADATA_VERSION
      FileUtils.mkdir_p(state_dir)

      path = File.join(state_dir, "#{@id}#{FILE_EXT}")
      temp_path = "#{path}.tmp"

      # Auto-compute first_preview if not yet cached and messages contain a user entry.
      compute_first_preview!

      record = {
        "metadata_version" => @metadata_version,
        "id" => @id,
        "mode" => @mode,
        "model_name" => @model_name,
        "working_directory" => @working_directory,
        "messages" => @messages.map { |msg| stringify_message_keys(msg) },
        "created_at" => @created_at,
        "updated_at" => @updated_at,
        "status" => @status,
        "last_prompt" => @last_prompt,
        "first_preview" => @first_preview,
        "test_run" => !!@test_run,
        "pending_question" => @pending_question ? stringify_message_keys(@pending_question) : nil,
        "used_memory_names" => Array(@used_memory_names)
      }

      File.write(temp_path, JSON.pretty_generate(record) + "\n")
      File.rename(temp_path, path)
      self
    end

    # Mark a session as running.
    def self.mark_running(session_id, state_dir: default_state_dir)
      session = load(session_id, state_dir: state_dir)
      session.status = STATUS_RUNNING
      session.save(state_dir: state_dir)
    end

    # Mark a session as completed.
    def self.mark_completed(session_id, state_dir: default_state_dir)
      session = load(session_id, state_dir: state_dir)
      session.status = STATUS_COMPLETED
      session.save(state_dir: state_dir)
    end

    # Mark a session as errored.
    def self.mark_error(session_id, reason:, state_dir: default_state_dir)
      session = load(session_id, state_dir: state_dir)
      session.status = STATUS_ERROR
      session.last_prompt = reason.to_s
      session.save(state_dir: state_dir)
    end

    # Mark a session as stopped.
    def self.mark_stopped(session_id, state_dir: default_state_dir)
      session = load(session_id, state_dir: state_dir)
      session.status = STATUS_STOPPED
      session.save(state_dir: state_dir)
    end

    # Directory for a specific session (holds IPC files alongside session.json).
    def self.session_dir(session_id, state_dir: default_state_dir)
      File.join(state_dir, session_id)
    end

    # Default sessions directory path.
    def self.default_sessions_dir
      default_state_dir
    end

    # XDG-aware sessions directory.
    def self.default_state_dir(env: ENV)
      xdg = env.fetch("XDG_STATE_HOME", "").to_s.strip
      base = xdg.empty? ? File.join(Dir.home, ".local", "state") : xdg
      File.join(base, STATE_SUBDIR)
    end

    # Derive and cache the first user-message preview in the session record.
    # Returns true if the cached value was set or updated.
    def compute_first_preview!
      return false if @first_preview && !@first_preview.empty?

      first_user = @messages.find { |m| m[:role].to_s == "user" || m["role"].to_s == "user" }
      return false unless first_user

      preview = self.class.preview_of(first_user[:content] || first_user["content"])
      return false if preview.empty?

      @first_preview = preview
      true
    end

    # A prompt as a one-line preview: whitespace collapsed, cut at 80 chars.
    def self.preview_of(text)
      norm = text.to_s.gsub(/\s+/, " ").strip
      norm.length > 80 ? "#{norm[0, 80]}…" : norm
    end

    private

    def stringify_message_keys(hash)
      hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    class << self
      private

      # A chat turn's tool_calls get symbol keys too ({id:, name:,
      # arguments:}); the arguments keep the model's string keys.
      def symbolize_message_keys(hash)
        message = hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
        if message[:tool_calls].is_a?(Array)
          message[:tool_calls] = message[:tool_calls].map do |call|
            call.is_a?(Hash) ? call.each_with_object({}) { |(k, v), h| h[k.to_sym] = v } : call
          end
        end
        message
      end

      def session_path(session_id, state_dir:)
        File.join(state_dir, "#{session_id}#{FILE_EXT}")
      end
    end
  end
end
