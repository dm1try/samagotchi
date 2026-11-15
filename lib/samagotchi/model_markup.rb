# frozen_string_literal: true

module Samagotchi
  # The plain Qwen-style markup tokens, apart from the model-specific token
  # formats. ModelProfile, ToolCallParser, StrayToolCall, PromptLiteralGuard,
  # TurnNote, MessageParts, AnswerText, LLMContextStale and ParticipantView
  # read them here without loading a tool class.
  #
  # No requires: it is a leaf every client can load.
  module ModelMarkup
    TOOL_CALL_OPEN = "<tool_call>"
    TOOL_CALL_CLOSE = "</tool_call>"
    FUNCTION_OPEN = "<function="
    FUNCTION_CLOSE = "</function>"
    PARAMETER_OPEN = "<parameter="
    PARAMETER_CLOSE = "</parameter>"
    TOOL_RESPONSE_OPEN = "<tool_response>"
    TOOL_RESPONSE_CLOSE = "</tool_response>"
    THINK_OPEN = "<think>"
    THINK_CLOSE = "</think>"
  end
end
