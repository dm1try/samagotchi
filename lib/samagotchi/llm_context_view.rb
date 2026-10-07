# frozen_string_literal: true

module Samagotchi
  # What the model is sent of the stored conversation: the one step
  # between a session's messages and the three places that format them
  # for a request (KernelLoop#format_prompt and #warmup_prompt, the native
  # prompt; ChatLoop#wire_messages, the chat messages). A strategy may
  # change what is sent; the session keeps the originals.
  #
  # Under +none+ (the default) nothing changes: #messages returns the
  # conversation it was given, the same Array of the same entries, so the
  # prompt is byte for byte what it was before the view existed.
  class LLMContextView
    NONE = :none

    attr_reader :strategy

    # @param strategy [Symbol] :none
    def initialize(strategy: NONE)
      @strategy = strategy
    end

    def none? = strategy == NONE

    # @param conversation [Array<Hash>] the stored entries, in order
    # @return [Array<Hash>] the entries to format
    def messages(conversation)
      conversation
    end
  end
end
