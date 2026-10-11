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
  # +reasoning_history+ a level Symbol (ReasoningHistory.session_level) or nil,
  # +appended_prompt_files+ the absolute paths chi --append-system-prompt
  # named (their text goes into the system prompt; [] with none).
  #
  # It doesn't save itself: the session keeps each setting in its own field
  # and file key, and resolves it on its own. A delegate child starts
  # without one; a continue and a fork copy their session's (.of).
  SessionSetup = Data.define(:llm_context, :thinking, :reasoning_history, :appended_prompt_files) do
    def initialize(llm_context: nil, thinking: nil, reasoning_history: nil, appended_prompt_files: [])
      super(llm_context: llm_context, thinking: thinking, reasoning_history: reasoning_history,
            appended_prompt_files: Array(appended_prompt_files).map(&:to_s).freeze)
    end

    def empty? = llm_context.nil? && thinking.nil? && reasoning_history.nil? && appended_prompt_files.empty?

    # A session's own setup, for a session that starts from it.
    # @param session [Session, nil]
    # @return [SessionSetup]
    def self.of(session)
      return new if session.nil?

      new(llm_context: session.llm_context, thinking: session.thinking, reasoning_history: session.reasoning_history,
          appended_prompt_files: session.appended_prompt_files)
    end
  end
end
