# frozen_string_literal: true

module Samagotchi
  module Tools
    # find_tools' answer text that the wire reads too, kept a leaf (no
    # requires): ToolIndex writes CALL_HINT as a keyword answer's first
    # line, and LLM::AnthropicWire strips it from a result whose tools it
    # loads (they are called directly then).
    module IndexHint
      # A keyword answer's first line; call_tool is BuiltinCalls::VIA.
      CALL_HINT = "Call one with call_tool(tool: \"<group>/<tool>\", args: {…})."
    end
  end
end
