# frozen_string_literal: true

require "open3"
require_relative "output_guardrails"

module Samagotchi
  module Tools
    # Runs an arbitrary shell command and returns stdout, stderr, and exit code.
    # The model can use this to execute Ruby snippets, run RSpec, or any other
    # shell command needed during self-improvement or code assistance.
    #
    # Examples the model can emit:
    #   <tool name="execute">ruby -e 'puts 2 + 2'</tool>
    #   <tool name="execute">bundle exec rspec spec/some_spec.rb --no-color</tool>
    #   <tool name="execute">ruby path/to/script.rb</tool>
    class Execute
      NAME        = "execute"
      DESCRIPTION = "Run a shell command (ruby snippet, rspec, etc.). Large stdout/stderr is truncated to a head+tail preview with metadata."
      TIMEOUT_SEC = 30
      STOP_GRACE_SEC = 1.0
      STOP_POLL_INTERVAL_SEC = 0.05

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(command)
        command = command.strip
        timeout_sec = timeout_seconds
        stdout, stderr, status = run_command(command, timeout_sec: timeout_sec)

        stdout_block = output_block("stdout", stdout)
        stderr_block = output_block("stderr", stderr)
        telemetry = telemetry_lines_for([stdout_block, stderr_block].join("\n"))

        parts = []
        parts.concat(telemetry) unless telemetry.empty?
        parts << stdout_block unless stdout_block.nil?
        parts << stderr_block unless stderr_block.nil?
        parts << "exit: #{status.exitstatus}"
        parts.join("\n")
      rescue CommandTimedOut
        "Error: command timed out after #{timeout_sec}s"
      rescue => e
        "Error: #{e.message}"
      end

      def self.run_command(command, timeout_sec:)
        stdout_text = ""
        stderr_text = ""
        status = nil
        timed_out = false

        Open3.popen3(command, pgroup: true) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          stdout_reader = reader_thread_for(stdout)
          stderr_reader = reader_thread_for(stderr)

          begin
            if wait_thr.join(timeout_sec)
              status = wait_thr.value
            else
              timed_out = true
              terminate_process_tree(wait_thr.pid)
              wait_thr.join
              status = wait_thr.value
            end
          ensure
            close_quietly(stdout)
            close_quietly(stderr)
          end

          stdout_text = stdout_reader.value
          stderr_text = stderr_reader.value
        end

        raise CommandTimedOut if timed_out

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

      def self.output_block(label, content)
        return nil if content.nil? || content.empty?

        truncate_at_bytes = OutputGuardrails.env_positive_int("SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES", OutputGuardrails::DEFAULT_TRUNCATE_AT_BYTES)
        preview_bytes = OutputGuardrails.env_positive_int("SAMAGOTCHI_EXECUTE_PREVIEW_BYTES", OutputGuardrails::DEFAULT_PREVIEW_BYTES)
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
          threshold_env: "SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT",
          threshold_default: OutputGuardrails::DEFAULT_TELEMETRY_THRESHOLD_PCT,
          token_key: "estimated_tokens_for_command_output",
          pct_key: "estimated_window_pct_for_command_output"
        )
      end

      class CommandTimedOut < StandardError; end
    end
  end
end
