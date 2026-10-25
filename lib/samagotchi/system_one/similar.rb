# frozen_string_literal: true

module Samagotchi
  module SystemOne
    # The few-shot examples an ask carries beside its own facts: the earlier
    # asks the user actually answered, the most alike first — this rule in
    # this repository, then this rule, then whatever shares the most words
    # with this call. No embeddings: a word overlap, with the newer ask first
    # when two tie, so the same log always gives the same five
    # (docs/guardrails.md, "System 1").
    module Similar
      # How many examples the state can carry.
      MAX = 5
      # A "token" of a call, for the overlap: a word, lower-cased.
      TOKEN = /[a-z0-9_]+/

      module_function

      # @param entries [Array<Hash>] SystemOne::Log#entries, oldest first —
      #   the same read the record gate uses
      # @param rule [String, nil] the rule asking now
      # @param repo_name [String, nil] the repository this ask is in
      # @param call_text [String] the call to approve (ApprovalQuestion.call_text)
      # @return [Array<Hash>] at most MAX examples, most alike first; [] when
      #   the log has nothing labelled to offer
      def select(entries:, rule:, repo_name:, call_text:)
        words = tokens(call_text)
        ranked = Array(entries).each_with_index.select { |entry, _index| labelled?(entry) }
        ranked = ranked.sort_by { |entry, index| [tier(entry, rule, repo_name), -overlap(entry["call"], words), -index] }
        ranked.first(MAX).map { |entry, _index| example(entry) }
      end

      # A judgment teaches something only when the user answered it: no label
      # or a `none` says nothing, and a line with no rule cannot be matched.
      def labelled?(entry)
        answer = entry["answer"].to_s
        !answer.empty? && answer != "none" && !entry["rule"].to_s.strip.empty?
      end

      # 0: this rule in this repository. 1: this rule anywhere. 2: any other
      # ask the user answered.
      def tier(entry, rule, repo_name)
        same_rule = entry["rule"].to_s == rule.to_s
        return 0 if same_rule && !repo_name.to_s.strip.empty? && entry["repo_name"].to_s == repo_name.to_s
        return 1 if same_rule

        2
      end

      # How many of this call's words the logged call shares.
      def overlap(call, words)
        return 0 if words.empty?

        (tokens(call) & words).size
      end

      def tokens(text)
        text.to_s.downcase.scan(TOKEN).uniq
      end

      # What the judge is shown about an ask: how it was judged and what the
      # user did, as the log holds it.
      def example(entry)
        { "rule" => entry["rule"].to_s, "repo" => entry["repo_name"], "call" => entry["call"],
          "answer" => entry["answer"].to_s }.compact
      end
    end
  end
end
