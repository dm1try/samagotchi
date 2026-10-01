# frozen_string_literal: true

require_relative "text_diff"
require_relative "tools/edit"
require_relative "tools/tool_path"

module Samagotchi
  # What chi's own edit/write tools change, as a TextDiff. Used twice:
  #
  # - EditPreview.for(call): a dry run before the call runs (the approval
  #   card). It reads the file once and never writes.
  # - EditPreview.snapshot + change: the file before and after the call ran
  #   (the tool row), so the row shows what really happened.
  #
  # A diff is {text:, added:, removed:, truncated:, new_file:}; a preview can
  # also be {error: "old text not found in …"} (the call would fail) or
  # {skipped: "binary file" | "file over 1 MB"}.
  module EditPreview
    TOOLS = %w[edit write].freeze
    MAX_FILE_BYTES = 1024 * 1024
    SNIFF_BYTES = 8 * 1024

    module_function

    def tool?(name) = TOOLS.include?(name.to_s)

    # @return [Hash, nil] nil for a tool that isn't edit/write
    def for(call)
      return nil unless tool?(call[:name])

      path = Tools::ToolPath.normalize(call[:path])
      before = snapshot(path)
      return before if before.is_a?(Hash)

      if call[:name].to_s == "edit"
        result = Tools::Edit.apply(path: path, old_text: call[:old_text], new_text: call[:new_text],
                                   start_line: call[:start_line], end_line: call[:end_line], read: ->(_) { before })
        return { error: result.delete_prefix("Error: ") } if result.is_a?(String)

        after = result.first
      else
        after = call[:content]
        return { error: "missing content" } unless after.is_a?(String)

        skip = skip_reason(after)
        return { skipped: skip } if skip
      end
      # Unlike change, a no-op still gets a (0/0) diff: nil means "not edit/write".
      TextDiff.unified(before.to_s, after).merge(new_file: before.nil?)
    end

    # The file as the tools read it: nil when it doesn't exist, the text, or
    # {skipped:} / {error:} when it can't be diffed.
    def snapshot(path)
      return nil unless File.file?(path)
      return { skipped: "file over 1 MB" } if File.size(path) > MAX_FILE_BYTES

      text = File.read(path)
      skip = skip_reason(text)
      skip ? { skipped: skip } : text
    rescue SystemCallError, IOError => e
      { error: e.message }
    end

    # @param before [String, nil] nil for a file that didn't exist
    # @return [Hash, nil] nil when there's nothing to show (same text, or
    #   the after side isn't a readable text file)
    def change(before, after)
      return nil unless after.is_a?(String)
      return nil unless before.nil? || before.is_a?(String)
      return nil if before == after

      TextDiff.unified(before.to_s, after).merge(new_file: before.nil?)
    end

    def skip_reason(text)
      return "file over 1 MB" if text.bytesize > MAX_FILE_BYTES

      "binary file" if text.byteslice(0, SNIFF_BYTES).include?("\0")
    end
  end
end
