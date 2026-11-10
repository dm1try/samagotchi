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
  #   session config's toolkit.default then), +toolkit_origin+ the reason
  #   for that choice (chosen, default or inherited), +settings+ the session's own
  # settings chi --set gave (SessionConfig::Settings; its bundles part is
  # what Plugin::Context#settings lays over config.yml's),
  # +parent_answers+ the session's own guardrails.parent_answers (a level
  # String, tighten-only: Guardrails::ParentPolicy.effective) or nil,
  # +working_set_pins+ the items the user pinned in the working set
  # (WorkingSetPin; [] with none), +preloaded_memory_names+ and
  # +muted_memory_names+ the names --memory and --mute selected ([] with
  # none). A delegate source's reserved memory is not copied to a normal
  # child, and a fork cannot inherit it because its parent_id would mark it
  # as a delegate.
  #
  # It doesn't save itself: the session keeps each setting in its own field
  # and file key, and resolves it on its own. A delegate child starts
  # without one (but the toolkit its delegate call named, and its parent's
  # parent_answers); a continue and a fork copy their session's (.of).
  SessionSetup = Data.define(:llm_context, :thinking, :reasoning_history, :appended_prompt_files,
                             :preloaded_memory_names, :muted_memory_names, :toolkit, :toolkit_origin, :settings,
                             :parent_answers, :working_set_pins) do
    def initialize(llm_context: nil, thinking: nil, reasoning_history: nil, appended_prompt_files: [], toolkit: nil,
                   preloaded_memory_names: [], muted_memory_names: [], toolkit_origin: nil, settings: nil,
                   parent_answers: nil, working_set_pins: [])
      toolkit_origin ||= "chosen" if toolkit
      super(llm_context: llm_context, thinking: thinking, reasoning_history: reasoning_history,
            appended_prompt_files: Array(appended_prompt_files).map(&:to_s).freeze, toolkit: toolkit,
            preloaded_memory_names: name_list(preloaded_memory_names),
            muted_memory_names: name_list(muted_memory_names), toolkit_origin: toolkit_origin&.to_s,
            settings: SessionConfig::Settings.of(settings), parent_answers: parent_answers&.to_s,
            working_set_pins: WorkingSetPin.list(working_set_pins))
    end

    # Every member at its default: none of the session's own settings.
    def empty? = self == self.class.new

    # A session's own setup, for a session that starts from it: each
    # member is the session's field of the same name (Session.new_session
    # applies them by name), but for SessionSetup::CARRY's. Its toolkit
    # always: one from before toolkits is full (Toolkit.of), not whatever
    # config's default is now.
    # @param session [Session, nil]
    # @param forked [Boolean] whether the new session is a forked child
    # @return [SessionSetup]
    def self.of(session, forked: false)
      return new if session.nil?

      values = members.to_h do |member|
        [member, self::CARRY.fetch(member) { ->(s) { s.public_send(member) } }.call(session)]
      end
      if forked || session.delegate?
        values[:preloaded_memory_names] = values[:preloaded_memory_names].reject do |name|
          name == Session::DELEGATE_MEMORY
        end
      end
      new(**values)
    end

    private

    def name_list(names) = Array(names).map { |name| name.to_s.strip }.reject(&:empty?).uniq.freeze
  end

  # How SessionSetup.of carries a member that isn't its session's field as
  # it is: member => (session) -> value.
  SessionSetup::CARRY = {
    toolkit: ->(session) { Toolkit.of(session.toolkit) },
    toolkit_origin: ->(_session) { "inherited" }
  }.freeze
end
