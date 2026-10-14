# frozen_string_literal: true

require_relative "level_setting_command"
require_relative "reasoning_history"

module Samagotchi
  # /reasoning-history, the session's own reasoning_history level
  # (Session#reasoning_history): `/reasoning-history drop|turn|all` sets it
  # (an explicit turn too), `/reasoning-history default` unsets it (the
  # session follows SAMAGOTCHI_REASONING_HISTORY, the model, its host, then
  # turn). Resolved on any host: a native one ignores the level (its loop
  # keeps the running turn's reasoning), but the session keeps it for a
  # chat model. A change that rewrites the earlier replies asks first. See
  # LevelSettingCommand.
  class ReasoningHistoryCommand < LevelSettingCommand
    NAME = "/reasoning-history"
    USAGE = "usage: #{NAME} [#{(ReasoningHistory::LEVELS + [ReasoningHistory::UNSET]).join("|")}]".freeze
    NATIVE_NOTE = "  (ignored on this host: the native loop keeps the running turn's reasoning)"
    # ReasoningHistory.cache_cost's; nil (no cost) says nothing.
    COST_NOTES = {
      history: "Earlier replies gain or lose their reasoning: the server reads the conversation again " \
               "from the first earlier thought."
    }.freeze

    SPEC = Spec.new(
      name: NAME, label: "reasoning history", usage: USAGE, cost_notes: COST_NOTES,
      parse: lambda { |word|
        level = ReasoningHistory.session_level(word)
        [!level.nil? || word == ReasoningHistory::UNSET, level]
      },
      own: lambda(&:reasoning_history_override),
      explained: ->(engine, own) { engine.reasoning_history_explained(native: true, own: own) },
      set: ->(engine, own) { engine.reasoning_history_override = own },
      cache_cost: ->(engine, from, to) { engine.reasoning_history_cache_cost(from, to) },
      follows: "#{ReasoningHistory::ENV_NAME}, the model, its host, then turn",
      extra_line: lambda { |engine|
        chat = begin
          engine.chat_model?
        rescue StandardError
          false
        end
        chat ? nil : NATIVE_NOTE
      }
    )
  end
end
