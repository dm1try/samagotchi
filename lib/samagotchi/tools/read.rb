# frozen_string_literal: true

require_relative "output_guardrails"

module Samagotchi
  module Tools
    # Reads a file from disk and returns its contents as a string.
    class Read
      NAME        = "read"
      DESCRIPTION = "Read a file from disk. Large files are returned as a head+tail preview with size metadata."

      DEFAULT_HARD_MAX_BYTES = 2 * 1024 * 1024

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(path)
        path = path.to_s.strip
        size = File.size(path)

        hard_max_bytes = OutputGuardrails.env_positive_int("SAMAGOTCHI_READ_HARD_MAX_BYTES", DEFAULT_HARD_MAX_BYTES)
        truncate_at_bytes = OutputGuardrails.env_positive_int("SAMAGOTCHI_READ_TRUNCATE_AT_BYTES", OutputGuardrails::DEFAULT_TRUNCATE_AT_BYTES)
        preview_bytes = OutputGuardrails.env_positive_int("SAMAGOTCHI_READ_PREVIEW_BYTES", OutputGuardrails::DEFAULT_PREVIEW_BYTES)

        if size > hard_max_bytes
          return "Error: file too large: #{path} (#{size} bytes, hard limit #{hard_max_bytes} bytes)."
        end

        return File.read(path) if size <= truncate_at_bytes

        build_truncated_preview(path: path, file_size: size, preview_bytes: preview_bytes)
      rescue Errno::ENOENT
        "Error: file not found: #{path.strip}"
      rescue => e
        "Error: #{e.message}"
      end

      def self.build_truncated_preview(path:, file_size:, preview_bytes:)
        preview = OutputGuardrails.head_tail_from_file(path: path, file_size: file_size, preview_bytes: preview_bytes)

        preview_block = [
          "[TRUNCATED_PREVIEW_HEAD]",
          preview[:head],
          "[... omitted #{preview[:omitted_bytes]} bytes ...]",
          "[TRUNCATED_PREVIEW_TAIL]",
          preview[:tail]
        ].join("\n")

        metadata_lines = [
          "truncated=true",
          "path=#{path}",
          "preview_strategy=head_tail",
          "file_bytes=#{file_size}",
          "returned_preview_bytes=#{preview[:returned_preview_bytes]}",
          "omitted_bytes=#{preview[:omitted_bytes]}"
        ]

        telemetry = telemetry_lines_for(preview_block)
        metadata_lines.concat(telemetry) unless telemetry.empty?

        [metadata_lines.join("\n"), "", preview_block].join("\n")
      end

      def self.telemetry_lines_for(content)
        OutputGuardrails.telemetry_lines_for(
          content: content,
          threshold_env: "SAMAGOTCHI_READ_TELEMETRY_THRESHOLD_PCT",
          threshold_default: OutputGuardrails::DEFAULT_TELEMETRY_THRESHOLD_PCT,
          token_key: "estimated_tokens_for_preview",
          pct_key: "estimated_window_pct_for_preview"
        )
      end
    end
  end
end
