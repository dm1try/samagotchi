# frozen_string_literal: true

require_relative "tool_path"

module Samagotchi
  module Tools
    # Replaces an exact block of text in an existing file.
    #
    # XML syntax (used by the model):
    #   <tool name="edit" path="path/to/file">
    #     <old>exact text to replace</old>
    #     <new>replacement text</new>
    #   </tool>
    #
    # The <old> block must match exactly once in the file.  The tool returns an
    # error if the text is not found or appears more than once.
    class Edit
      NAME        = "edit"
      DESCRIPTION = <<~DESC.strip
        Edit a file by replacing an exact block of text.
        Usage: <tool name="edit" path="path/to/file"><old>exact text to replace</old><new>replacement text</new></tool>
        The <old> block must match exactly once in the file.
        Range mode: pass start_line/end_line (inclusive) instead of old_text.
        end_line is optional (means "to EOF") and may overshoot EOF — the tool clamps to the last line and reports the clamp. A start_line past EOF returns an error.
      DESC

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(content, path:, start_line: nil, end_line: nil)
        path = ToolPath.normalize(path)

        if range_requested?(start_line, end_line)
          return call_range_mode(content, path: path, start_line: start_line, end_line: end_line)
        end

        old_text = extract_tag(content, "old")
        new_text = extract_tag(content, "new")

        return "Error: missing <old>...</old> block" if old_text.nil?
        return "Error: missing <new>...</new> block" if new_text.nil?
        return "Error: <old> block is empty" if old_text.empty?
        return "Error: file not found: #{path}" unless File.exist?(path)

        source = File.read(path)
        count  = count_occurrences(source, old_text)

        return "Error: old text not found in #{path}" if count == 0
        return "Error: old text matches #{count} times in #{path}; make it unique" if count > 1

        idx     = source.index(old_text)
        updated = source[0, idx] + new_text + source[idx + old_text.length..]
        File.write(path, updated)
        "Edited #{path}: replaced #{old_text.bytesize} bytes with #{new_text.bytesize} bytes"
      rescue => e
        "Error: #{e.message}"
      end

      def self.call_range_mode(content, path:, start_line:, end_line:)
        return "Error: file not found: #{path}" unless File.exist?(path)

        new_text = extract_tag(content, "new")
        return "Error: missing <new>...</new> block" if new_text.nil?

        start_num = parse_positive_line_number(start_line, "start_line")
        return start_num if start_num.is_a?(String)
        return "Error: start_line must be provided for range edits" if start_num.nil?

        source = File.read(path)
        lines = source.lines
        total_lines = lines.length

        # Option C: end_line is optional and means "to EOF" when omitted
        # (unless SAMAGOTCHI_EDIT_END_OPTIONAL=false).
        end_provided = !blank?(end_line)
        end_num = end_provided ? parse_positive_line_number(end_line, "end_line") : nil
        return end_num if end_num.is_a?(String)

        # Option B: an end_line that overshoots EOF is clamped here and flagged
        # in the result so the agent never mutates a different span silently.
        # Set SAMAGOTCHI_EDIT_ALLOW_OOR_END=false to keep the hard error instead.
        clamp_note = ""
        end_value = nil
        if end_provided
          if end_num > total_lines
            if OutputGuardrails.env_bool("SAMAGOTCHI_EDIT_ALLOW_OOR_END", default: true)
              clamp_note = " (end_line #{end_num} exceeds #{total_lines} lines; clamped to line #{total_lines})"
              end_value = total_lines
            else
              return "Error: range out of bounds for #{path}: file has #{total_lines} lines"
            end
          else
            end_value = end_num
          end
        else
          unless OutputGuardrails.env_bool("SAMAGOTCHI_EDIT_END_OPTIONAL", default: true)
            return "Error: start_line and end_line must both be provided for range edits"
          end
          end_value = total_lines
        end

        # start past EOF is genuinely unusable -> keep a hard error.
        return "Error: start_line #{start_num} out of bounds for #{path}: file has #{total_lines} lines" if start_num > total_lines
        return "Error: start_line must be <= end_line" if start_num > end_value

        prefix = lines[0, start_num - 1].join
        suffix = lines[end_value..]&.join.to_s
        # Ensure new_text ends with a newline when a suffix follows so that the
        # first suffix line isn't concatenated onto the last replacement line.
        normalized = (!new_text.empty? && !suffix.empty? && !new_text.end_with?("\n")) ? new_text + "\n" : new_text
        updated = prefix + normalized + suffix
        File.write(path, updated)

        replaced_lines = (end_value - start_num) + 1
        new_line_count = new_text.lines.length
        "Edited #{path}: replaced lines #{start_num}-#{end_value} (#{replaced_lines} lines) with #{new_line_count} lines#{clamp_note}"
      rescue => e
        "Error: #{e.message}"
      end
      private_class_method :call_range_mode

      # Count non-overlapping literal occurrences of +needle+ in +haystack+.
      def self.count_occurrences(haystack, needle)
        count = 0
        pos   = 0
        while (i = haystack.index(needle, pos))
          count += 1
          break if count > 1  # early exit — we only care whether it's 0, 1, or >1
          pos = i + needle.length
        end
        count
      end
      private_class_method :count_occurrences

      def self.extract_tag(content, tag)
        m = content.match(/<#{tag}>(.*?)<\/#{tag}>/m)
        m ? m[1] : nil
      end
      private_class_method :extract_tag

      def self.range_requested?(start_line, end_line)
        !blank?(start_line) || !blank?(end_line)
      end
      private_class_method :range_requested?

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
