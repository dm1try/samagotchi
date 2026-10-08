# frozen_string_literal: true

require_relative "llm_context_stale"
require_relative "tool_activity"
require_relative "token_usage"

module Samagotchi
  # The ✂ row a turn gets for a batch of LLM context edits the apply rule
  # let through (LLMContextApply::Outcome#applied?): the :llm_context_edited
  # event both loops emit (KernelLoop#apply_llm_context!, its +emit+), at a
  # request (+moment+ :request; a forget_outputs call's batch too) or at the
  # end of a turn (:turn_end); never for the warm-up, a held or a staged
  # batch, or a restore (the forget_outputs row says it). The web and the
  # TUI print +text+ as it is; the web's hover lists +groups+.
  #
  # {type: :llm_context_edited, moment:, why:, freed_tokens:, tail_tokens:,
  #  staged:, text: "✂ forgot 2 outputs, stubbed 1 stale read · frees ~4.1k
  #  tokens (paid off)", groups: [{kind: "stale", items: [{id, tool, title,
  #  note}]}, {kind: "forget", note:, by:, items: [{id, tool, title, kept}]}]}
  #
  # The stale items share one group, each with its own note; a forget group
  # is one forget_outputs call's (the view's key: note, by and staged_at),
  # its note once. Tokens are chars/4, so "~".
  module LLMContextNotice
    TYPE = :llm_context_edited
    # A forget's note on the row, at most (the stub keeps all of it).
    NOTE_MAX = 300
    WHY = { payoff: "paid off", top_bucket: "the context is nearly full", turn_end: "at turn end" }.freeze

    module_function

    # @param outcome [LLMContextApply::Outcome] an applied one
    # @param moment [Symbol] :request or :turn_end
    # @return [Hash] the event
    def event(conversation, outcome, moment:, cwd: Dir.pwd)
      calls = LLMContextStale.paired_runs(conversation).to_h { |run| [run.ref.id, run.call] }
      groups = groups(outcome.applied, calls, cwd)
      freed = tokens(outcome.freed_chars)
      { type: TYPE, moment: moment.to_s, why: outcome.why.to_s, freed_tokens: freed,
        tail_tokens: tokens(outcome.tail_chars), staged: outcome.staged,
        text: text(groups, freed, outcome.why, outcome.staged), groups: groups }
    end

    def groups(edits, calls, cwd)
      stale = edits.select { |edit| edit.kind == :stale }
      forgets = edits.select { |edit| edit.kind == :forget }.group_by { |edit| [edit.note, edit.by, edit.staged_at] }
      groups = []
      unless stale.empty?
        groups << { kind: "stale", items: stale.map { |edit| item(edit, calls, cwd).merge(note: edit.note) } }
      end
      forgets.each do |(note, by, _), group|
        items = group.map do |edit|
          kept = edit.keep.map { |first, last| first == last ? first.to_s : "#{first}-#{last}" }
          item(edit, calls, cwd).merge(kept: kept.empty? ? nil : kept.join(", ")).compact
        end
        groups << { kind: "forget", note: cut(note.to_s), by: by, items: items }
      end
      groups
    end

    # An output's id, its tool and its row's title (ToolActivity.tool_title;
    # none when its call can't be told).
    def item(edit, calls, cwd)
      call = calls[edit.id]
      return { id: edit.id } unless call

      name = call[:name].to_s
      { id: edit.id, tool: name, title: ToolActivity.tool_title(name, call, cwd: cwd) }.compact
    end

    # "✂ forgot 2 outputs, stubbed 1 stale read · frees ~4.1k tokens (paid
    # off) · 1 more staged".
    def text(groups, freed, why, staged)
      forgot = groups.select { |group| group[:kind] == "forget" }.sum { |group| group[:items].size }
      stale = groups.select { |group| group[:kind] == "stale" }.sum { |group| group[:items].size }
      done = []
      done << "forgot #{count(forgot, "output")}" if forgot.positive?
      done << "stubbed #{count(stale, "stale read")}" if stale.positive?
      frees = freed.positive? ? "frees ~#{k(freed)}" : "frees nothing"
      frees += " (#{WHY[why]})" if WHY.key?(why)
      line = "✂ #{done.join(", ")} · #{frees}"
      staged.positive? ? "#{line} · #{staged} more staged" : line
    end

    def count(number, noun) = "#{number} #{noun}#{"s" unless number == 1}"

    def tokens(chars) = [(chars / TokenUsage::CHARS_PER_TOKEN).ceil, 0].max

    # "4.1k tokens", "640 tokens".
    def k(tokens) = tokens >= 1000 ? format("%.1fk tokens", tokens / 1000.0) : "#{tokens} tokens"

    def cut(note) = note.length > NOTE_MAX ? "#{note[0, NOTE_MAX - 1]}…" : note

    private_class_method :groups, :item, :text, :count, :tokens, :k, :cut
  end
end
