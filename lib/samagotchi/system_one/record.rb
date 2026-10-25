# frozen_string_literal: true

module Samagotchi
  module SystemOne
    # One rule's record: what System 1 has judged for it and what the user
    # did about those asks. Built from `SystemOne::Log#entries` (judgments
    # joined with their last label), filtered to one rule. The gate before
    # System 1 answers for the user: enough clean allows at the threshold,
    # and no false allow among the rule's last 20 labelled asks
    # (docs/guardrails.md, "System 1").
    #
    # An ask with no label, no probability, or a `none` label counts for
    # neither side: only a judgment the user actually answered teaches
    # anything.
    class Record
      # The labels that mean the user let the call through.
      ALLOW_LABELS = %w[allow_once allow_wide].freeze
      # A judgment at the threshold that the user did not allow: System 1
      # was wrong, and the rule's record is not clean.
      FALSE_ALLOW_LABELS = %w[deny should_have_asked].freeze
      # How many of the rule's labelled asks the false-allow check looks at.
      WINDOW = 20

      attr_reader :rule, :entries

      # @param entries [Array<Hash>] SystemOne::Log#entries, oldest first
      # @param rule [String] the rule the record is for
      def initialize(entries, rule:)
        @rule = rule.to_s
        @entries = Array(entries).select { |entry| entry["rule"].to_s == @rule }
      end

      # @param threshold [Float] the probability an auto-allow needs
      # @param min_record [Integer] how many clean allows the rule needs
      # @return [Boolean] whether System 1 may answer this rule for the user
      def qualifies?(threshold:, min_record:)
        clean = high(threshold).count { |entry| ALLOW_LABELS.include?(entry["answer"].to_s) }
        return false if clean < min_record.to_i

        !false_allow?(labeled.last(WINDOW), threshold)
      end

      # The counts a `/guardrails` listing shows: how many asks the rule has,
      # how many were answered, and how each was answered.
      # @return [Hash]
      def summary
        labeled_entries = labeled
        {
          rule: rule,
          asks: entries.size,
          labelled: labeled_entries.size,
          allow_once: count("allow_once"),
          allow_wide: count("allow_wide"),
          deny: count("deny"),
          should_have_asked: count("should_have_asked"),
          none: count("none"),
          no_label: entries.size - labeled_entries.size,
          no_p: entries.count { |entry| entry["p"].nil? }
        }
      end

      private

      # The asks of the rule the user answered.
      def labeled
        entries.reject { |entry| entry["answer"].nil? }
      end

      # The asks judged at or above +threshold+.
      def high(threshold)
        entries.select { |entry| entry["p"] && entry["p"].to_f >= threshold.to_f }
      end

      def false_allow?(list, threshold)
        list.any? { |entry| entry["p"] && entry["p"].to_f >= threshold.to_f && FALSE_ALLOW_LABELS.include?(entry["answer"].to_s) }
      end

      def count(label)
        entries.count { |entry| entry["answer"].to_s == label }
      end
    end
  end
end
