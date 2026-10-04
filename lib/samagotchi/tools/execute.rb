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
      TIMEOUT_SEC = 120
      STOP_GRACE_SEC = 1.0
      STOP_POLL_INTERVAL_SEC = 0.05
      WAIT_SLICE_SEC = 0.2
      NOT_RUN_ON_STOP = "Error: not run, the user stopped the turn"
      TIMEOUT_HINT = "(killed at the limit; for a long command use task_create, then task_wait)"
      # How long the output may stay open once the shell has exited: a
      # `server &` child keeps the pipes, and the read would never end.
      BACKGROUND_GRACE_SEC = 1.5
      BACKGROUND_HINT = "(a background process kept the output open and was stopped; " \
                        "to keep a server or long job running, start it with task_create)"
      # It had left the process group (setsid), so it is still running.
      BACKGROUND_DETACHED_HINT = "(a background process kept the output open and was left running; " \
                                 "to keep a server or long job running, start it with task_create)"
      READ_CHUNK_BYTES = 65_536

      def self.name        = NAME

      # @param cancelled [#call] true once the user stopped the turn: the
      #   command is killed (or not started) and its output so far returned
      # @param env [Hash, nil] added to the command's environment
      def self.call(command, cwd: nil, cancelled: -> { false }, env: nil)
        return NOT_RUN_ON_STOP if cancelled.call

        command = command.strip
        resolved_cwd = resolve_cwd(cwd)
        return "Error: cwd not found: #{resolved_cwd}" unless resolved_cwd

        timeout_sec = timeout_seconds
        stdout, stderr, status, held_open = run_command(command, timeout_sec: timeout_sec, cwd: resolved_cwd, cancelled: cancelled,
                                                      env: env)

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
      rescue CommandTimedOut => e
        # Keep the "Error:" first line (callers classify on it), say how to run
        # a long command, and return whatever it printed before it was killed.
        stopped_result("Error: command timed out after #{timeout_sec}s\n#{TIMEOUT_HINT}", e)
      rescue CommandCancelled => e
        stopped_result("Error: command stopped by the user after #{e.elapsed.round}s (killed; rerun it if still needed)", e)
      rescue StandardError => e
        "Error: #{e.message}"
      end

      def self.stopped_result(first_line, error)
        parts = [first_line]
        parts << output_block("stdout", error.stdout)
        parts << output_block("stderr", error.stderr)
        parts.compact.join("\n")
      end
      private_class_method :stopped_result

      def self.run_command(command, timeout_sec:, cwd:, cancelled: -> { false }, env: nil)
        stdout_text = ""
        stderr_text = ""
        status = nil
        timed_out = false
        was_cancelled = false
        aborted = false
        held_open = false
        started = monotonic_time
        deadline = started + timeout_sec

        Open3.popen3(env || {}, command, chdir: cwd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          readers = [OutputReader.new(stdout), OutputReader.new(stderr)]

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
            aborted = true
            terminate_process_tree(wait_thr.pid)
            raise
          ensure
            # The shell is gone, but a child it put in the background (`cmd &`)
            # may still hold the pipes: wait for EOF a short grace only, then
            # stop the command's process group and keep the output so far.
            # Already stopped (timeout, Stop, an exception): no more checks.
            stopping = timed_out || was_cancelled || aborted
            outcome = await_readers(readers, until_time: monotonic_time + BACKGROUND_GRACE_SEC,
                                             deadline: stopping ? nil : deadline,
                                             cancelled: stopping ? -> { false } : cancelled)
            unless outcome == :done
              was_cancelled = true if outcome == :cancelled
              timed_out = true if outcome == :timeout
              stopped = stop_process_group(wait_thr.pid, readers)
              held_open = (stopped ? :stopped : :detached) if outcome == :grace && !stopping
            end
            readers.each(&:finish)
            stdout_text, stderr_text = readers.map(&:text)
          end
        end

        raise CommandTimedOut.new(stdout_text, stderr_text) if timed_out
        raise CommandCancelled.new(stdout_text, stderr_text, monotonic_time - started) if was_cancelled

        [stdout_text, stderr_text, status, held_open]
      end
      private_class_method :run_command

      # Waits for both readers to hit EOF until +until_time+, the overall
      # +deadline+ or a Stop. Returns :done, :grace, :timeout or :cancelled.
      def self.await_readers(readers, until_time:, deadline:, cancelled:)
        loop do
          return :done if readers.all?(&:done?)
          return :cancelled if cancelled.call
          return :timeout if deadline && monotonic_time > deadline
          return :grace if monotonic_time > until_time

          readers.find { |r| !r.done? }&.wait(STOP_POLL_INTERVAL_SEC)
        end
      end
      private_class_method :await_readers

      # The shell has exited (its pid is reaped) but its process group still
      # has members holding the output: TERM the group, then KILL it. A process
      # that left the group (setsid) is out of reach; the pipes get closed.
      # True once the output was released, false if something still holds it.
      def self.stop_process_group(pgid, readers)
        signal_group(pgid, "TERM")
        return true if await_readers(readers, until_time: monotonic_time + STOP_GRACE_SEC, deadline: nil,
                                              cancelled: -> { false }) == :done

        signal_group(pgid, "KILL")
        await_readers(readers, until_time: monotonic_time + STOP_GRACE_SEC, deadline: nil, cancelled: -> { false }) == :done
      end
      private_class_method :stop_process_group

      # Only the group: the leader's pid is reaped, so it may name another process.
      def self.signal_group(pgid, signal)
        Process.kill(signal, -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      private_class_method :signal_group

      # Reads a pipe in chunks on its own thread, so the output read so far
      # survives the pipe being closed under it.
      class OutputReader
        def initialize(io)
          @io = io
          @buffer = String.new(encoding: Encoding::BINARY)
          @thread = Thread.new do
            Thread.current.report_on_exception = false
            loop { @buffer << io.readpartial(READ_CHUNK_BYTES) }
          rescue IOError # EOFError is one
            nil
          end
        end

        def done? = !@thread.alive?

        def wait(seconds) = @thread.join(seconds)

        # Closes the pipe (a reader still blocked gets IOError) and ends the
        # thread; the text is safe to read afterwards.
        def finish
          @thread.join(STOP_POLL_INTERVAL_SEC) unless done?
          close_quietly
          @thread.kill unless @thread.join(STOP_GRACE_SEC)
        end

        def text
          @buffer.dup.force_encoding(@io.external_encoding || Encoding.default_external)
        end

        private

        def close_quietly
          @io.close unless @io.closed?
        rescue IOError
          nil
        end
      end
      private_constant :OutputReader

      def self.terminate_process_tree(pid)
        signal_process(pid, "TERM")

        deadline = monotonic_time + STOP_GRACE_SEC
        sleep(STOP_POLL_INTERVAL_SEC) while process_alive?(pid) && monotonic_time < deadline

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

      # execute.timeout_sec (SAMAGOTCHI_EXECUTE_TIMEOUT_SEC); 0 or less = the default.
      def self.timeout_seconds
        OutputGuardrails.config_positive_int("execute.timeout_sec", TIMEOUT_SEC)
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
