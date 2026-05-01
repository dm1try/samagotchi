# frozen_string_literal: true

require "open3"
require "timeout"
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

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(command)
        command = command.strip
        stdout, stderr, status = Timeout.timeout(TIMEOUT_SEC) { Open3.capture3(command) }

        stdout_block = output_block("stdout", stdout)
        stderr_block = output_block("stderr", stderr)
        telemetry = telemetry_lines_for([stdout_block, stderr_block].join("\n"))

        parts = []
        parts.concat(telemetry) unless telemetry.empty?
        parts << stdout_block unless stdout_block.nil?
        parts << stderr_block unless stderr_block.nil?
        parts << "exit: #{status.exitstatus}"
        parts.join("\n")
      rescue Timeout::Error
        "Error: command timed out after #{TIMEOUT_SEC}s"
      rescue => e
        "Error: #{e.message}"
      end

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
    end
  end
end
