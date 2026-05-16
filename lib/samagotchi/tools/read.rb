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

      def self.call(path, start_line: nil, end_line: nil)
        path = path.to_s.strip

        if range_requested?(start_line, end_line)
          return read_range(path, start_line: start_line, end_line: end_line)
        end

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

      def self.range_requested?(start_line, end_line)
        !blank?(start_line) || !blank?(end_line)
      end
      private_class_method :range_requested?

      def self.read_range(path, start_line:, end_line:)
        start_num = parse_positive_line_number(start_line, "start_line")
        return start_num if start_num.is_a?(String)

        end_num = parse_positive_line_number(end_line, "end_line")
        return end_num if end_num.is_a?(String)

        return "Error: start_line and end_line must both be provided for range reads" if start_num.nil? || end_num.nil?
        return "Error: start_line must be <= end_line" if start_num > end_num

        lines = File.readlines(path, chomp: false)
        total_lines = lines.length
        return "Error: range out of bounds for #{path}: file has #{total_lines} lines" if total_lines.zero?
        return "Error: range out of bounds for #{path}: file has #{total_lines} lines" if start_num > total_lines || end_num > total_lines

        lines[(start_num - 1)..(end_num - 1)].join
      end
      private_class_method :read_range

      def self.parse_positive_line_number(value, key)
        return nil if blank?(value)

        integer = Integer(value.to_s.strip, exception: false)
        return "Error: #{key} must be a positive integer" unless integer&.positive?

        integer
      end
      private_class_method :parse_positive_line_number

      def self.blank?(value)
        value.nil? || value.to_s.strip.empty?
      end
      private_class_method :blank?
    end
  end
end
