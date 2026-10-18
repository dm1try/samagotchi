# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "shellwords"
require "time"
require_relative "../atomic_file"
require_relative "../log"
require_relative "../process_group"
require_relative "shell"
require_relative "task_record"

module Samagotchi
  module Tools
    # Execute requires this file (it hands a command over with adopt), and
    # this one needs Execute only at run time: autoload keeps the two from
    # requiring each other.
    autoload :Execute, File.expand_path("execute", __dir__)

    module TaskRuntime
      TASKS_DIR = File.join("tmp", "tasks")
      METADATA_FILENAME = "task.json"
      OUTPUT_FILENAME = "output.log"
      EXIT_CODE_FILENAME = "exit_code"
      STOP_GRACE_SEC = 3.0
      STOP_POLL_INTERVAL_SEC = 0.1
      METADATA_VERSION = TaskRecord::METADATA_VERSION
      OUTPUT_TAIL_READ_BYTES = 16 * 1024
      SANITIZED_ENV_KEYS = %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_VERSION].freeze
      # Set by chi (Builtins.parent_env); the model's env can't change it.
      MARKER_ENV_KEYS = %w[SAMAGOTCHI_PARENT_SESSION SAMAGOTCHI_SESSION_MODEL SAMAGOTCHI_SESSION_THINKING
                           SAMAGOTCHI_SESSION_REASONING_HISTORY].freeze
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
        # Absolute: the trap writes it wherever the shell is when it exits
        # (a +cwd+, or a cd in the command). Ruby opens output_path here.
        exit_code_path = File.expand_path(File.join(task_dir, EXIT_CODE_FILENAME))

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
        waiter = Process.detach(pid)
        # Read now, compared before each signal: a pid reused later is not this task.
        pid_started = ProcessGroup.start_time(pid)

        record = TaskRecord.running(id: task_id, command: normalized_command, cwd: resolved_cwd, pid: pid,
                                    pid_started: pid_started, started_at: timestamp,
                                    output_path: output_path, exit_code_path: exit_code_path)

        write_record(record)
        record_exit_status(waiter, exit_code_path, task_id: task_id)
        [record, nil]
      rescue StandardError => e
        [nil, "Error: #{e.message}"]
      ensure
        output_io&.close
      end

      # The shell's status from chi's waiter (+waiter+, a Process.detach
      # thread), for a shell whose EXIT trap wrote nothing: one killed by a
      # signal (zsh's sh mode skips the trap on TERM, INT and KILL) gets
      # 128 + the signal, one whose command replaced the trap gets its exit
      # status. Only while this chi runs. A record a refresh finished in
      # between (failed, no exit code) is corrected; a stopped task (its
      # stop flag on disk) is left as task_stop records it.
      # The thread is named EXIT_STATUS_THREAD (a spec joins them before it
      # removes the tasks' folder) here, before it returns: named from
      # inside, a thread not yet scheduled was missed by that join.
      # @return [Thread]
      def record_exit_status(waiter, path, task_id:)
        # Absolute now: safe against a later chdir.
        record_path = File.expand_path(metadata_path(task_id))
        path = File.expand_path(path)
        thread = Thread.new do
          Thread.current.report_on_exception = false
          code = status_code(waiter.value)
          next if code.nil? || record_at(record_path)&.stop_requested_by

          File.write(path, code.to_s) if !File.exist?(path) && Dir.exist?(File.dirname(path))
          correct_finished_record(record_path, read_exit_code(path))
        rescue StandardError => e
          Log.debug(:turn, "task_exit_code_failed", id: task_id, error: e.class.name, msg: e.message)
        end
        thread.name = EXIT_STATUS_THREAD
        thread
      end

      # A Process::Status as a shell reports one: its exit status, or
      # 128 + the signal that killed it.
      def status_code(status)
        return nil unless status

        status.exitstatus || (status.termsig && (128 + status.termsig))
      end

      # record_exit_status's threads' name.
      EXIT_STATUS_THREAD = "task_exit_status"

      # Reasons a refresh finishes a record with when it read no exit code.
      MISSING_CODE_REASONS = ["process_ended_without_exit_code", NOT_CHIS_PROCESS].freeze

      # A record a refresh finished before the exit code was there (failed,
      # exit_code nil, no stop) gets +code+; finished_at is kept.
      def correct_finished_record(record_path, code)
        record = record_at(record_path)
        return unless code && record && !record.running? && record.exit_code.nil? && !record.stop_requested_by
        return unless MISSING_CODE_REASONS.include?(record.stop_reason)

        status = code.zero? ? "completed" : "failed"
        AtomicFile.write(record_path, record_json(record.with(status: status, exit_code: code, stop_reason: nil)))
      end

      def record_at(path)
        return nil unless File.file?(path)

        TaskRecord.from_file(JSON.parse(File.read(path)))
      rescue JSON::ParserError
        nil
      end

      # A record for a command chi already runs: an execute still running at
      # its limit, handed over as a task (Execute::HANDED_OVER), given as a
      # TaskRecord.running whose +started_at+ is the spawn's. Its logs and
      # exit_code file stay where execute put them, so the paths must be
      # absolute; +stderr_path+ is a log of its own (task_wait tails it).
      # The pid's start time is read here, at the hand-over, not at the
      # spawn (a quick execute is spared the ps): read while execute's
      # detach waiter is still running, so the pid is still its child.
      # @param task [TaskRecord]
      # @return [Array(TaskRecord, nil), Array(nil, String)] the record, or an error
      def adopt(task)
        id = task.id
        return [nil, "Error: invalid task id: #{id}"] unless TASK_ID_SHAPE.match?(id.to_s)
        return [nil, "Error: task already exists: #{id}"] if File.exist?(metadata_path(id))

        relative = %i[output_path stderr_path exit_code_path].find { |key| !File.absolute_path?(task.public_send(key).to_s) }
        return [nil, "Error: #{relative} must be absolute: #{task.public_send(relative)}"] if relative

        pid = task.pid
        return [nil, "Error: not a process chi can stop: #{pid.inspect}"] unless ProcessGroup.signalable?(pid)

        cwd = task.cwd
        record = task.with(command: task.command.to_s.strip, cwd: File.expand_path(cwd.to_s.empty? ? Dir.pwd : cwd),
                           pid_started: ProcessGroup.start_time(pid), handed_over_by: Execute::NAME)
        write_record(record)
        [record, nil]
      rescue StandardError => e
        [nil, "Error: #{e.message}"]
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
        end.compact.sort_by { |record| record.created_at.to_s }.reverse
      end

      # The tasks this conversation started that are still running: its
      # task_create calls and the executes it handed over at their limit.
      # Only those results count: records are shared by every session in the
      # worker's cwd, and task_list shows them all.
      # A native tool_response joins its calls' results with "---".
      # @return [Array<Hash>] {id:, command:}, oldest first
      def running_created_in(messages)
        created_ids_in(messages).filter_map do |id|
          record, _error = get_record(id)
          { id: id, command: record.command.to_s } if record&.running?
        end
      end

      # The ids of every task this conversation started (task_create, a
      # handed-over execute), whatever their status now, oldest first.
      # @return [Array<String>]
      def created_ids_in(messages)
        Array(messages).flat_map do |message|
          next [] unless (message[:role] || message["role"]).to_s == "tool_response"

          (message[:content] || message["content"]).to_s.split("\n\n---\n\n").filter_map do |block|
            block[CREATED_BLOCK, 1] || handed_over_id(block)
          end
        end.uniq
      end

      # A task_create result as the model gets it: its "[task_create]" lead,
      # after the one "ran as: …" line a gate-corrected call has.
      RAN_AS_LINE = "(?:ran as: [^\n]*\n)?"
      CREATED_BLOCK = /\A#{RAN_AS_LINE}\[task_create\]\ntask_id: (\S+)/
      CREATED_OUTPUT = /\A#{RAN_AS_LINE}(?:\[task_create\]\n)?task_id: (\S+)/

      # The task id of a tool output that started a task, the "[tool]" lead
      # optional (a UI's row has it or not): a task_create's, or an execute's
      # handed_over_id. nil for any other tool or output.
      # @return [String, nil]
      def created_id(tool, text)
        case tool
        when "task_create" then text.to_s[CREATED_OUTPUT, 1]
        when Execute::NAME then handed_over_id(text)
        end
      end

      # The task id an execute's hand-over result names: anchored on its
      # first line (Execute::HANDED_OVER), never a "task_id:" line anywhere,
      # which the command's own output can print. The "[execute]" lead and
      # a "ran as: …" line before it are optional. web/public/task_stop.js
      # has the JS twin (handedOverId).
      # @return [String, nil]
      def handed_over_id(text)
        text = text.to_s
        # A regexp raises on bytes that aren't UTF-8 (a command's raw output).
        text = text.scrub unless text.valid_encoding?
        text[handed_over_pattern, 1]
      end

      def handed_over_pattern
        @handed_over_pattern ||= /\A#{RAN_AS_LINE}(?:\[#{Execute::NAME}\]\n)?#{Regexp.escape(Execute::HANDED_OVER)} \d+s limit:[^\n]*\ntask_id: (\S+)/
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

        command = TaskRecord.from_file(JSON.parse(File.read(path)))&.command
        command.is_a?(String) && !command.strip.empty? ? command : nil
      rescue StandardError
        nil
      end

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
        return [refreshed, nil] unless refreshed.running?

        # Checked again just before the signal: never a group chi didn't start.
        return [mark_not_chis(refreshed), nil] unless chis_group?(refreshed, started: refreshed.pid_started)

        flagged = refreshed.with(stop_requested_by: by.to_s)
        write_record(flagged)

        # A group that isn't ours (EPERM) is an error, not a stop.
        ProcessGroup.stop(flagged.pid, grace: STOP_GRACE_SEC, poll: STOP_POLL_INTERVAL_SEC, quiet: [Errno::ESRCH])

        updated = mark_stopped(refresh_record(flagged))
        write_record(updated)

        [updated, nil]
      rescue StandardError => e
        [nil, "Error: #{e.message}"]
      end

      def refresh_record(record)
        return record unless record.running?

        pid = record.pid
        return record if chis_group?(record, started: record.pid_started)
        # Gone: its exit code says how it ended.
        return mark_finished_without_exit_code(record) if ProcessGroup.signalable?(pid) && !ProcessGroup.alive?(pid)

        mark_not_chis(record)
      end

      # Whether the record's pid still leads its own group. With +started+
      # (the start time recorded at task_create), also the same process: a
      # ps per call on macOS (~5 ms), asked by each refresh (task_list,
      # task_get, each task_wait poll) so a reused pid reads as exited, and
      # by task_stop again just before the signal.
      def chis_group?(record, started: nil) = ProcessGroup.leader?(record.pid, started: started)

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

        TaskRecord.from_file(JSON.parse(File.read(path)))
      rescue JSON::ParserError
        nil
      end

      def write_record(record)
        ensure_tasks_dir
        dir = task_dir_for(record.id)
        FileUtils.mkdir_p(dir)

        path = File.join(dir, METADATA_FILENAME)
        AtomicFile.write(path, record_json(record))
      end

      def record_json(record) = JSON.pretty_generate(record.to_file) + "\n"

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

      # The command with an EXIT trap set before it that writes the shell's
      # exit status to +exit_code_path+. A prefix, not lines after the
      # command: a trailing "\\" or "|" in the command would swallow those,
      # and an `exit N` or a `set -e` failure would skip them. A command that
      # sets its own EXIT trap replaces this one, and a shell killed by a
      # signal skips it (zsh's sh mode, on TERM, INT and KILL): no exit_code
      # file from the shell then. The waiter of the chi that started it
      # writes the code instead (record_exit_status: the status, or
      # 128 + the signal); with that chi gone too, the task ends failed with
      # process_ended_without_exit_code.
      def wrapped_shell_command(command, exit_code_path)
        write = %(printf "%s" "$?" > #{Shellwords.escape(exit_code_path)})
        "trap #{Shellwords.escape(write)} EXIT\n#{command}\n"
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
        return record unless record.running?

        exit_code = read_exit_code(record.exit_code_path)
        record =
          if record.stop_requested_by
            mark_stopped(record.with(exit_code: exit_code))
          elsif exit_code.nil?
            record.with(status: "failed", exit_code: nil, stop_reason: record.stop_reason || missing_reason)
          elsif exit_code.zero?
            record.with(status: "completed", exit_code: 0)
          else
            record.with(status: "failed", exit_code: exit_code)
          end
        record = record.with(finished_at: record.finished_at || timestamp)
        write_record(record)
        record
      end

      # The disk copy when it is newer than +record+: already finished, or
      # flagged by a stop that started after +record+ was read.
      def current_record(record)
        disk = load_record(record.id)
        return record unless disk
        return disk if !disk.running? || disk.stop_requested_by

        record
      end

      def mark_stopped(record)
        record.with(status: "stopped", stop_reason: "stopped_by_#{record.stop_requested_by}",
                    finished_at: record.finished_at || timestamp)
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
