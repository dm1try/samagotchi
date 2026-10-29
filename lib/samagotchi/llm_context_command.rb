# frozen_string_literal: true

require_relative "llm_context_override"
require_relative "llm_context_strategy"
require_relative "llm_context_edit"
require_relative "llm_context_stale"
require_relative "cache_confirm"

module Samagotchi
  # /llm-context, the session's own LLM context values
  # (LLMContextOverride): with no arguments, the strategy, apply rule and
  # budget the next turn runs under and where each came from (the session,
  # models: <key>, a hosts entry, llm_context.*); with
  # `strategy <layers|none>`, `apply <rule>` and `budget <N|off>` (any of
  # them, in one line; `default` unsets one) it sets the session's own, and
  # `reset` unsets them all. A change takes effect at the next turn's
  # start (the REPL and the worker run it between turns), and the reply
  # says what it costs: forget on or off changes the tool list and the
  # system prompt (a full cache break); stale turned on stages the reads
  # already superseded as one batch under the apply rule; a layer turned
  # off sends its stubs whole again (the originals stay in the session, so
  # turning it back on brings them back). The two that restart the prompt
  # cache (forget on or off, stubs sent whole again) ask first
  # (CacheConfirm, #cache_cost); --yes (or -y) applies them.
  class LLMContextCommand
    NAME = LLMContextOverride::COMMAND
    USAGE = "usage: #{NAME} [strategy <none|stale,forget|default>] [apply <payoff|next_request|turn_end|default>] " \
            "[budget <tokens|64k|off|default>] | #{NAME} reset".freeze
    RESET = "reset"
    FIELDS = LLMContextOverride::COMMAND_WORDS.invert.freeze

    # @param engine [Engine] #llm_context_explained, #llm_context_override(=), #session
    # @param save [#call] saves the session after a change
    def initialize(engine:, save:)
      @engine = engine
      @save = save
    end

    # @param args [String] what follows /llm-context (--yes anywhere)
    # @param confirm [Boolean] ask before a change that restarts the prompt
    #   cache (CacheConfirm, #cache_cost); false applies it at once (chi
    #   send, a delegate, a start flag)
    # @return [Array(String, Boolean, CacheConfirm::Confirm|nil)] the reply,
    #   whether the values changed, and the confirm it asks for (nothing
    #   changed then)
    # @raise [ArgumentError] a line that isn't one (its message and USAGE)
    def run(args, confirm: true)
      # Before #words: it refuses --yes, and "reset --yes" isn't RESET.
      args, yes = CacheConfirm.split(args, downcase: false)
      return [listing(@engine.llm_context_explained), false, nil] if args.empty?

      session = @engine.session or raise ArgumentError, "no session yet"
      before = @engine.llm_context_explained
      updated = args.casecmp?(RESET) ? LLMContextOverride.new : LLMContextOverride.update(@engine.llm_context_override, words(args))
      ask = confirm && !yes ? ask(session, before, updated, args) : nil
      return ask if ask

      @engine.llm_context_override = updated
      @save.call(session)
      after = @engine.llm_context_explained
      [[listing(after), *notes(session, before&.resolved, after&.resolved)].join("\n"), true, nil]
    end

    # What a change from +before+ to +after+ (Resolved) costs the prompt
    # cache, nil for nothing worth asking about: forget on or off changes
    # the tool list and the system prompt (:full); a layer turned off while
    # it has applied stubs sends them whole again (:history). Stale turned
    # on only stages a batch under the apply rule (its break comes later,
    # as designed), and the apply rule and budget only decide when a break
    # comes: a switch to next_request with staged edits pending applies
    # them at the next request, a break the old rule makes by the end of
    # the next turn anyway.
    # @return [Symbol, nil]
    def cache_cost(session, before, after)
      return nil unless before && after

      was = before.active_layers
      now = after.active_layers
      return :full if was.include?(:forget) != now.include?(:forget)

      :history if (was - now).any? { |layer| applied_count(session.messages, layer).positive? }
    end

    # The values, where each came from, and what the session sets itself.
    def listing(explained)
      return "llm context: can't be resolved for this model" unless explained

      resolved = explained.resolved
      own = @engine.llm_context_override
      set = own ? LLMContextOverride::FIELDS.filter_map { |field| own_word(own, field) }.join("; ") : nil
      [
        "llm context: #{strategy_word(resolved)} (#{explained.strategy.where})",
        "  apply:  #{resolved.apply} (#{explained.apply.where})",
        "  budget: #{resolved.budget_tokens ? "#{resolved.budget_tokens} tokens" : "off"} (#{explained.budget_tokens.where})",
        "  this session's own: #{set.to_s.empty? ? "none (follows the model, its host, then llm_context.*)" : set}"
      ].join("\n")
    end

    private

    # The reply that asks before a costly change (CacheConfirm), nil when
    # it needn't.
    def ask(session, before, updated, args)
      would = @engine.llm_context_explained(own: updated)
      was = before&.resolved
      now = would&.resolved
      cost = cache_cost(session, was, now)
      step = CacheConfirm.ask(line: "#{NAME} #{args}", cost: cost, changed: !cost.nil?, engine: @engine)
      return nil unless step

      costs = notes(session, was, now).drop(1).reject { |note| note.start_with?("stale:") }
      [[listing(before), "This change restarts the prompt cache:", *costs, step.text].join("\n"), false, step]
    end

    # "strategy stale stale forget apply turn_end budget 64k" as fields
    # and their words; a strategy takes the words up to the next field.
    def words(args)
      fields = {}
      field = nil
      args.split.each do |token|
        if FIELDS.key?(token.downcase) && (field.nil? || fields[field])
          field = FIELDS[token.downcase]
          raise ArgumentError, "#{token} is given twice\n#{USAGE}" if fields.key?(field)

          fields[field] = nil
        elsif field.nil?
          raise ArgumentError, "unknown #{NAME} word #{token}\n#{USAGE}"
        elsif fields[field].nil? || field == :strategy
          fields[field] = [fields[field], token].compact.join(" ")
        else
          raise ArgumentError, "#{FIELDS.key(field)} takes one value, not #{fields[field]} #{token}\n#{USAGE}"
        end
      end
      missing = fields.find { |_field, word| word.nil? }
      raise ArgumentError, "#{FIELDS.key(missing.first)} needs a value\n#{USAGE}" if missing

      fields
    end

    def own_word(own, field)
      word = LLMContextOverride.word(field, own.public_send(field))
      word && "#{LLMContextOverride::COMMAND_WORDS[field]} #{word}"
    end

    def strategy_word(resolved) = resolved.active_layers.empty? ? "none" : resolved.active_layers.join(", ")

    # What the change does from the next turn on.
    def notes(session, before, after)
      return [] unless before && after
      return ["(no change to what the next turn runs under)"] if before.with(source: nil) == after.with(source: nil)

      was = before.active_layers
      now = after.active_layers
      notes = ["From the next turn's start (a running turn keeps its own)."]
      notes << forget_note(now.include?(:forget)) if was.include?(:forget) != now.include?(:forget)
      notes << stale_note(session, after) if now.include?(:stale) && !was.include?(:stale)
      (was - now).each do |layer|
        count = applied_count(session.messages, layer)
        next if count.zero?

        notes << "#{layer}'s #{count} stub#{"s" if count != 1} go#{"es" if count == 1} out whole again (a cache break " \
                 "from the first; the originals stay in the session, and turning #{layer} back on brings the stubs back)."
      end
      notes
    end

    def forget_note(on)
      verb = on ? "joins" : "leaves"
      note = "forget_outputs #{verb} the tool list and the system prompt#{" (and outputs show their ids)" if on}: " \
             "the next request re-reads the whole prompt (a full cache break)."
      on ? note : "#{note} Its past forget_outputs calls and their results stay in the history."
    end

    # How many past reads are already superseded, and when they go in.
    def stale_note(session, resolved)
      found = LLMContextStale.found(session.messages, root: session.working_directory.to_s,
                                                      changes: resolved.stale_edits).size
      return "stale: no past read is superseded yet." if found.zero?

      when_in = case resolved.apply
                when :next_request then "at the next request"
                when :turn_end then "at the end of the next turn"
                else "at the next request if what it frees pays for the re-read tail, else at the end of the next turn"
                end
      "stale: #{found} past read#{"s" if found != 1} already superseded go#{"es" if found == 1} in as one batch " \
        "under apply #{resolved.apply}: #{when_in}."
    end

    def applied_count(messages, layer)
      Array(messages).sum do |entry|
        next 0 unless entry[:role].to_s == "tool_response"

        LLMContextEdit.on(entry).values.count { |edit| edit.applied? && edit.kind == layer }
      end
    end
  end
end
