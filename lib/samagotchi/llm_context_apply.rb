# frozen_string_literal: true

require "time"
require_relative "llm_context_edit"
require_relative "llm_context_stale"
require_relative "llm_context_view"
require_relative "log"
require_relative "token_usage"

module Samagotchi
  # The ✂ row's builder (#apply!), loaded on first use: the test kit loads
  # this file (through the strategy) and never emits a row.
  autoload :LLMContextNotice, File.expand_path("llm_context_notice", __dir__)

  # When a layer's edits reach the prompt: the apply rule
  # (llm_context.apply, LLMContextStrategy). Every edit breaks the prompt
  # cache from the earliest entry it changes, so the edits due at one point
  # go in one batch, under one cache break.
  #
  # Two points ask (#run!): each request of both loops (+moment+ :request,
  # the warm-up too, as the next turn's first request) and the end of a
  # turn the model answered (+moment+ :turn_end). What waits between them is
  # staged: for the stale layer it is worked out again at each point from
  # the conversation itself (LLMContextStale.found with changes), so
  # nothing is kept for it and a --resume stages the same; an edit saved
  # with no applied_at (a later layer's, forget) is staged too. Only an
  # applied edit is saved (LLMContextEdit.store), and it stays.
  #
  # The rules, at a request:
  # - next_request: a read a later read superseded is applied at once (P2's
  #   behaviour); one only an edit or write superseded waits for turn end.
  # - turn_end: nothing; all of it at turn end. Where a warm-up follows
  #   (the native loop on a local llama.cpp) it warms the edited prompt;
  #   elsewhere the break moves to the next turn's first request.
  # - payoff: the whole batch is applied when the tokens it frees are at
  #   least the tail it makes the server read again (from the earliest
  #   edited entry to the end, as sent after it), or the context is in the
  #   top ContextStatus bucket; otherwise it waits for turn end.
  # At turn end every staged edit is applied, under each rule.
  #
  # Never applied, at any point: a stale stub of a read of a file the
  # last +protect_steps+ steps edited (LLMContextStale.protected_ids); a
  # forget was checked against them when the model made it.
  module LLMContextApply
    RULES = %i[payoff next_request turn_end].freeze
    MOMENTS = %i[request turn_end].freeze

    # One staged edit: the entry it goes on, the edit (applied_at nil) and
    # whether only a change superseded its read (never sent mid-edit).
    Staged = Data.define(:index, :edit, :change) do
      def change? = change
    end

    # What a point did: the edits it applied (saved on the entries), how
    # many stay staged, and for the batch it weighed (the applied one, or
    # under payoff the one it held back) the chars it frees and the tail
    # it makes the server read again; +why+: :next_request, :turn_end,
    # :payoff or :top_bucket when it applied, :held when payoff held a
    # batch back, nil when there was nothing to weigh.
    Outcome = Data.define(:applied, :staged, :freed_chars, :tail_chars, :why) do
      def self.none = new(applied: [], staged: 0, freed_chars: 0, tail_chars: 0, why: nil)

      def applied? = !applied.empty?
    end

    module_function

    # Before each request of both loops (+moment+ :request; the warm-up
    # too, on its own copy, as the next turn's first request) and at the
    # end of a turn the model answered (:turn_end): +llm_context+'s layers
    # (LLMContextStrategy::Resolved, the turn's) stage their edits on
    # +conversation+ and its apply rule (#run!) saves the batch it lets
    # through as applied, so the request about to be sent (or the next
    # turn's first, and the warm-up) is the first with the stubs.
    # +context+: the turn's ContextStatus (payoff applies in its top bucket;
    # an applied batch rebases its estimate, ContextStatus#edited!). none
    # changes nothing. Logged as llm_context_apply when a batch is applied
    # (+model+: the run's model name, in the line), and shown to the user as
    # a ✂ row (+emit+ takes the :llm_context_edited event, LLMContextNotice;
    # the warm-up's own copy, +warmup+, has neither).
    # @return [Outcome]
    def apply!(conversation, llm_context, moment: :request, context: nil, warmup: false, emit: nil, model: nil)
      view = LLMContextView.for(llm_context)
      return Outcome.none if view.none?

      outcome = run!(conversation, layers: view.layers, rule: llm_context.apply, moment: moment,
                                   protect_steps: llm_context.protect_steps, top_bucket: context&.top_bucket? || false,
                                   changes: llm_context.stale_edits)
      if outcome.applied?
        # The prompt just shrank: the context estimate counts from it.
        context&.edited!
        unless warmup
          log_applied(outcome, llm_context, moment, model)
          emit_applied(emit, conversation, outcome, moment) if emit
        end
      end
      outcome
    end

    def log_applied(outcome, llm_context, moment, model)
      Log.info(:model, "llm_context_apply", rule: llm_context.apply, at: moment, why: outcome.why,
                                            applied: outcome.applied.size, ids: outcome.applied.map(&:id).join(","),
                                            staged: outcome.staged, freed: (outcome.freed_chars / TokenUsage::CHARS_PER_TOKEN).ceil,
                                            tail: (outcome.tail_chars / TokenUsage::CHARS_PER_TOKEN).ceil,
                                            model: model)
    end

    # The batch's ✂ row; a row that can't be built never breaks the turn.
    def emit_applied(emit, conversation, outcome, moment)
      emit.call(LLMContextNotice.event(conversation, outcome, moment: moment))
    rescue StandardError => e
      Log.warn(:model, "llm_context_notice_failed", error: e.class.name, message: e.message)
    end

    # Stages what +layers+ find on +conversation+ and applies what +rule+
    # lets through at +moment+.
    # @param top_bucket [Boolean] the context is in the top ContextStatus bucket
    # @param changes [Boolean] an edit or write makes a read stale too
    #   (llm_context.stale_edits; off: later reads only, P2's rule)
    # @return [Outcome]
    def run!(conversation, layers:, rule:, moment:, protect_steps:, top_bucket: false, root: Dir.pwd,
             now: Time.now.utc.iso8601(3), changes: false)
      layers = Array(layers)
      return Outcome.none if layers.empty?

      staged = stage(conversation, layers, protect_steps, root, now, changes)
      return Outcome.none if staged.empty?

      batch, why, measured = choose(conversation, layers, staged, rule, moment, top_bucket)
      freed, tail = measured || measure(conversation, layers, batch, now)
      applied = batch.map do |item|
        edit = item.edit.with(applied_at: now)
        LLMContextEdit.store(conversation[item.index], edit)
        edit
      end
      Outcome.new(applied: applied, staged: staged.size - batch.size, freed_chars: freed, tail_chars: tail, why: why)
    end

    # The edits waiting to reach the prompt.
    # @return [Array<Staged>]
    def stage(conversation, layers, protect_steps, root, now, changes)
      staged = []
      kept = LLMContextStale.protected_ids(conversation, steps: protect_steps, root: root)
      if layers.include?(:stale)
        LLMContextStale.found(conversation, root: root, changes: changes).each do |stale|
          edit = LLMContextEdit.new(id: stale.run.ref.id, kind: :stale, note: stale.note, by: LLMContextStale::BY,
                                    staged_at: now, applied_at: nil)
          staged << Staged.new(index: stale.run.index, edit: edit, change: stale.change?)
        end
      end
      # A forget passed its own check when the model made it
      # (LLMContextForget: a read the model edits against goes only with
      # lines kept); the rule holds back only stale's.
      staged.concat(saved_staged(conversation, layers))
            .reject { |item| item.edit.kind == :stale && kept.include?(item.edit.id) }
    end

    # [the batch to apply, why, its [freed, tail] when payoff measured it]
    # at +moment+ under +rule+.
    def choose(conversation, layers, staged, rule, moment, top_bucket)
      return [staged, :turn_end] if moment == :turn_end

      case rule
      when :next_request
        batch = staged.reject(&:change?)
        [batch, batch.empty? ? nil : :next_request]
      when :payoff
        return [staged, :top_bucket] if top_bucket

        measured = measure(conversation, layers, staged)
        freed, tail = measured
        freed >= tail ? [staged, :payoff, measured] : [[], :held, measured]
      else
        [[], nil]
      end
    end

    # The chars +batch+ frees from what +conversation+ sends now, and the
    # chars sent after it from its earliest entry on (the tail the server
    # reads again).
    # @return [Array(Integer, Integer)]
    def measure(conversation, layers, batch, now = "now")
      return [0, 0] if batch.empty?

      view = LLMContextView.new(strategy: layers)
      trial = conversation.dup
      batch.each do |item|
        trial[item.index] = trial[item.index].dup if trial[item.index].equal?(conversation[item.index])
        LLMContextEdit.store(trial[item.index], item.edit.with(applied_at: now))
      end
      after = view.messages(trial)
      first = batch.map(&:index).min
      [sent_chars(view.messages(conversation)) - sent_chars(after), sent_chars(after[first..])]
    end

    def sent_chars(entries) = LLMContextView.chars(entries)

    # What applying +edits+ ([entry index, LLMContextEdit] pairs) would
    # free under +layers+, and the tail after them, in chars (#measure).
    # @return [Array(Integer, Integer)]
    def weigh(conversation, layers:, edits:)
      measure(conversation, Array(layers), edits.map { |index, edit| Staged.new(index: index, edit: edit, change: false) })
    end

    # Edits saved unapplied on the entries, of +layers+ (forget saves its
    # edits so, LLMContextForget).
    def saved_staged(conversation, layers)
      conversation.each_with_index.flat_map do |entry, index|
        next [] unless entry[:role].to_s == "tool_response"

        LLMContextEdit.on(entry).values.reject(&:applied?).select { |edit| layers.include?(edit.kind) }
                      .map { |edit| Staged.new(index: index, edit: edit, change: false) }
      end
    end

    private_class_method :stage, :choose, :measure, :saved_staged, :log_applied, :emit_applied
  end
end
