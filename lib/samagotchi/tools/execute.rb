# frozen_string_literal: true

require "fileutils"
require_relative "../config"
require_relative "../log"
require_relative "../paths"
require_relative "../process_group"
require_relative "output_guardrails"
require_relative "shell"
require_relative "task_runtime"

module Samagotchi
  module Tools
    # Runs an arbitrary shell command and returns stdout, stderr, and exit code.
    # The model can use this to execute Ruby snippets, run RSpec, or any other
    # shell command needed during code assistance via the memory-reliant harness.
    #
    # Examples the model can emit:
    #   <tool name="execute">ruby -e 'puts 2 + 2'</tool>
    #   <tool name="execute">bundle exec rspec spec/some_spec.rb --no-color</tool>
    #   <tool name="execute">ruby path/to/script.rb</tool>
    class Execute
      NAME        = "execute"
      TIMEOUT_SEC = 120
      STOP_GRACE_SEC = 1.0
      STOP_POLL_INTERVAL_SEC = 0.05
      WAIT_SLICE_SEC = 0.2
      NOT_RUN_ON_STOP = "Error: not run, the user stopped the turn"
      # The first words of a command the user's Stop killed.
      STOPPED_BY_USER = "Error: command stopped by the user"
      # The same two when a signal to chi (a worker's TERM, HUP or INT)
      # stopped the turn: its cancel reason is :signal.
      NOT_RUN_ON_SIGNAL = "Error: not run, a signal to chi stopped the turn"
      STOPPED_BY_SIGNAL = "Error: command stopped by a signal to chi"
      # The same two when a session stop (chi sessions stop, the web's stop,
      # a parent stopping its delegate) canceled the turn: :session_stopped.
      NOT_RUN_ON_SESSION_STOP = "Error: not run, the session was stopped"
      STOPPED_BY_SESSION_STOP = "Error: command stopped as the session was stopped"
      # The first words of a command killed at the limit in kill mode (hooks
      # match on it).
      TIMEOUT_PREFIX = "Error: command timed out after"
      # Only in kill mode (execute.on_timeout: kill, the !cmd bang): in task
      # mode a command at the limit is handed over (HANDED_OVER).
      TIMEOUT_HINT = "(killed at the limit; for a long command use task_create, then task_wait)"
      # How long the output may stay open once the shell has exited: a
      # `server &` child keeps the pipes, and the read would never end.
      BACKGROUND_GRACE_SEC = 1.5
      BACKGROUND_HINT = "(a background process kept the output open and was stopped; " \
                        "to keep a server or long job running, start it with task_create)"
      # It had left the process group (setsid), so it is still running.
      BACKGROUND_DETACHED_HINT = "(a background process kept the output open and was left running; " \
                                 "to keep a server or long job running, start it with task_create)"
      # What a command still running at the limit gets (execute.on_timeout):
      # :task hands it over as a task (HANDED_OVER), :kill stops it.
      ON_TIMEOUT = %i[task kill].freeze
      # How many of the last lines of each log a hand-over shows.
      HAND_OVER_TAIL_LINES = 10
      # Where each command's logs and exit_code file live while it runs, and
      # after, for a handed-over one: <state dir>/execute/<id>/ (outside the
      # workspace, so git and `rm -rf tmp` never see them).
      LOGS_DIRNAME = "execute"
      STDOUT_LOG = "stdout.log"
      STDERR_LOG = "stderr.log"
      # A handed-over command's dir names its task.json here (the sweep).
      BACK_POINTER = "task"
      # The sweep (sweep_leftovers): a dir no command holds any more, with
      # no back-pointer after a day (chi died mid-execute), or whose task
      # record is gone or is older than RETENTION_DAYS.
      ORPHAN_AGE_SEC = 24 * 3600
      RETENTION_DAYS = 14
      # The first words of a command still running at the limit and handed
      # over as a task (handed_over_line). TaskRuntime.handed_over_id, the
      # web's task_stop.js and the slow-commands bundle match on them.
      HANDED_OVER = "Still running at the"

      def self.name        = NAME

      # A hand-over result's first line; its "task_id: …" line follows it.
      def self.handed_over_line(limit_sec)
        "#{HANDED_OVER} #{Integer(limit_sec)}s limit: moved to a background task, not killed."
      end

      # @param cancelled [#call] true once the user stopped the turn: the
      #   command is killed (or not started) and its output so far returned
      # @param stop_reason [#call] the stop's reason (:signal: a signal to
      #   chi, :session_stopped: a session stop, which the result then names
      #   instead of the user)
      # @param env [Hash, nil] added to the command's environment, over
      #   chi's Ruby/Bundler variables scrubbed as task_create scrubs them
      #   (TaskRuntime.sanitized_spawn_env); chi's callers build it, so it
      #   may set those keys (task_create refuses them from the model)
      # @param on_timeout [Symbol, String, nil] :task or :kill (ON_TIMEOUT);
      #   nil reads execute.on_timeout
      def self.call(command, cwd: nil, cancelled: -> { false }, stop_reason: -> {}, env: nil, on_timeout: nil)
        return not_run(stop_reason) if cancelled.call

        command = command.strip
        resolved_cwd = resolve_cwd(cwd)
        return "Error: cwd not found: #{resolved_cwd}" unless resolved_cwd

        sweep_leftovers_once
        timeout_sec = timeout_seconds
        stdout, stderr, status, held_open = run_command(command, timeout_sec: timeout_sec, cwd: resolved_cwd, cancelled: cancelled,
                                                                 env: env, on_timeout: on_timeout_mode(on_timeout))

        stdout_block = output_block("stdout", stdout)
        stderr_block = output_block("stderr", stderr)
        telemetry = telemetry_lines_for([stdout_block, stderr_block].join("\n"))

        parts = []
        parts.concat(telemetry) unless telemetry.empty?
        parts << stdout_block unless stdout_block.nil?
        parts << stderr_block unless stderr_block.nil?
        # "(no output)" says nothing matched: a bare "exit: 0" reads to a
        # model as "done, something happened".
        silent = stdout_block.nil? && stderr_block.nil?
        parts << (silent ? "exit: #{status.exitstatus} (no output)" : "exit: #{status.exitstatus}")
        parts << (held_open == :detached ? BACKGROUND_DETACHED_HINT : BACKGROUND_HINT) if held_open
        parts.join("\n")
      rescue HandedOver => e
        e.text
      rescue CommandTimedOut => e
        # Keep the "Error:" first line (callers classify on it), say how to run
        # a long command, and return whatever it printed before it was killed.
        stopped_result("#{TIMEOUT_PREFIX} #{timeout_sec}s\n#{TIMEOUT_HINT}", e)
      rescue CommandCancelled => e
        first = STOPPED_BY.fetch(stop_reason.call, STOPPED_BY_USER)
        stopped_result("#{first} after #{e.elapsed.round}s (killed; rerun it if still needed)", e)
      rescue StandardError => e
        "Error: #{e.message}"
      end

      # What a command the turn's stop kept from starting returns.
      def self.not_run(stop_reason) = NOT_RUN.fetch(stop_reason.call, NOT_RUN_ON_STOP)

      # The texts above by the stop's reason; any other is the user's Stop.
      NOT_RUN = { signal: NOT_RUN_ON_SIGNAL, session_stopped: NOT_RUN_ON_SESSION_STOP }.freeze
      STOPPED_BY = { signal: STOPPED_BY_SIGNAL, session_stopped: STOPPED_BY_SESSION_STOP }.freeze

      # execute.on_timeout, or the caller's: :task (the default) or :kill.
      def self.on_timeout_mode(value)
        value = Samagotchi::Config.get("execute.on_timeout") if value.nil? || value.to_s.strip.empty?
        mode = value.to_s.strip.downcase.to_sym
        ON_TIMEOUT.include?(mode) ? mode : :task
      end
      private_class_method :on_timeout_mode

      def self.stopped_result(first_line, error)
        parts = [first_line]
        parts << output_block("stdout", error.stdout)
        parts << output_block("stderr", error.stderr)
        parts.compact.join("\n")
      end
      private_class_method :stopped_result

      # The command's stdout and stderr go to two logs in its dir under the
      # state dir (logs_root), not to pipes: a command handed over at the
      # limit keeps writing there after execute (or chi) is gone. chi holds
      # each log with a shared flock across the spawn, so the command's
      # processes inherit open files a fresh exclusive flock can't get while
      # any of them still has one (held?). stdin is /dev/null: a background
      # group reading the terminal would stop on SIGTTIN. The shell is
      # detached at once; the waiter it returns reaps it, also after a
      # hand-over, so it never stays a zombie.
      def self.run_command(command, timeout_sec:, cwd:, cancelled: -> { false }, env: nil, on_timeout: :task)
        status = nil
        timed_out = false
        was_cancelled = false
        aborted = false
        handed_over = false
        held_open = false
        started_at = Time.now
        started = monotonic_time
        deadline = started + timeout_sec

        id = TaskRuntime.generate_task_id
        dir = File.join(logs_root, id)
        FileUtils.mkdir_p(dir)
        logs = [File.join(dir, STDOUT_LOG), File.join(dir, STDERR_LOG)]
        exit_code_path = File.join(dir, TaskRuntime::EXIT_CODE_FILENAME)
        begin
          pid = spawn_logged(command, env: env, cwd: cwd, logs: logs, exit_code_path: exit_code_path)
        rescue StandardError => e
          Log.info(:turn, "execute_spawn_failed", id: id, error: e.class.name)
          FileUtils.rm_rf(dir)
          raise
        end
        # Never the command line or its output: a command may carry a
        # secret, and its output is the tool result's.
        Log.debug(:turn, "execute_started", id: id, pid: pid, timeout_sec: timeout_sec, on_timeout: on_timeout)
        wait_thr = Process.detach(pid)
        # A stop is done once the shell is reaped and nothing holds the logs:
        # a child that ignores TERM keeps them, so the stop goes on to KILL.
        stopped = -> { !wait_thr.alive? && !held?(logs) }

        begin
          until wait_thr.join(WAIT_SLICE_SEC)
            if cancelled.call
              was_cancelled = true
              break
            elsif monotonic_time > deadline
              timed_out = true
              break
            end
          end
          # Ended right at the deadline: finished, not timed out.
          timed_out = false if timed_out && !wait_thr.alive?
          if timed_out && on_timeout == :task
            task = TaskRecord.running(id: id, command: command, cwd: cwd, pid: pid, started_at: started_at.utc.iso8601,
                                      output_path: logs[0], stderr_path: logs[1], exit_code_path: exit_code_path)
            text = hand_over(task, waiter: wait_thr, timeout_sec: timeout_sec, dir: dir)
            if text
              handed_over = true
              Log.info(:turn, "execute_handed_over", id: id, after_sec: timeout_sec)
              raise HandedOver, text
            end
            # Not adopted because it ended meanwhile: finished too.
            timed_out = false unless wait_thr.alive?
          end
          terminate_process_tree(pid, stopped: stopped) if timed_out || was_cancelled
          wait_thr.join
          status = wait_thr.value
        rescue HandedOver
          raise
        rescue Exception => e # rubocop:disable Lint/RescueException -- kill the child, then re-raise
          # An Interrupt (or anything else) mid-wait: the child is in its own
          # process group, so it never saw the SIGINT. Kill it.
          aborted = true
          Log.info(:turn, "execute_aborted", id: id, error: e.class.name)
          terminate_process_tree(pid, stopped: stopped) if wait_thr.alive?
          raise
        ensure
          unless handed_over
            # The shell is gone; a child it put in the background may still
            # hold the logs. Already stopped (timeout, Stop, an exception): no
            # more checks.
            unless timed_out || was_cancelled || aborted
              outcome, held_open = background_check(pid, logs, deadline: deadline, cancelled: cancelled)
              was_cancelled = true if outcome == :cancelled
              # Under on_timeout: task too: the shell is reaped, there is no
              # leader left to hand over.
              timed_out = true if outcome == :timeout
            end
            stdout_text, stderr_text = logs.map { |path| read_log(path) }
            # A holder left running (setsid) still writes there: the dir
            # stays, and the sweep removes it once no one holds the logs.
            FileUtils.rm_rf(dir) unless held_open == :detached
          end
        end

        elapsed_ms = ((monotonic_time - started) * 1000).round
        if timed_out
          Log.info(:turn, "execute_timed_out", id: id, after_sec: timeout_sec)
          raise CommandTimedOut.new(stdout_text, stderr_text)
        end
        if was_cancelled
          Log.info(:turn, "execute_stopped", id: id, ms: elapsed_ms)
          raise CommandCancelled.new(stdout_text, stderr_text, monotonic_time - started)
        end

        Log.debug(:turn, "execute_finished", id: id, exit: status&.exitstatus, ms: elapsed_ms,
                                             background: held_open || nil)
        [stdout_text, stderr_text, status, held_open]
      end
      private_class_method :run_command

      # @return [Integer] the pid of the shell, which leads its own group
      def self.spawn_logged(command, env:, cwd:, logs:, exit_code_path:)
        # Append mode: the shell and its background children share the open
        # file, and each write lands at the end.
        ios = logs.map { |path| File.open(path, "a") }
        ios.each { |io| io.flock(File::LOCK_SH) }
        ProcessGroup.spawn(TaskRuntime.sanitized_spawn_env.merge(env || {}), *Shell.argv(TaskRuntime.wrapped_shell_command(command, exit_code_path)),
                           chdir: cwd, in: File::NULL, out: ios[0], err: ios[1])
      ensure
        ios&.each(&:close)
      end
      private_class_method :spawn_logged

      # After the shell exited: a background child still holding the logs
      # (`cmd &`) gets BACKGROUND_GRACE_SEC, then its group is stopped
      # (BACKGROUND_HINT), unless it left the group (setsid) and holds them
      # still (BACKGROUND_DETACHED_HINT, left running). One that holds none
      # (`nohup cmd >f 2>&1 &`) is left alone, with no note.
      # @return [Array(Symbol, Symbol|false)] the outcome (:done, :grace,
      #   :timeout, :cancelled) and the hint (:stopped, :detached or false)
      def self.background_check(pgid, logs, deadline:, cancelled:)
        return [:done, false] unless held?(logs)

        outcome = await_release(logs, until_time: monotonic_time + BACKGROUND_GRACE_SEC, deadline: deadline, cancelled: cancelled)
        return [outcome, false] if outcome == :done

        # Only the group: the leader's pid is reaped, so it may name another process.
        ProcessGroup.stop(pgid, grace: STOP_GRACE_SEC, poll: STOP_POLL_INTERVAL_SEC, stopped: -> { !held?(logs) })
        return [outcome, false] unless outcome == :grace

        [outcome, held?(logs) ? :detached : :stopped]
      end
      private_class_method :background_check

      # Whether some process still has one of +paths+ open from the spawn:
      # a flock belongs to the open file description, so an exclusive try
      # fails while any inherited copy is open (~0.2 ms; no lsof, no /proc).
      def self.held?(paths)
        paths.any? do |path|
          File.open(path, "r") do |file|
            got = file.flock(File::LOCK_EX | File::LOCK_NB)
            file.flock(File::LOCK_UN) if got
            !got
          end
        rescue Errno::ENOENT
          false
        end
      end

      # Polls the logs until no one holds them (+until_time+), the overall
      # +deadline+ or a Stop. Returns :done, :grace, :timeout or :cancelled.
      def self.await_release(paths, until_time:, deadline:, cancelled:)
        loop do
          return :done unless held?(paths)
          return :cancelled if cancelled.call
          return :timeout if deadline && monotonic_time > deadline
          return :grace if monotonic_time > until_time

          sleep(STOP_POLL_INTERVAL_SEC)
        end
      end
      private_class_method :await_release

      # The whole log when it is under execute.truncate_at_bytes, else its
      # head and tail only, read by seek (never the whole 100 MB).
      # @return [String, LogPreview]
      def self.read_log(path)
        return "" unless File.file?(path)

        size = File.size(path)
        return File.read(path) if size <= truncate_at_bytes

        LogPreview.new(size, OutputGuardrails.head_tail_from_file(path: path, file_size: size, preview_bytes: preview_bytes))
      end
      private_class_method :read_log

      # A command still running at the limit becomes a task (TaskRuntime.
      # adopt +task+, a TaskRecord.running) with the logs where they are
      # (+dir+); a back-pointer in that dir names the record for the sweep. nil when it can't be adopted (the caller
      # then kills it as in :kill mode) or when it ended meanwhile (the
      # caller then reads it as finished).
      # @return [String, nil] the HANDED_OVER result
      def self.hand_over(task, waiter:, timeout_sec:, dir:)
        return nil unless waiter.alive?

        record, error = TaskRuntime.adopt(task)
        return nil if error

        File.write(File.join(dir, BACK_POINTER), File.expand_path(TaskRuntime.metadata_path(record.id)))
        TaskRuntime.record_exit_status(waiter, record.exit_code_path, task_id: record.id)
        # Ended between the deadline and the adopt: the record says how.
        TaskRuntime.get_record(record.id) unless waiter.alive?
        lines = [handed_over_line(timeout_sec), "task_id: #{record.id}",
                 "Wait for it with task_wait (it may take minutes); task_stop stops it."]
        { "stdout" => record.output_path, "stderr" => record.stderr_path }.each do |label, path|
          tail = TaskRuntime.output_tail_lines(path, HAND_OVER_TAIL_LINES)
          lines << "#{label} (so far, tail):\n#{tail.chomp}" unless tail.empty?
        end
        lines.join("\n")
      end
      private_class_method :hand_over

      # <state dir>/execute: every command's dir (LOGS_DIRNAME).
      def self.logs_root = File.join(Paths.state_dir, LOGS_DIRNAME)

      # Once per process, at the first command (sweep_leftovers).
      def self.sweep_leftovers_once
        return if @swept

        @swept = true
        sweep_leftovers
      rescue StandardError
        nil
      end
      private_class_method :sweep_leftovers_once

      # Removes the dirs under logs_root no process holds any more: one
      # without a back-pointer, older than ORPHAN_AGE_SEC (a chi that died
      # mid-execute); one whose back-pointer's task.json is gone, or whose
      # logs are older than RETENTION_DAYS (a handed-over task long done).
      # A dir whose logs are still held is a command still running: kept.
      # The records live in each project's tmp/tasks, which the state dir
      # can't list: hence the back-pointer.
      # @return [Array<String>] the dirs removed
      def self.sweep_leftovers(now: Time.now)
        Dir.glob(File.join(logs_root, "*")).select { |dir| File.directory?(dir) }.filter_map do |dir|
          next unless leftover?(dir, now)

          FileUtils.rm_rf(dir)
          dir
        end
      end

      def self.leftover?(dir, now)
        logs = [File.join(dir, STDOUT_LOG), File.join(dir, STDERR_LOG)]
        return false if held?(logs)

        age = now - ([dir, *logs].filter_map { |path| File.mtime(path) if File.exist?(path) }.max || now)
        pointer = File.join(dir, BACK_POINTER)
        return age > ORPHAN_AGE_SEC unless File.file?(pointer)

        !File.file?(File.read(pointer).strip) || age > RETENTION_DAYS * 24 * 3600
      rescue SystemCallError
        false
      end
      private_class_method :leftover?

      # The shell still runs: TERM its group (or the shell alone, if it left
      # the group), then KILL it once the grace is over, unless +stopped+
      # (the shell reaped, the logs released) came first.
      def self.terminate_process_tree(pid, stopped:)
        ProcessGroup.stop(pid, grace: STOP_GRACE_SEC, poll: STOP_POLL_INTERVAL_SEC, leader: true, stopped: stopped)
      end
      private_class_method :terminate_process_tree

      def self.monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
      private_class_method :monotonic_time

      # execute.timeout_sec (SAMAGOTCHI_EXECUTE_TIMEOUT_SEC); 0 or less = the default.
      def self.timeout_seconds
        OutputGuardrails.config_positive_int("execute.timeout_sec", TIMEOUT_SEC)
      end

      # Resolves the working directory for the child process. An empty/absent
      # cwd defaults to the project root (Dir.pwd), mirroring task_runtime.
      # Relative paths are expanded against Dir.pwd; an unresolvable directory
      # returns nil so the caller can surface a friendly error.
      def self.resolve_cwd(cwd)
        value = cwd.to_s.strip
        resolved = value.empty? ? Dir.pwd : File.expand_path(value)
        Dir.exist?(resolved) ? resolved : nil
      end
      private_class_method :resolve_cwd

      def self.truncate_at_bytes
        OutputGuardrails.config_positive_int("execute.truncate_at_bytes", OutputGuardrails::DEFAULT_TRUNCATE_AT_BYTES)
      end
      private_class_method :truncate_at_bytes

      def self.preview_bytes
        OutputGuardrails.config_positive_int("execute.preview_bytes", OutputGuardrails::DEFAULT_PREVIEW_BYTES)
      end
      private_class_method :preview_bytes

      # @param content [String, LogPreview] a log read whole, or its head
      #   and tail (read_log)
      def self.output_block(label, content)
        return nil if content.nil? || content.empty?

        bytes = content.bytesize
        return "#{label}:\n#{content}" if bytes <= truncate_at_bytes && !content.is_a?(LogPreview)

        preview = if content.is_a?(LogPreview)
                    content.preview
                  else
                    OutputGuardrails.head_tail_from_string(content: content, preview_bytes: preview_bytes)
                  end

        [
          "#{label}:",
          "truncated=true",
          "preview_strategy=head_tail",
          "#{label}_bytes=#{bytes}",
          "returned_preview_bytes=#{preview.returned_preview_bytes}",
          "omitted_bytes=#{preview.omitted_bytes}",
          "[TRUNCATED_PREVIEW_HEAD]",
          preview.head,
          "[... omitted #{preview.omitted_bytes} bytes ...]",
          "[TRUNCATED_PREVIEW_TAIL]",
          preview.tail
        ].join("\n")
      end

      def self.telemetry_lines_for(content)
        OutputGuardrails.telemetry_lines_for(
          content: content,
          threshold_key: "execute.telemetry_threshold_pct",
          threshold_default: OutputGuardrails::DEFAULT_TELEMETRY_THRESHOLD_PCT,
          token_key: "estimated_tokens_for_command_output",
          pct_key: "estimated_window_pct_for_command_output"
        )
      end

      # A big log: its size, and the head and tail read by seek, which
      # output_block shows as it shows a long string's.
      class LogPreview
        attr_reader :bytesize, :preview # Integer, OutputGuardrails::PreviewParts

        def initialize(bytesize, preview)
          @bytesize = bytesize
          @preview = preview
        end

        def empty? = @bytesize.zero?
      end

      # Raised out of the wait with the hand-over's text: no read, no rm_rf.
      class HandedOver < StandardError
        attr_reader :text

        def initialize(text)
          @text = text
          super("handed over")
        end
      end

      class CommandTimedOut < StandardError
        attr_reader :stdout, :stderr

        def initialize(stdout, stderr)
          @stdout = stdout
          @stderr = stderr
          super("command timed out")
        end
      end

      class CommandCancelled < StandardError
        attr_reader :stdout, :stderr, :elapsed

        def initialize(stdout, stderr, elapsed)
          @stdout = stdout
          @stderr = stderr
          @elapsed = elapsed
          super("command stopped by the user")
        end
      end
    end
  end
end
