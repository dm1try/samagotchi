# frozen_string_literal: true

module Samagotchi
  module Tools
    # A background task's record, as TaskRuntime keeps it in
    # tmp/tasks/<id>/task.json. Read with .from_file, written with #to_file;
    # an update is a #with. The values are as on disk: times are iso8601
    # strings, +pid+ whatever the file holds (a hand-edited one may not be
    # a number; TaskRuntime never signals that).
    #
    # The file keeps its key order (the members' order) and leaves out the
    # optional keys while unset: +stderr_path+ and +handed_over_by+ (only a
    # handed-over execute has them) and +stop_requested_by+ (only once a
    # stop started). bundles/slow-commands reads these files on its own.
    TaskRecord = Data.define(
      :metadata_version, :id, :command, :cwd, :workspace_root, :status, :pid, :pid_started,
      :created_at, :started_at, :finished_at, :exit_code, :stop_reason,
      :output_path, :stderr_path, :exit_code_path, :handed_over_by, :stop_requested_by
    ) do
      self::METADATA_VERSION = 1
      self::OPTIONAL = %i[stderr_path handed_over_by stop_requested_by].freeze

      # A record for a task that just started (task_create), or that an
      # execute hands over (TaskRuntime.adopt fills in +pid_started+ then).
      # @param started_at [String] iso8601; also its +created_at+
      def self.running(id:, command:, cwd:, pid:, started_at:, output_path:, exit_code_path:, pid_started: nil,
                       stderr_path: nil, handed_over_by: nil)
        new(metadata_version: self::METADATA_VERSION, id: id, command: command, cwd: cwd, workspace_root: Dir.pwd,
            status: "running", pid: pid, pid_started: pid_started, created_at: started_at, started_at: started_at,
            finished_at: nil, exit_code: nil, stop_reason: nil, output_path: output_path, stderr_path: stderr_path,
            exit_code_path: exit_code_path, handed_over_by: handed_over_by, stop_requested_by: nil)
      end

      # @param data [Hash] the parsed task.json; a key it lacks reads nil
      # @return [TaskRecord, nil] nil when +data+ isn't an object
      def self.from_file(data)
        return nil unless data.is_a?(Hash)

        new(**members.to_h { |key| [key, data[key.to_s]] })
      end

      # @return [Hash] the task.json object, string keys in member order
      def to_file
        to_h.reject { |key, value| value.nil? && self.class::OPTIONAL.include?(key) }.transform_keys(&:to_s)
      end

      # A task id as people read it: the random part a task_create id ends
      # with (TaskRuntime.generate_task_id starts it with the time, the same
      # for every task that second), else its first 8 chars. The web's
      # turn_events.js has the JS twin (shortTaskId).
      def self.short_id(id)
        id = id.to_s
        id[/-(\h{8})\z/, 1] || id[0, 8]
      end

      def running? = status == "running"

      def stopped_by_user? = stop_reason == "stopped_by_user"
    end
  end
end
