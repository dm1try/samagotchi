# frozen_string_literal: true

require_relative "level_setting_command"
require_relative "thinking"

module Samagotchi
  # /thinking, the session's own thinking level (Session#thinking):
  # `/thinking off|low|medium|high` sets it, `/thinking default` unsets it
  # (the session follows the process default, the model, its host, then
  # thinking.level). What a change costs the prompt cache:
  # Thinking.cache_cost. See LevelSettingCommand.
  class ThinkingCommand < LevelSettingCommand
    NAME = "/thinking"
    SETTABLE = (Thinking::LEVELS - [Thinking::DEFAULT]).freeze
    USAGE = "usage: #{NAME} [#{Thinking::LEVELS.join("|")}]".freeze

    COST_NOTES = {
      full: "On this model the whole prompt is read again (Gemma's <|think|> starts it).",
      provider: "The request's thinking fields change: a hosted API (OpenRouter, Claude, OpenAI) reads the whole " \
                "conversation again.",
      tail: "Only the prompt's tail changes: the cache keeps the rest."
    }.freeze

    SPEC = Spec.new(
      name: NAME, label: "thinking", usage: USAGE, cost_notes: COST_NOTES,
      parse: lambda { |word|
        level = word.to_sym
        if Thinking::LEVELS.include?(level)
          [true, SETTABLE.include?(level) ? level : nil]
        else
          [false, nil]
        end
      },
      own: lambda(&:thinking_override),
      explained: ->(engine, own) { engine.thinking_explained(own: own) },
      set: ->(engine, own) { engine.thinking_override = own },
      cache_cost: ->(engine, _from, _to) { engine.thinking_cache_cost },
      follows: "chi web --thinking / SAMAGOTCHI_THINKING_LEVEL, the model, its host, then thinking.level",
      extra_line: nil
    )
  end
end
