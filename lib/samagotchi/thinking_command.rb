# frozen_string_literal: true

require_relative "cache_confirm"
require_relative "thinking"

module Samagotchi
  # /thinking, the session's own thinking level (Session#thinking): with no
  # argument, the level the next turn runs at and where it came from;
  # `/thinking off|low|medium|high` sets the session's own, `/thinking
  # default` unsets it (the session follows the process default, the
  # model, its host, then thinking.level). A change takes effect at the
  # next turn's start (the REPL and the worker run it between turns), and
  # the reply says what it costs the prompt cache (Thinking.cache_cost).
  # A costly change asks first (CacheConfirm); --yes (or -y) applies it.
  class ThinkingCommand
    NAME = "/thinking"
    SETTABLE = (Thinking::LEVELS - [Thinking::DEFAULT]).freeze
    USAGE = "usage: #{NAME} [#{Thinking::LEVELS.join("|")}]".freeze

    COST_NOTES = {
      full: "On this model the whole prompt is read again (Gemma's <|think|> starts it).",
      provider: "The request's thinking fields change: a hosted API (OpenRouter, Claude, OpenAI) reads the whole " \
                "conversation again.",
      tail: "Only the prompt's tail changes: the cache keeps the rest."
    }.freeze

    # @param engine [Engine] #thinking_explained(own:), #thinking_override(=),
    #   #session, #thinking_cache_cost, #history?
    # @param save [#call] saves the session after a change
    def initialize(engine:, save:)
      @engine = engine
      @save = save
    end

    # @param args [String] what follows /thinking (--yes anywhere)
    # @param confirm [Boolean] ask before a costly change (CacheConfirm);
    #   false applies it at once (chi send, a delegate, a start flag)
    # @return [Array(String, Boolean, CacheConfirm::Confirm|nil)] the reply,
    #   whether the level changed, and the confirm it asks for (nothing
    #   changed then)
    # @raise [ArgumentError] a word that isn't a level (with USAGE)
    def run(args, confirm: true)
      word, yes = CacheConfirm.split(args)
      return [listing(@engine.thinking_explained), false, nil] if word.empty?

      level = word.to_sym
      raise ArgumentError, "unknown thinking level #{word}\n#{USAGE}" unless Thinking::LEVELS.include?(level)

      session = @engine.session or raise ArgumentError, "no session yet"
      own = SETTABLE.include?(level) ? level : nil
      before = @engine.thinking_explained
      ask = confirm && !yes ? ask(before, own, word) : nil
      return ask if ask

      @engine.thinking_override = own
      @save.call(session)
      after = @engine.thinking_explained
      [[listing(after), *notes(before, after)].join("\n"), true, nil]
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

    # The reply that asks before a costly change, nil when it needn't.
    def ask(before, own, word)
      would = @engine.thinking_explained(own: own)
      return nil unless before && would

      cost = @engine.thinking_cache_cost
      return nil unless CacheConfirm.needed?(cost: cost, history: @engine.history?, changed: would.level != before.level)

      step = CacheConfirm.confirm(NAME, word)
      [[listing(before), "Switching to #{would.level} restarts the prompt cache: #{COST_NOTES[cost]}", step.text].join("\n"), false, step]
    end

    def notes(before, after)
      return [] unless before && after
      return ["(no change to what the next turn runs under)"] if before.level == after.level

      ["From the next turn's start (a running turn keeps its own).", COST_NOTES[@engine.thinking_cache_cost]].compact
    end
  end
end
