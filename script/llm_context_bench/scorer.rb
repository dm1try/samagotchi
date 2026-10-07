# frozen_string_literal: true

require_relative "profile"
require_relative "strategies"

module LLMContextBench
  # One plan's numbers (tokens are chars/4):
  # - outputs, tool_tokens: the tool outputs in context at the case's
  #   request, and their tokens; prompt_tokens: that request's prompt under
  #   none;
  # - forgotten: the outputs the plan edits; freed: what the prompt loses
  #   by it, as chi's LLMContextView sends it (the stubs counted);
  # - wrong_strict / wrong_loose: edited outputs a later step needs, from
  #   the step the edit reaches through the end of the case's next turn:
  #   it re-reads the file or re-runs the command (strict), or also
  #   mentions its path or an identifier the output brought in (loose).
  #   need_strict / need_loose: the same over every output in context (the
  #   base rate, what a random pick scores);
  # - one_step_outputs: edited outputs the very step the edit reaches
  #   re-reads (a read of the same file) or re-runs; offline that step is
  #   the session's own, made without the stub, so it is the floor, not
  #   the stub's effect;
  # - re_prefilled: what the server prefills again because an edit broke its
  #   prompt cache: at each request an edit first reaches, the prompt from
  #   the earliest entry it changes to the end of what the previous request
  #   (and its answer) left cached.
  Result = Data.define(:strategy, :model, :policy, :case_name, :how, :outputs, :tool_tokens, :prompt_tokens,
                       :forgotten, :invalid_ids, :freed, :wrong_strict, :wrong_loose, :need_strict, :need_loose,
                       :one_step_outputs, :re_prefilled)

  # Scores a Plan on its case's replay, the edits rendered through chi's own
  # LLMContextView (as LLMContextEdit records saved on copies of the
  # entries, the way chi saves them), so the tokens are what chi would send.
  class Scorer
    BY = "llm_context_bench"

    # @param plan [Plan]
    # @return [Result]
    def score(plan)
      kase = plan.kase
      replay = kase.replay
      outputs = kase.outputs
      by_id = outputs.to_h { |output| [output.id, output] }
      edits = plan.edits.select { |edit| by_id.key?(edit.output_id) && edit.applies_at <= kase.at }
      horizon = Later.new(replay, replay.prompt_end(kase.at)...replay.turns[kase.turn + 1].end)
      edited = edits.map { |edit| by_id[edit.output_id] }
      wrong_strict, wrong_loose = needs(replay, kase, edits, by_id)

      Result.new(strategy: plan.strategy, model: plan.model, policy: plan.policy, case_name: kase.name, how: plan.how,
                 outputs: outputs.size, tool_tokens: outputs.sum(&:tokens), prompt_tokens: prompt_tokens(replay, kase.at, []),
                 forgotten: edited.size, invalid_ids: plan.invalid_ids,
                 freed: prompt_tokens(replay, kase.at, []) - prompt_tokens(replay, kase.at, edits),
                 wrong_strict: wrong_strict, wrong_loose: wrong_loose,
                 need_strict: outputs.count { |output| horizon.reread?(output) },
                 need_loose: outputs.count { |output| horizon.loose?(output) },
                 one_step_outputs: one_step(replay, edits, by_id), re_prefilled: re_prefilled(replay, edits, by_id))
    end

    # Request +request+'s prompt as chi's view sends it with +edits+ applied
    # by then.
    # @return [Array<Hash>] the entries
    def view(replay, request, edits)
      conversation = replay.messages[0...replay.prompt_end(request)]
      applied = edits.select { |edit| edit.applies_at <= request }
      return conversation if applied.empty?

      entries = replay.outputs.to_h { |output| [output.id, output.entry_index] }
      copies = {}
      applied.each do |edit|
        index = entries.fetch(edit.output_id)
        copies[index] ||= conversation[index].dup
        Samagotchi::LLMContextEdit.store(copies[index], record(edit))
      end
      conversation = conversation.each_with_index.map { |entry, index| copies[index] || entry }
      Samagotchi::LLMContextView.new(strategy: applied.map(&:kind).uniq).messages(conversation)
    end

    private

    def record(edit)
      stamp = "request #{edit.applies_at}"
      Samagotchi::LLMContextEdit.new(id: edit.output_id, kind: edit.kind, note: edit.note, by: BY, staged_at: stamp,
                                     applied_at: stamp)
    end

    def prompt_tokens(replay, request, edits)
      view(replay, request, edits).sum { |entry| replay.entry_tokens(entry) }
    end

    def needs(replay, kase, edits, by_id)
      strict = 0
      loose = 0
      end_of_case = replay.turns[kase.turn + 1].end
      edits.group_by(&:applies_at).each do |request, group|
        later = Later.new(replay, replay.prompt_end(request)...end_of_case)
        group.each do |edit|
          output = by_id[edit.output_id]
          strict += 1 if later.reread?(output)
          loose += 1 if later.loose?(output)
        end
      end
      [strict, loose]
    end

    # The spike's one-step check (part_b.py retouch, strict): the step's
    # call re-runs the output's command, or reads a file the output read.
    def one_step(replay, edits, by_id)
      edits.count do |edit|
        output = by_id[edit.output_id]
        replay.calls[edit.applies_at].any? do |call|
          (output.target.command && output.target.command == call.target.command) ||
            (output.read? && output.target.keys.intersect?(call.target.keys))
        end
      end
    end

    def re_prefilled(replay, edits, by_id)
      edits.group_by(&:applies_at).sum do |request, group|
        next 0.0 if request.zero?

        first = group.map { |edit| by_id[edit.output_id].entry_index }.min
        cached_end = replay.prompt_end(request - 1) + 1
        view(replay, request, edits)[first...cached_end].to_a.sum { |entry| replay.entry_tokens(entry) }
      end
    end
  end
end
