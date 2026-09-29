# frozen_string_literal: true

require_relative "output_guardrails"
require_relative "tool_path"
require_relative "../image_store"

module Samagotchi
  module Tools
    # Reads a file from disk and returns its contents as a string.
    class Read
      NAME        = "read"

      DEFAULT_HARD_MAX_BYTES = 2 * 1024 * 1024

      def self.name        = NAME

      # An image the tool found (by its magic bytes, whatever its name): the
      # line the model reads, and the file the loop attaches (ToolRunner).
      # It is that line as a String.
      class ImageResult < String
        attr_reader :image_path, :description

        def initialize(image_path, description)
          @image_path = image_path
          @description = description
          super("Image #{description} attached.")
        end

        def images = [{ path: image_path, description: description }]

        # The text only says the image is attached: when it can't be, the
        # line saying why replaces it.
        def image_only? = true
      end

      # How far into a file its size is looked for (a JPEG's frame header
      # can follow a large EXIF block).
      IMAGE_HEADER_BYTES = 256 * 1024

      def self.call(path, start_line: nil, end_line: nil)
        path = ToolPath.normalize(path)

        if ImageStore.image_file?(path)
          return "Error: #{path} is an image; read it without start_line/end_line" if range_requested?(start_line, end_line)

          return image_result(path)
        end

        if range_requested?(start_line, end_line)
          return read_range(path, start_line: start_line, end_line: end_line)
        end

        size = File.size(path)

        hard_max_bytes = OutputGuardrails.config_positive_int("read.hard_max_bytes", DEFAULT_HARD_MAX_BYTES)
        truncate_at_bytes = OutputGuardrails.config_positive_int("read.truncate_at_bytes", OutputGuardrails::DEFAULT_TRUNCATE_AT_BYTES)
        preview_bytes = OutputGuardrails.config_positive_int("read.preview_bytes", OutputGuardrails::DEFAULT_PREVIEW_BYTES)

        if size > hard_max_bytes
          return "Error: file too large: #{path} (#{size} bytes, hard limit #{hard_max_bytes} bytes)."
        end

        return File.read(path) if size <= truncate_at_bytes

        build_truncated_preview(path: path, file_size: size, preview_bytes: preview_bytes)
      rescue Errno::ENOENT
        "Error: file not found: #{path}"
      rescue => e
        "Error: #{e.message}"
      end

      def self.image_result(path)
        info = ImageHeader.read(File.binread(path, IMAGE_HEADER_BYTES))
        size = info.width && info.height ? "#{info.width}×#{info.height} " : ""
        ImageResult.new(path, "#{File.basename(path)} (#{size}#{info.format.to_s.upcase})")
      end
      private_class_method :image_result

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
          threshold_key: "read.telemetry_threshold_pct",
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
        lines = File.readlines(path, chomp: false)
        total_lines = lines.length
        return "Error: range out of bounds for #{path}: file is empty (0 lines)" if total_lines.zero?

        start_num = parse_positive_line_number(start_line, "start_line")
        return start_num if start_num.is_a?(String)
        return "Error: start_line must be provided for range reads" if start_num.nil?

        end_provided = !blank?(end_line)
        end_num = end_provided ? parse_positive_line_number(end_line, "end_line") : nil
        return end_num if end_num.is_a?(String)

        # Option C: end_line is optional and means "to EOF" when omitted
        # (unless SAMAGOTCHI_READ_END_OPTIONAL=false).
        unless end_provided
          return "Error: start_line and end_line must both be provided for range reads" unless OutputGuardrails.env_bool("SAMAGOTCHI_READ_END_OPTIONAL", default: true)

          end_num = total_lines
        end

        # Option B: an end_line that overshoots EOF is clamped silently by
        # Ruby's slice; when it also exceeds the file we trim here so the agent
        # sees the real span.  Set SAMAGOTCHI_READ_ALLOW_OOR_END=false to keep
        # the historical hard error instead.
        clamp_note = ""
        if end_provided && end_num > total_lines
          if OutputGuardrails.env_bool("SAMAGOTCHI_READ_ALLOW_OOR_END", default: true)
            clamp_note = "\n[read: end_line #{end_num} exceeds #{total_lines} lines; returning lines #{start_num}-#{total_lines}]"
            end_num = total_lines
          else
            return "Error: range out of bounds for #{path}: file has #{total_lines} lines"
          end
        end

        # A start past EOF is genuinely unusable -> keep a hard error.  A slice
        # whose start is within the file never yields nil, so this also guards
        # against the previous ".join on nil" crash.
        return "Error: start_line #{start_num} out of bounds for #{path}: file has #{total_lines} lines" if start_num > total_lines
        return "Error: start_line must be <= end_line" if start_num > end_num

        content = lines[(start_num - 1)..(end_num - 1)].join
        clamp_note.empty? ? content : content + clamp_note
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
