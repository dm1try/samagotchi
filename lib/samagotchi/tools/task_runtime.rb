# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "shellwords"
require "time"
require_relative "../atomic_file"
require_relative "../process_group"
require_relative "shell"

module Samagotchi
  module Tools
    module TaskRuntime
      TASKS_DIR = File.join("tmp", "tasks")
      METADATA_FILENAME = "task.json"
      OUTPUT_FILENAME = "output.log"
      EXIT_CODE_FILENAME = "exit_code"
      STOP_GRACE_SEC = 3.0
      STOP_POLL_INTERVAL_SEC = 0.1
      METADATA_VERSION = 1
      OUTPUT_TAIL_READ_BYTES = 16 * 1024
      SANITIZED_ENV_KEYS = %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_VERSION].freeze
      # Set by chi (Builtins.parent_env); the model's env can't change it.
      MARKER_ENV_KEYS = %w[SAMAGOTCHI_PARENT_SESSION SAMAGOTCHI_SESSION_MODEL].freeze
      # task_wait and task_get add it to a task the user stopped (the web's
      # stop-task button), so the model doesn't rerun the job.
      # A record whose pid isn't a process group chi started (missing, 0, 1,
      # not a number, or a pid another process reuses): nothing is signalled.
      NOT_CHIS_PROCESS = "the task's process is gone or isn't the one chi started"
      USER_STOP_NOTE = "note: the user stopped this task; don't restart it unless they ask."

      module_function

      # @param marker_env [Hash] chi's own variables, set over the model's +env+
      def create_task(command, cwd: nil, env: nil, marker_env: {})
        normalized_command = command.to_s.strip
        return [nil, "Error: command is required"] if normalized_command.empty?

        resolved_cwd = normalize_cwd(cwd)
        return [nil, "Error: cwd not found: #{resolved_cwd}"] unless Dir.exist?(resolved_cwd)

        spawn_env, env_error = spawn_env_for(env)
        return [nil, env_error] if env_error

        spawn_env = spawn_env.merge(marker_env || {})

        task_id = generate_task_id
        task_dir = task_dir_for(task_id)
        output_path = File.join(task_dir, OUTPUT_FILENAME)
        exit_code_path = File.join(task_dir, EXIT_CODE_FILENAME)

        FileUtils.mkdir_p(task_dir)

        # The child writes to it; the ensure below closes the parent's copy.
        output_io = File.open(output_path, "a") # rubocop:disable Style/FileOpen
        output_io.sync = true

        wrapped_command = wrapped_shell_command(normalized_command, exit_code_path)
        # Non-login, the shell Execute uses too (Shell).
        pid = ProcessGroup.spawn(
          spawn_env,
          *Shell.argv(wrapped_command),
          chdir: resolved_cwd,
          out: output_io,
          err: output_io
        )
        Process.detach(pid)
        # Read now, compared before each signal: a pid reused later is not this task.
        pid_started = ProcessGroup.start_time(pid)

        now = timestamp
        record = {
          "metadata_version" => METADATA_VERSION,
          "id" => task_id,
          "command" => normalized_command,
          "cwd" => resolved_cwd,
          "workspace_root" => Dir.pwd,
          "status" => "running",
          "pid" => pid,
          "pid_started" => pid_started,
          "created_at" => now,
          "started_at" => now,
          "finished_at" => nil,
          "exit_code" => nil,
          "stop_reason" => nil,
          "output_path" => output_path,
          "exit_code_path" => exit_code_path
        }

        write_record(record)
        [record, nil]
      rescue StandardError => e
        [nil, "Error: #{e.message}"]
      ensure
        output_io&.close
      end

      def list_records
        ensure_tasks_dir
        task_dirs = Dir.glob(File.join(TASKS_DIR, "*"))
                       .select { |path| File.directory?(path) }

        task_dirs.map do |task_dir|
          id = File.basename(task_dir)
          record = load_record(id)
          next nil unless record

          refresh_record(record)
        end.compact.sort_by { |record| record["created_at"].to_s }.reverse
      end

      # The tasks this conversation's task_create calls started that are
      # still running. Only task_create results count: records are shared by
      # every session in the worker's cwd, and task_list shows them all.
      # A native tool_response joins its calls' results with "---".
      # @return [Array<Hash>] {id:, command:}, oldest first
      def running_created_in(messages)
        created_ids_in(messages).filter_map do |id|
          record, _error = get_record(id)
          { id: id, command: record["command"].to_s } if record&.fetch("status") == "running"
        end
      end

      # The ids of every task this conversation's task_create calls started,
      # whatever their status now, oldest first.
      # @return [Array<String>]
      def created_ids_in(messages)
        Array(messages).flat_map do |message|
          next [] unless (message[:role] || message["role"]).to_s == "tool_response"

          (message[:content] || message["content"]).to_s.split("\n\n---\n\n").filter_map do |block|
            block[/\A\[task_create\]\ntask_id: (\S+)/, 1]
          end
        end.uniq
      end

      # A task id as task_create makes them: no path parts.
      TASK_ID = /\A[A-Za-z0-9_-]+\z/

      # The command of the task +task_id+ under +root+ (a session's working
      # directory) as its record has it, for a UI row's title; nil for no
      # such task or an unreadable record. Reads the record only (no
      # refresh), so it is cheap and never fails.
      # @return [String, nil]
      def command_of(task_id, root: Dir.pwd)
        id = task_id.to_s.strip
        return nil unless id.match?(TASK_ID)

        path = File.join(root || Dir.pwd, TASKS_DIR, id, METADATA_FILENAME)
        return nil unless File.file?(path)

        command = JSON.parse(File.read(path))["command"]
        command.is_a?(String) && !command.strip.empty? ? command : nil
      rescue StandardError
        nil
      end

      def stopped_by_user?(record) = record["stop_reason"] == "stopped_by_user"

      def get_record(task_id)
        record = load_record(task_id)
        return [nil, not_found(task_id)] unless record

        [refresh_record(record), nil]
      rescue StandardError => e
        [nil, "Error: #{e.message}"]
      end

      def output_tail_lines(path, line_count)
        return "" unless File.file?(path)

        size = File.size(path)
        offset = [size - OUTPUT_TAIL_READ_BYTES, 0].max
        content = File.open(path, "rb") do |file|
          file.seek(offset)
          file.read
        end
        content = content.split("\n", 2).last.to_s if offset.positive?
        content.lines.last(line_count).join
      end

      # A requested stop ends as "stopped" whatever the exit code: the flag
      # is on disk before the TERM, so a reader refreshing the record while
      # the group dies records the stop, not a failure.
      # @param by [String] "model" (task_stop) or "user" (the web's button)
      def stop_task(task_id, by:)
        record = load_record(task_id)
        return [nil, not_found(task_id)] unless record

        refreshed = refresh_record(record)
        return [refreshed, nil] unless refreshed["status"] == "running"

        pid = refreshed["pid"]
        # Checked again just before the signal: never a group chi didn't start.
        return [mark_not_chis(refreshed), nil] unless chis_group?(refreshed, started: refreshed["pid_started"])

        refreshed["stop_requested_by"] = by.to_s
        write_record(refreshed)

        # A group that isn't ours (EPERM) is an error, not a stop.
        ProcessGroup.stop(pid, grace: STOP_GRACE_SEC, poll: STOP_POLL_INTERVAL_SEC, quiet: [Errno::ESRCH])

        updated = mark_stopped(refresh_record(refreshed))
        write_record(updated)

        [updated, nil]
      rescue StandardError => e
        [nil, "Error: #{e.message}"]
      end

      def refresh_record(record)
        return record unless record["status"] == "running"

        pid = record["pid"]
        return record if chis_group?(record)
        # Gone: its exit code says how it ended.
        return mark_finished_without_exit_code(record) if ProcessGroup.signalable?(pid) && !ProcessGroup.alive?(pid)

        mark_not_chis(record)
      end

      # Whether the record's pid still leads its own group. With +started+
      # (the start time recorded at task_create), also the same process: a
      # ps per call, so only task_stop asks it, just before the signal;
      # a refresh (each task_wait poll, task_list) checks the group only.
      def chis_group?(record, started: nil) = ProcessGroup.leader?(record["pid"], started: started)

      # A running record whose pid isn't a group chi started (NOT_CHIS_PROCESS)
      # ends as failed, unless its exit code or a stop on disk says more.
      def mark_not_chis(record)
        mark_finished_without_exit_code(record, missing_reason: NOT_CHIS_PROCESS)
      end

      # A session id (a uuid) is never a task's: task ids are a timestamp
      # and hex (20261005093000-1a2b3c4d).
      SESSION_ID_SHAPE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      # A model mixing up ids (Qwen passes session ids to task_get and
      # task_stop) is told which kind it passed and where task ids come from.
      def not_found(task_id)
        error = "Error: task not found: #{task_id}"
        return error unless SESSION_ID_SHAPE.match?(task_id.to_s)

        "#{error} (that is a session id; task ids come from task_create, and task_list lists them)"
      end

      # Exactly the shape generate_task_id makes. Anything else (../x, an
      # absolute path) is no task, so a model's id never leaves tmp/tasks.
      TASK_ID_SHAPE = /\A\d{14}-\h{8}\z/

      def load_record(task_id)
        return nil unless TASK_ID_SHAPE.match?(task_id.to_s)

        path = metadata_path(task_id)
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      def write_record(record)
        ensure_tasks_dir
        dir = task_dir_for(record.fetch("id"))
        FileUtils.mkdir_p(dir)

        path = File.join(dir, METADATA_FILENAME)
        AtomicFile.write(path, JSON.pretty_generate(record) + "\n")
      end

      def metadata_path(task_id)
        File.join(task_dir_for(task_id), METADATA_FILENAME)
      end

      def task_dir_for(task_id)
        File.join(TASKS_DIR, task_id.to_s)
      end

      def ensure_tasks_dir
        FileUtils.mkdir_p(TASKS_DIR)
      end

      def generate_task_id
        loop do
          candidate = "#{Time.now.utc.strftime("%Y%m%d%H%M%S")}-#{SecureRandom.hex(4)}"
          return candidate unless File.exist?(metadata_path(candidate))
        end
      end

      def normalize_cwd(cwd)
        value = cwd.to_s.strip
        value.empty? ? Dir.pwd : File.expand_path(value)
      end

      def wrapped_shell_command(command, exit_code_path)
        escaped_exit_code_path = Shellwords.escape(exit_code_path)
        <<~SH
          #{command}
          status=$?
          printf "%s" "$status" > #{escaped_exit_code_path}
          exit "$status"
        SH
      end

      def sanitized_spawn_env
        # Running from temporary directories can inherit Bundler-specific env
        # (for example RUBYOPT=-rbundler/setup) that breaks plain `ruby -e`.
        {
          "RUBYOPT" => sanitized_rubyopt,
          "RUBYLIB" => nil,
          "BUNDLE_GEMFILE" => nil,
          "BUNDLE_BIN_PATH" => nil,
          "BUNDLER_VERSION" => nil
        }
      end

      def spawn_env_for(overrides)
        return [sanitized_spawn_env, nil] if overrides.nil? || overrides.to_s.empty?

        overrides = JSON.parse(overrides) if overrides.is_a?(String)
        return [nil, "Error: env must be an object"] unless overrides.is_a?(Hash)

        normalized = {}
        overrides.each do |key, value|
          return [nil, "Error: env keys and values must be strings"] unless key.is_a?(String) && value.is_a?(String)
          return [nil, "Error: env keys and values cannot contain NUL bytes"] if key.include?("\0") || value.include?("\0")
          return [nil, "Error: env key is reserved: #{key}"] if SANITIZED_ENV_KEYS.include?(key) || MARKER_ENV_KEYS.include?(key)

          normalized[key] = value
        end

        [sanitized_spawn_env.merge(normalized), nil]
      rescue JSON::ParserError
        [nil, "Error: env must be a JSON object"]
      end

      def sanitized_rubyopt
        rubyopt = ENV["RUBYOPT"].to_s
        return nil if rubyopt.empty?

        filtered = rubyopt.split(/\s+/).reject do |arg|
          arg == "-rbundler/setup" || arg.match?(%r{\A-r.*bundler/setup\z})
        end
        return nil if filtered.empty?

        filtered.join(" ")
      end

      def mark_finished_without_exit_code(record, missing_reason: "process_ended_without_exit_code")
        record = current_record(record)
        return record unless record["status"] == "running"

        exit_code = read_exit_code(record["exit_code_path"])

        if record["stop_requested_by"]
          record["exit_code"] = exit_code
          mark_stopped(record)
        elsif exit_code.nil?
          record["status"] = "failed"
          record["exit_code"] = nil
          record["stop_reason"] ||= missing_reason
        elsif exit_code.zero?
          record["status"] = "completed"
          record["exit_code"] = 0
        else
          record["status"] = "failed"
          record["exit_code"] = exit_code
        end

        record["finished_at"] ||= timestamp
        write_record(record)
        record
      end

      # The disk copy when it is newer than +record+: already finished, or
      # flagged by a stop that started after +record+ was read.
      def current_record(record)
        disk = load_record(record.fetch("id"))
        return record unless disk
        return disk if disk["status"] != "running" || disk["stop_requested_by"]

        record
      end

      def mark_stopped(record)
        record["status"] = "stopped"
        record["stop_reason"] = "stopped_by_#{record["stop_requested_by"]}"
        record["finished_at"] ||= timestamp
        record
      end

      def read_exit_code(path)
        return nil if path.to_s.empty? || !File.exist?(path)

        Integer(File.read(path).strip, exception: false)
      rescue StandardError => _e
        nil
      end

      def timestamp
        Time.now.utc.iso8601
      end
    end
  end
end
