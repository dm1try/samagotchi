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
    # The rule: the whole reply is one closed block that opens with the call
    # and ends with that call's own close. It needs no model profile (ChatLoop
    # has no ToolCallParser). A reply opening with prose, a fence or a quote is
    # an answer, and so is one that mentions, quotes or fences the syntax, or
    # says anything after the close. The block carries no inner tags: an empty
    # `<function=task_list></function>` and `<tool_call>{"name":"x"}</tool_call>`
    # are calls the host could not read just as much as one with its
    # `<parameter=` inside. Widening past the inner tag costs at most one
    # hidden retry, and nothing is guessed from the block, so a reply that
    # reads as a call is treated as one. KernelLoop has its own path for a
    # corrupt generation (ToolCallParser#malformed, per profile); this
    # predicate is ChatLoop's.
    module StrayToolCall
      # A stray call can only open with the block itself.
      OPENS = ["<tool_call>", "<function=", "<parameter="].freeze
      # ... and end with the close of that same block: nothing else in the
      # reply. A `<parameter=` call often closes with `</function>` (the
      # flavour that mixes the two tags does it mid-block too).
      CLOSES = {
        "<tool_call>" => ["</tool_call>"],
        "<function=" => ["</function>"],
        "<parameter=" => ["</parameter>", "</function>"]
      }.freeze
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
        # The close belongs to the opener: text that ends in any other tag is
        # not one call the host tried to read.
        return nil unless CLOSES[opener].any? { |close| body.end_with?(close) }

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
