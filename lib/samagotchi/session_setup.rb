# frozen_string_literal: true

require_relative "llm_context_override"
require_relative "reasoning_history"
require_relative "thinking"
require_relative "toolkit"
require_relative "session_config"
require_relative "working_set_pin"

module Samagotchi
  # A session's own settings that come before its model's, carried as one
  # value on the paths that spawn a session from a whole setup
  # (SessionManager.spawn_session, a continue, a plugin's fork, the web's
  # create, chi send --new): +llm_context+ is an LLMContextOverride or nil,
  # +thinking+ a level Symbol (Thinking.session_level) or nil,
  # +reasoning_history+ a level Symbol (ReasoningHistory.session_level) or nil,
  # +appended_prompt_files+ the absolute paths chi --append-system-prompt
  # named (their text goes into the system prompt; [] with none),
  # +toolkit+ a Toolkit or nil (SessionManager.spawn_session gives the
  # session config's toolkit.default then), +settings+ the session's own
  # settings chi --set gave (SessionConfig::Settings; its bundles part is
  # what Plugin::Context#settings lays over config.yml's),
  # +parent_answers+ the session's own guardrails.parent_answers (a level
  # String, tighten-only: Guardrails::ParentPolicy.effective) or nil,
  # +working_set_pins+ the items the user pinned in the working set
  # (WorkingSetPin; [] with none).
  #
  # It doesn't save itself: the session keeps each setting in its own field
  # and file key, and resolves it on its own. A delegate child starts
  # without one (but the toolkit its delegate call named, and its parent's
  # parent_answers); a continue and a fork copy their session's (.of).
  SessionSetup = Data.define(:llm_context, :thinking, :reasoning_history, :appended_prompt_files, :toolkit,
                             :settings, :parent_answers, :working_set_pins) do
    def initialize(llm_context: nil, thinking: nil, reasoning_history: nil, appended_prompt_files: [], toolkit: nil,
                   settings: nil, parent_answers: nil, working_set_pins: [])
      super(llm_context: llm_context, thinking: thinking, reasoning_history: reasoning_history,
            appended_prompt_files: Array(appended_prompt_files).map(&:to_s).freeze, toolkit: toolkit,
            settings: SessionConfig::Settings.of(settings), parent_answers: parent_answers&.to_s,
            working_set_pins: WorkingSetPin.list(working_set_pins))
    end

    def empty?
      llm_context.nil? && thinking.nil? && reasoning_history.nil? && appended_prompt_files.empty? && toolkit.nil? &&
        settings.empty? && parent_answers.nil? && working_set_pins.empty?
    end

    # A session's own setup, for a session that starts from it. Its
    # toolkit always: one from before toolkits is full (Toolkit.of), not
    # whatever config's default is now.
    # @param session [Session, nil]
    # @return [SessionSetup]
    def self.of(session)
      return new if session.nil?

      new(llm_context: session.llm_context, thinking: session.thinking, reasoning_history: session.reasoning_history,
          appended_prompt_files: session.appended_prompt_files, toolkit: Toolkit.of(session.toolkit),
          settings: session.settings, parent_answers: session.parent_answers,
          working_set_pins: session.working_set_pins)
    end
  end
end
