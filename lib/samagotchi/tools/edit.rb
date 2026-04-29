# frozen_string_literal: true

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
      DESC

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(content, path:)
        path     = path.strip
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
    end
  end
end
