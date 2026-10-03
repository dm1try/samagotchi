# frozen_string_literal: true

require_relative "output_guardrails"
require_relative "tool_path"

module Samagotchi
  module Tools
    # Replaces an exact block of text in an existing file (old_text →
    # new_text), or a range of lines (start_line..end_line → new_text).
    #
    # old_text must match exactly once in the file. The tool returns an error
    # if the text is not found or appears more than once. new_text is
    # required in both modes; "" deletes.
    class Edit
      NAME        = "edit"

      def self.name        = NAME

      OLD_TEXT_REQUIRED = "Error: old_text is required (the exact text to replace), or give start_line for a range edit"
      NEW_TEXT_REQUIRED = 'Error: new_text is required (use "" to delete)'

      def self.call(path:, old_text: nil, new_text: nil, start_line: nil, end_line: nil)
        path = ToolPath.normalize(path)
        result = apply(path: path, old_text: old_text, new_text: new_text, start_line: start_line, end_line: end_line)
        return result if result.is_a?(String)

        updated, message = result
        File.write(path, updated)
        message
      rescue => e
        "Error: #{e.message}"
      end

      # The edit without the write: [updated, message] or "Error: …", with
      # exactly the strings call returns. +read+ reads the file, so a dry run
      # (EditPreview) can reuse a copy it already has; each mode keeps its own
      # check order (exact: the texts first; range: file not found first).
      def self.apply(path:, old_text: nil, new_text: nil, start_line: nil, end_line: nil, read: ->(p) { File.read(p) })
        path = ToolPath.normalize(path)

        if range_requested?(start_line, end_line)
          return apply_range_mode(new_text, path: path, start_line: start_line, end_line: end_line, read: read)
        end

        return OLD_TEXT_REQUIRED if old_text.nil? || old_text.to_s.empty?
        return NEW_TEXT_REQUIRED if new_text.nil?
        return "Error: file not found: #{path}" unless File.exist?(path)

        old_text = old_text.to_s
        new_text = new_text.to_s

        source = read.(path)
        count  = count_occurrences(source, old_text)

        return "Error: old text not found in #{path}" if count == 0
        return "Error: old text matches #{count} times in #{path}; make it unique" if count > 1

        idx     = source.index(old_text)
        updated = source[0, idx] + new_text + source[idx + old_text.length..]
        [updated, "Edited #{path}: replaced #{old_text.bytesize} bytes with #{new_text.bytesize} bytes"]
      rescue => e
        "Error: #{e.message}"
      end

      START_LINE_REQUIRED = "Error: end_line alone isn't enough for a range edit; " \
                            "pass start_line too (1-based, the first line to replace)"

      def self.apply_range_mode(new_text, path:, start_line:, end_line:, read:)
        return "Error: file not found: #{path}" unless File.exist?(path)
        return NEW_TEXT_REQUIRED if new_text.nil?

        new_text = new_text.to_s

        start_num = parse_positive_line_number(start_line, "start_line")
        return start_num if start_num.is_a?(String)
        # Not defaulted to 1 like read: a range edit replaces the span, so a
        # guessed start would silently overwrite the top of the file.
        return START_LINE_REQUIRED if start_num.nil?

        source = read.(path)
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

        replaced_lines = (end_value - start_num) + 1
        new_line_count = new_text.lines.length
        [updated, "Edited #{path}: replaced lines #{start_num}-#{end_value} (#{replaced_lines} lines) with #{new_line_count} lines#{clamp_note}"]
      rescue => e
        "Error: #{e.message}"
      end
      private_class_method :apply_range_mode

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
