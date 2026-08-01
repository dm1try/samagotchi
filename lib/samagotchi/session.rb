# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module Samagotchi
  class Session
    METADATA_VERSION = 1
    STATE_SUBDIR = File.join("samagotchi", "sessions")
    FILE_EXT = ".json"

    STATUS_IDLE = "idle"
    STATUS_RUNNING = "running"
    STATUS_COMPLETED = "completed"
    STATUS_ERROR = "error"
    STATUS_STOPPED = "stopped"

    attr_accessor :id, :metadata_version, :mode, :model_name, :working_directory, :messages,
                  :created_at, :updated_at, :status, :last_prompt

    def initialize(id:, mode:, model_name:, working_directory:, messages:, created_at:, updated_at:,
                   metadata_version: METADATA_VERSION, status: STATUS_IDLE, last_prompt: "")
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
    end

    # Build a new, unsaved session.
    def self.new_session(mode:, model_name:, working_directory:)
      now = Time.now.iso8601(3)
      new(
        id: SecureRandom.uuid,
        mode: mode.to_s,
        model_name: model_name.to_s,
        working_directory: working_directory.to_s,
        messages: [],
        created_at: now,
        updated_at: now,
        status: STATUS_IDLE
      )
    end

    # Load a persisted session by its UUID.
    def self.load(session_id, state_dir: default_state_dir)
      path = session_path(session_id, state_dir: state_dir)
      raise ArgumentError, "Session not found: #{session_id}" unless File.exist?(path)

      data = JSON.parse(File.read(path))
      messages = (data["messages"] || []).map { |msg| symbolize_message_keys(msg) }
      new(
        id: data.fetch("id"),
        metadata_version: data.fetch("metadata_version", METADATA_VERSION),
        mode: data.fetch("mode"),
        model_name: data.fetch("model_name"),
        working_directory: data.fetch("working_directory"),
        messages: messages,
        created_at: data.fetch("created_at"),
        updated_at: data.fetch("updated_at"),
        status: data.fetch("status", STATUS_IDLE),
        last_prompt: data.fetch("last_prompt", "")
      )
    rescue JSON::ParserError => e
      raise ArgumentError, "Session file corrupted (#{session_id}): #{e.message}"
    end

    # Return all saved sessions sorted by created_at (oldest first).
    def self.list(state_dir: default_state_dir)
      return [] unless Dir.exist?(state_dir)

      Dir.glob(File.join(state_dir, "*#{FILE_EXT}")).filter_map do |path|
        data = JSON.parse(File.read(path))
        new(
          id: data.fetch("id"),
          metadata_version: data.fetch("metadata_version", METADATA_VERSION),
          mode: data.fetch("mode"),
          model_name: data.fetch("model_name"),
          working_directory: data.fetch("working_directory"),
          messages: [],
          created_at: data.fetch("created_at"),
          updated_at: data.fetch("updated_at"),
          status: data.fetch("status", STATUS_IDLE),
          last_prompt: data.fetch("last_prompt", "")
        )
      rescue JSON::ParserError, KeyError
        nil
      end.sort_by(&:created_at)
    end

    # Persist the session atomically. Updates +updated_at+ in place.
    def save(state_dir: self.class.default_state_dir)
      @updated_at = Time.now.iso8601(3)
      FileUtils.mkdir_p(state_dir)

      path = File.join(state_dir, "#{@id}#{FILE_EXT}")
      temp_path = "#{path}.tmp"

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
        "last_prompt" => @last_prompt
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

    private

    def stringify_message_keys(hash)
      hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    class << self
      private

      def symbolize_message_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end

      def session_path(session_id, state_dir:)
        File.join(state_dir, "#{session_id}#{FILE_EXT}")
      end
    end
  end
end
