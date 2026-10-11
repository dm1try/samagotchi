# frozen_string_literal: true

require_relative "cache_confirm"
require_relative "reasoning_history"

module Samagotchi
  # /reasoning-history, the session's own reasoning_history level
  # (Session#reasoning_history): with no argument, the level the next turn
  # runs under and where it came from; `/reasoning-history drop|turn|all`
  # sets the session's own (an explicit turn too), `/reasoning-history
  # default` unsets it (the session follows SAMAGOTCHI_REASONING_HISTORY,
  # the model, its host, then turn). A change takes effect at the next
  # turn's start; a native host ignores the level (its loop keeps the
  # running turn's reasoning), but the session keeps it for a chat model.
  # A change that rewrites the earlier replies asks first (CacheConfirm);
  # --yes (or -y) applies it.
  class ReasoningHistoryCommand
    NAME = "/reasoning-history"
    USAGE = "usage: #{NAME} [#{(ReasoningHistory::LEVELS + [ReasoningHistory::UNSET]).join("|")}]".freeze
    NATIVE_NOTE = "  (ignored on this host: the native loop keeps the running turn's reasoning)"
    # ReasoningHistory.cache_cost's; nil (no cost) says nothing.
    COST_NOTES = {
      history: "Earlier replies gain or lose their reasoning: the server reads the conversation again " \
               "from the first earlier thought."
    }.freeze

    # @param engine [Engine] #reasoning_history_explained,
    #   #reasoning_history_override(=), #session, #chat_model?,
    #   #reasoning_history_cache_cost, #history?
    # @param save [#call] saves the session after a change
    def initialize(engine:, save:)
      @engine = engine
      @save = save
    end

    # @param args [String] what follows /reasoning-history (--yes anywhere)
    # @param confirm [Boolean] ask before a costly change (CacheConfirm);
    #   false applies it at once
    # @return [Array(String, Boolean, CacheConfirm::Confirm|nil)] the reply,
    #   whether the level changed, and the confirm it asks for (nothing
    #   changed then)
    # @raise [ArgumentError] a word that isn't a level (with USAGE)
    def run(args, confirm: true)
      word, yes = CacheConfirm.split(args)
      return [listing(explained), false, nil] if word.empty?

      level = ReasoningHistory.session_level(word)
      raise ArgumentError, "unknown reasoning history level #{word}\n#{USAGE}" unless level || word == ReasoningHistory::UNSET

      session = @engine.session or raise ArgumentError, "no session yet"
      before = explained
      ask = confirm && !yes ? ask(before, level, word) : nil
      return ask if ask

      @engine.reasoning_history_override = level
      @save.call(session)
      after = explained
      [[listing(after), *notes(before, after)].join("\n"), true, nil]
    end

    # The level, where it came from, and what the session sets itself.
    def listing(explained)
      return "reasoning history: can't be resolved for this model" unless explained

      lines = ["reasoning history: #{explained.label}"]
      unless explained.own
        lines << "  this session's own: none (follows #{ReasoningHistory::ENV_NAME}, the model, its host, then turn)"
      end
      lines << NATIVE_NOTE unless chat?
      lines.join("\n")
    end

    private

    # Resolved on any host: a native one ignores it, but /reasoning-history
    # still shows what a chat model would get.
    def explained(own: @engine.reasoning_history_override)
      @engine.reasoning_history_explained(native: true, own: own)
    end

    # The reply that asks before a costly change, nil when it needn't.
    def ask(before, own, word)
      would = explained(own: own)
      return nil unless before && would

      cost = @engine.reasoning_history_cache_cost(before.level, would.level)
      return nil unless CacheConfirm.needed?(cost: cost, history: @engine.history?, changed: would.level != before.level)

      step = CacheConfirm.confirm(NAME, word)
      [[listing(before), "Switching to #{would.level} restarts the prompt cache: #{COST_NOTES[cost]}", step.text].join("\n"), false, step]
    end

    def chat?
      @engine.chat_model?
    rescue StandardError
      false
    end

    def notes(before, after)
      return [] unless before && after
      return ["(no change to what the next turn runs under)"] if before.level == after.level

      cost = @engine.reasoning_history_cache_cost(before.level, after.level)
      ["From the next turn's start (a running turn keeps its own).", COST_NOTES[cost]].compact
    end
  end
end
