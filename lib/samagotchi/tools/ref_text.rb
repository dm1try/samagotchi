# frozen_string_literal: true

module Samagotchi
  module Tools
    # A tool's text that shows part of a file kept elsewhere in whole: a
    # task's log (task_wait's output tail), a child's reply file (delegate,
    # delegate_result). It is the text itself (a String), like
    # Plugin::ToolResult; #ref_path is the file, which ToolRunner's cut
    # names when the text is longer than max_tool_output_chars
    # (ToolOutputCut's :head_tail_ref), instead of saving a copy;
    # #stderr_path, a handed-over execute's stderr log, the cut names too.
    class RefText < String
      attr_reader :ref_path, :stderr_path

      def initialize(text, ref_path, stderr_path: nil)
        @ref_path = ref_path
        @stderr_path = stderr_path.to_s.empty? ? nil : stderr_path
        super(text.to_s)
      end

      # +text+ as a RefText of +ref_path+; +text+ as it is with no path.
      def self.wrap(text, ref_path, stderr_path: nil)
        ref_path.to_s.empty? ? text : new(text, ref_path, stderr_path: stderr_path)
      end
    end
  end
end
