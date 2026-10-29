# frozen_string_literal: true

require_relative "cache_confirm"

module Samagotchi
  # A command for a session's own level of a setting (/thinking,
  # /reasoning-history): with no argument, the level the next turn runs at
  # and where it came from; with a level, sets the session's own (the
  # setting's unset word unsets it). A change takes effect at the next
  # turn's start (the REPL and the worker run it between turns), and the
  # reply says what it costs the prompt cache. A costly change asks first
  # (CacheConfirm); --yes (or -y) applies it.
  #
  # A subclass gives its Spec (#spec): what differs between the settings.
  class LevelSettingCommand
    # name: the command; label: the reply's ("thinking: low (session)");
    # usage: the usage line an unknown word gets;
    # parse: word → [known?, the session's own level (nil unsets)];
    # own: engine → the session's own level now;
    # explained: (engine, own) → SettingExplained, nil when it can't be resolved;
    # set: (engine, own) → sets the session's own;
    # cache_cost: (engine, from_level, to_level) → a cost_notes key, nil for none;
    # cost_notes: {cost => the reply's line};
    # follows: what the session follows with no own level;
    # extra_line: engine → one more listing line, nil for none.
    Spec = Data.define(:name, :label, :usage, :parse, :own, :explained, :set, :cache_cost, :cost_notes, :follows,
                       :extra_line)

    # @param engine [Engine] the session's (#session, #history? and the spec's readers)
    # @param save [#call] saves the session after a change
    def initialize(engine:, save:)
      @engine = engine
      @save = save
    end

    # @param args [String] what follows the command (--yes anywhere)
    # @param confirm [Boolean] ask before a costly change (CacheConfirm);
    #   false applies it at once (chi send, a delegate, a start flag)
    # @return [Array(String, Boolean, CacheConfirm::Confirm|nil)] the reply,
    #   whether the level changed, and the confirm it asks for (nothing
    #   changed then)
    # @raise [ArgumentError] a word that isn't a level (with the usage)
    def run(args, confirm: true)
      word, yes = CacheConfirm.split(args)
      return [listing(explained), false, nil] if word.empty?

      known, own = spec.parse.call(word)
      raise ArgumentError, "unknown #{spec.label} level #{word}\n#{spec.usage}" unless known

      session = @engine.session or raise ArgumentError, "no session yet"
      before = explained
      ask = confirm && !yes ? ask(before, own, word) : nil
      return ask if ask

      spec.set.call(@engine, own)
      @save.call(session)
      after = explained
      [[listing(after), *notes(before, after)].join("\n"), true, nil]
    end

    # The level, where it came from, and what the session sets itself.
    def listing(explained)
      return "#{spec.label}: can't be resolved for this model" unless explained

      lines = ["#{spec.label}: #{explained.label}"]
      lines << "  this session's own: none (follows #{spec.follows})" unless explained.own
      extra = spec.extra_line&.call(@engine)
      lines << extra if extra
      lines.join("\n")
    end

    private

    def spec = self.class::SPEC

    def explained(own: spec.own.call(@engine)) = spec.explained.call(@engine, own)

    # The reply that asks before a costly change, nil when it needn't.
    def ask(before, own, word)
      would = explained(own: own)
      return nil unless before && would

      cost = spec.cache_cost.call(@engine, before.level, would.level)
      step = CacheConfirm.ask(line: "#{spec.name} #{word}", cost: cost, changed: would.level != before.level,
                              engine: @engine)
      return nil unless step

      [[listing(before), "Switching to #{would.level} restarts the prompt cache: #{spec.cost_notes[cost]}", step.text].join("\n"),
       false, step]
    end

    def notes(before, after)
      return [] unless before && after
      return ["(no change to what the next turn runs under)"] if before.level == after.level

      cost = spec.cache_cost.call(@engine, before.level, after.level)
      ["From the next turn's start (a running turn keeps its own).", spec.cost_notes[cost]].compact
    end
  end
end
