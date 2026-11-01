# frozen_string_literal: true

module Samagotchi
  module LLM
    # A reply that is nothing but a tool call written as text. The host's
    # parser could not read the block, so it came back as plain content with
    # no tool calls: a Qwen flavour that writes `<parameter=execute>` where
    # `<function=execute>` belongs, seen twice in 14 days of chat-loop
    # sessions (docs/internals/engine.md, "A reply that is only a tool call").
    # It is not an answer, and nothing is guessed from it: ChatLoop asks for
    # the reply once more, and a second one fails the turn.
    #
    # The rule is the narrow one the data supports, and it needs no model
    # profile (ChatLoop has no ToolCallParser): the whole reply is one closed
    # block that opens with the call. A reply opening with prose, a fence or
    # a quote is an answer, and so is one that mentions, quotes or fences the
    # syntax. KernelLoop has its own path for a corrupt generation
    # (ToolCallParser#malformed, per profile); this predicate is ChatLoop's.
    module StrayToolCall
      # A stray call can only open with the block itself.
      OPENS = ["<tool_call>", "<function=", "<parameter="].freeze
      # ... and end with the close of that block: nothing else in the reply.
      CLOSES = ["</function>", "</parameter>", "</tool_call>"].freeze
      # A block carries its own tags; an answer that merely starts with a
      # "<" is not one.
      INNER_TAG = /<[a-z_]+=/i
      # How much of the reply the warning keeps (KernelLoop's own cap).
      TAIL_CHARS = 400

      module_function

      # @return [String, nil] the shape of the reply ("tool_call", "function"
      # or "parameter") when all of it is one closed tool-call block, nil
      # when it reads as an answer.
      # +text+ is the reply with its thought already stripped (ChatLoop's
      # strip_model_thought).
      def shape(text)
        body = text.to_s.strip
        # The cheap gate: a whole block has to open with the block. This is
        # the whole cost of the check on a normal answer.
        return nil unless body.start_with?("<")

        opener = OPENS.find { |open| body.start_with?(open) }
        return nil if opener.nil?
        return nil unless CLOSES.any? { |close| body.end_with?(close) }

        # The tags inside it: a lone opening tag in a sentence is not a call
        # the host tried to read.
        return nil unless body[1..-2].match?(INNER_TAG)

        opener[/[a-z_]+/]
      end

      # The tail of a stray reply the log keeps, to see what the host sent.
      def tail(text)
        text = text.to_s
        text.length > TAIL_CHARS ? text[-TAIL_CHARS..] : text
      end
    end
  end
end
