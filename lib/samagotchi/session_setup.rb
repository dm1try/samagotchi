# frozen_string_literal: true

require_relative "llm_context_override"
require_relative "reasoning_history"
require_relative "thinking"

module Samagotchi
  # A session's own settings that come before its model's, carried as one
  # value on the paths that spawn a session from a whole setup
  # (SessionManager.spawn_session, a continue, a plugin's fork, the web's
  # create, chi send --new): +llm_context+ is an LLMContextOverride or nil,
  # +thinking+ a level Symbol (Thinking.session_level) or nil,
  # +reasoning_history+ a level Symbol (ReasoningHistory.session_level) or nil.
  #
  # It doesn't save itself: the session keeps each setting in its own field
  # and file key, and resolves it on its own. A delegate child starts
  # without one; a continue and a fork copy their session's (.of).
  SessionSetup = Data.define(:llm_context, :thinking, :reasoning_history) do
    def initialize(llm_context: nil, thinking: nil, reasoning_history: nil) = super

    def empty? = llm_context.nil? && thinking.nil? && reasoning_history.nil?

    # A session's own setup, for a session that starts from it.
    # @param session [Session, nil]
    # @return [SessionSetup]
    def self.of(session)
      return new if session.nil?

      new(llm_context: session.llm_context, thinking: session.thinking, reasoning_history: session.reasoning_history)
    end
  end
end
