# frozen_string_literal: true

require_relative "thinking"

module Samagotchi
  # /thinking, the session's own thinking level (Session#thinking): with no
  # argument, the level the next turn runs at and where it came from;
  # `/thinking off|low|medium|high` sets the session's own, `/thinking
  # default` unsets it (the session follows the process default, the
  # model, its host, then thinking.level). A change takes effect at the
  # next turn's start (the REPL and the worker run it between turns), and
  # the reply says what it costs the prompt cache (Thinking.cache_cost).
  class ThinkingCommand
    NAME = "/thinking"
    SETTABLE = (Thinking::LEVELS - [Thinking::DEFAULT]).freeze
    USAGE = "usage: #{NAME} [#{Thinking::LEVELS.join("|")}]".freeze

    COST_NOTES = {
      full: "On this model the whole prompt is read again (Gemma's <|think|> starts it).",
      provider: "The request's thinking fields change: a local llama.cpp or Splash server keeps its cache; " \
                "hosted APIs (OpenRouter → Claude, OpenAI) may restart theirs.",
      tail: "Only the prompt's tail changes: the cache keeps the rest."
    }.freeze

    # @param engine [Engine] #thinking_explained, #thinking_override(=),
    #   #session, #thinking_cache_cost
    # @param save [#call] saves the session after a change
    def initialize(engine:, save:)
      @engine = engine
      @save = save
    end

    # @param args [String] what follows /thinking
    # @return [Array(String, Boolean)] the reply and whether the level changed
    # @raise [ArgumentError] a word that isn't a level (with USAGE)
    def run(args)
      word = args.to_s.strip.downcase
      return [listing(@engine.thinking_explained), false] if word.empty?

      level = word.to_sym
      raise ArgumentError, "unknown thinking level #{word}\n#{USAGE}" unless Thinking::LEVELS.include?(level)

      session = @engine.session or raise ArgumentError, "no session yet"
      before = @engine.thinking_explained
      @engine.thinking_override = SETTABLE.include?(level) ? level : nil
      @save.call(session)
      after = @engine.thinking_explained
      [[listing(after), *notes(before, after)].join("\n"), true]
    end

    # The level, where it came from, and what the session sets itself.
    def listing(explained)
      return "thinking: can't be resolved for this model" unless explained

      lines = ["thinking: #{explained.label}"]
      unless explained.own
        lines << "  this session's own: none (follows chi web --thinking / SAMAGOTCHI_THINKING_LEVEL, the model, " \
                 "its host, then thinking.level)"
      end
      lines.join("\n")
    end

    private

    def notes(before, after)
      return [] unless before && after
      return ["(no change to what the next turn runs under)"] if before.level == after.level

      ["From the next turn's start (a running turn keeps its own).", COST_NOTES[@engine.thinking_cache_cost]].compact
    end
  end
end
