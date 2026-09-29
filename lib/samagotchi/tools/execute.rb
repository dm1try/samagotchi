# frozen_string_literal: true

require "open3"
require_relative "output_guardrails"

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
      TIMEOUT_SEC = 30
      STOP_GRACE_SEC = 1.0
      STOP_POLL_INTERVAL_SEC = 0.05
      WAIT_SLICE_SEC = 0.2
      NOT_RUN_ON_STOP = "Error: not run, the user stopped the turn"

      def self.name        = NAME

      # @param cancelled [#call] true once the user stopped the turn: the
      #   command is killed (or not started) and its output so far returned
      def self.call(command, cwd: nil, cancelled: -> { false })
        return NOT_RUN_ON_STOP if cancelled.call

        command = command.strip
        resolved_cwd = resolve_cwd(cwd)
        return "Error: cwd not found: #{resolved_cwd}" unless resolved_cwd

        timeout_sec = timeout_seconds
        stdout, stderr, status = run_command(command, timeout_sec: timeout_sec, cwd: resolved_cwd, cancelled: cancelled)

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
        parts.join("\n")
      rescue CommandTimedOut => e
        # Keep the "Error:" first line (callers classify on it) and return
        # whatever the command printed before it was killed.
        stopped_result("Error: command timed out after #{timeout_sec}s", e)
      rescue CommandCancelled => e
        stopped_result("Error: command stopped by the user after #{e.elapsed.round}s (killed; rerun it if still needed)", e)
      rescue => e
        "Error: #{e.message}"
      end

      def self.stopped_result(first_line, error)
        parts = [first_line]
        parts << output_block("stdout", error.stdout)
        parts << output_block("stderr", error.stderr)
        parts.compact.join("\n")
      end
      private_class_method :stopped_result

      def self.run_command(command, timeout_sec:, cwd:, cancelled: -> { false })
        stdout_text = ""
        stderr_text = ""
        status = nil
        timed_out = false
        was_cancelled = false
        started = monotonic_time
        deadline = started + timeout_sec

        Open3.popen3(command, chdir: cwd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          stdout_reader = reader_thread_for(stdout)
          stderr_reader = reader_thread_for(stderr)

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
            terminate_process_tree(wait_thr.pid) if timed_out || was_cancelled
            wait_thr.join
            status = wait_thr.value
          rescue Exception # rubocop:disable Lint/RescueException -- kill the child, then re-raise
            # An Interrupt (or anything else) mid-wait: the child is in its own
            # process group, so it never saw the SIGINT. Kill it, or the reads
            # below block until it closes stdout.
            terminate_process_tree(wait_thr.pid)
            raise
          ensure
            # Read the buffered output before closing the pipes. For a process
            # that exits almost instantly (e.g. `echo hello`), the background
            # reader thread may not have scheduled its `io.read` yet; joining
            # the reader after the pipe is closed would return "".
            stdout_text = stdout_reader.value
            stderr_text = stderr_reader.value
            close_quietly(stdout)
            close_quietly(stderr)
          end
        end

        raise CommandTimedOut.new(stdout_text, stderr_text) if timed_out
        raise CommandCancelled.new(stdout_text, stderr_text, monotonic_time - started) if was_cancelled

        [stdout_text, stderr_text, status]
      end
      private_class_method :run_command

      def self.reader_thread_for(io)
        Thread.new do
          Thread.current.report_on_exception = false
          io.read.to_s
        rescue IOError, EOFError
          ""
        end
      end
      private_class_method :reader_thread_for

      def self.close_quietly(io)
        io.close unless io.closed?
      rescue IOError
        nil
      end
      private_class_method :close_quietly

      def self.terminate_process_tree(pid)
        signal_process(pid, "TERM")

        deadline = monotonic_time + STOP_GRACE_SEC
        while process_alive?(pid) && monotonic_time < deadline
          sleep(STOP_POLL_INTERVAL_SEC)
        end

        signal_process(pid, "KILL") if process_alive?(pid)
      end
      private_class_method :terminate_process_tree

      def self.signal_process(pid, signal)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
      private_class_method :signal_process

      def self.process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
      private_class_method :process_alive?

      def self.monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
      private_class_method :monotonic_time

      def self.timeout_seconds
        value = Integer(ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"].to_s, exception: false)
        return TIMEOUT_SEC if value.nil? || value <= 0

        value
      end
      private_class_method :timeout_seconds

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

      def self.output_block(label, content)
        return nil if content.nil? || content.empty?

        truncate_at_bytes = OutputGuardrails.config_positive_int("execute.truncate_at_bytes", OutputGuardrails::DEFAULT_TRUNCATE_AT_BYTES)
        preview_bytes = OutputGuardrails.config_positive_int("execute.preview_bytes", OutputGuardrails::DEFAULT_PREVIEW_BYTES)
        bytes = content.bytesize
        return "#{label}:\n#{content}" if bytes <= truncate_at_bytes

        preview = OutputGuardrails.head_tail_from_string(content: content, preview_bytes: preview_bytes)

        [
          "#{label}:",
          "truncated=true",
          "preview_strategy=head_tail",
          "#{label}_bytes=#{bytes}",
          "returned_preview_bytes=#{preview[:returned_preview_bytes]}",
          "omitted_bytes=#{preview[:omitted_bytes]}",
          "[TRUNCATED_PREVIEW_HEAD]",
          preview[:head],
          "[... omitted #{preview[:omitted_bytes]} bytes ...]",
          "[TRUNCATED_PREVIEW_TAIL]",
          preview[:tail]
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
