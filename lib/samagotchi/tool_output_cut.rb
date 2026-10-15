# frozen_string_literal: true

module Samagotchi
  # How ToolRunner cuts a tool's output that is longer than
  # max_tool_output_chars, by the tool's policy (POLICIES, by its built-in
  # name; any other tool gets :head).
  #
  # :head keeps the first chars and ends with head_line ("[cut: N of M
  # chars; read it in parts]"): read (which has line ranges) and every tool
  # with no policy of its own.
  module ToolOutputCut
    POLICIES = {}.freeze

    # A head cut's last line (head_line), as LLMContextStale recognizes a
    # partial read by it. Kept in sync with head_line by its spec.
    HEAD_CUT = /\[cut: \d+ of \d+ chars; read it in parts\]\z/

    module_function

    # @param tool [String, nil] the call's tool name
    # @return [Symbol] its policy
    def policy(tool) = POLICIES.fetch(tool.to_s, :head)

    # +output+ cut to +cap+ chars by +tool+'s policy.
    # @return [String] the text the model gets
    def apply(output, cap:, tool:)
      _ = tool
      head(output, cap)
    end

    # +output+ cut to +cap+ chars, the cut line included: the model knows
    # what it didn't get. A cap smaller than the line keeps +cap+ chars and
    # the line goes past it.
    def head(output, cap)
      keep = cap - head_line(cap, output.length).length
      keep = cap unless keep.positive?
      "#{output[0, keep]}#{head_line(keep, output.length)}"
    end

    def head_line(kept, total)
      "\n[cut: #{kept} of #{total} chars; read it in parts]"
    end
  end
end
