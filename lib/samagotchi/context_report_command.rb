# frozen_string_literal: true

require "time"

require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "config"
require_relative "context_candidates_log"
require_relative "session"

module Samagotchi
  # `chi context report [--days N]`: counts from context_candidates.jsonl
  # (ContextCandidatesLog), no prompts: what was proposed and mentioned,
  # the judge's asks, what it would attach at each threshold, and how that
  # agrees with what the user did with the same candidates (attached,
  # mentioned, or declined); on mode's attaches (and how many the user
  # removed later), cards and /context attach|decline. This machine only
  # (SessionAccess::Contract).
  class ContextReportCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi context report [--days N]
        Counts from the candidate judge's log (context_candidates.jsonl): candidates
        proposed, mentioned, attached or declined by you, withdrawn; the judge's asks
        (judged, or no task stated yet); how many candidates it would attach at each
        threshold (each candidate's latest judged ask); and how that agrees with what
        you did with them. On mode: the judge's attaches, how many you removed later,
        its cards, and /context attach|decline. Default: the last 14 days.
    TEXT

    DEFAULT_DAYS = 14
    THRESHOLDS = [0.5, 0.6, 0.7, 0.8, 0.9].freeze
    FLAGS = CLI::Flags.new(args: false) { |flags| flags.value "--days" }.freeze

    # @param argv [Array<String>] the arguments after "context report"
    # @param state_dir [String, nil] the sessions folder (a spec seam)
    # @param now [Time] the report's clock (a spec seam)
    def initialize(argv, stdout: $stdout, stderr: $stderr, state_dir: nil, now: Time.now)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
      @now = now
    end

    def run
      parsed = parse_flags(FLAGS, @argv)
      return parsed if parsed.is_a?(Integer)

      days = parsed.options[:days]
      return usage_error("--days takes a positive whole number") if days && !days.to_s.match?(/\A[1-9]\d*\z/)

      report(days ? Integer(days, 10) : DEFAULT_DAYS)
      CLI::Exit::OK
    end

    # The counts, as a Hash (the report prints these).
    def self.counts(records, threshold:, offer_threshold:)
      by_candidate = records.group_by { |line| [line["session_id"], line["name"]] }
      kinds = ->(kind) { records.count { |line| line["kind"] == kind } }
      judged = records.select { |line| line["kind"] == "judged" }
      latest = by_candidate.transform_values do |lines|
        lines.reverse.find { |line| line["kind"] == "judged" && line["stated"] == true }&.fetch("p", nil)
      end.compact
      choices = by_candidate.transform_values { |lines| user_choice(lines) }.compact
      {
        sessions: records.map { |line| line["session_id"] }.uniq.size,
        proposed: kinds.call("proposed"), mentioned: kinds.call("mentioned"), attached: kinds.call("attached"),
        declined: kinds.call("declined"), detached: kinds.call("detached"), withdrawn: kinds.call("withdrawn"),
        asks: judged.size, stated: judged.count { |line| line["stated"] == true },
        unstated: judged.count { |line| line["stated"] == false }, candidates_judged: latest.size,
        would: THRESHOLDS.to_h { |t| [t, latest.values.count { |p| p.to_f >= t }] },
        threshold: threshold, offer_threshold: offer_threshold,
        agreement: agreement(latest, choices, threshold)
      }.merge(on_mode(records, by_candidate))
    end

    # On mode's own lines: the judge's attaches, those the user removed
    # later (its false positives), the cards, and /context attach|decline.
    def self.on_mode(records, by_candidate)
      by_command = ->(kind) { records.count { |line| line["kind"] == kind && line["by"] == "command" } }
      removed = by_candidate.values.count do |lines|
        index = lines.index { |line| line["kind"] == "judge_attached" }
        index && lines.drop(index + 1).any? { |line| %w[declined detached].include?(line["kind"]) && line["by"] != "command" }
      end
      { judge_attached: records.count { |line| line["kind"] == "judge_attached" }, judge_removed: removed,
        carded: records.count { |line| line["kind"] == "carded" }, command_attached: by_command.call("attached"),
        command_declined: by_command.call("declined") }
    end

    # What the user last did with a candidate: "attached" (attached by
    # them, or mentioned) or "declined"; nil when neither.
    def self.user_choice(lines)
      last = lines.reverse.find { |line| %w[mentioned attached declined detached].include?(line["kind"]) }
      return nil if last.nil? || last["kind"] == "detached"

      last["kind"] == "declined" ? "declined" : "attached"
    end

    # The judged candidates the user also chose for: agree (would attach
    # what they attached, or not what they declined), attached what they
    # declined, missed what they attached.
    def self.agreement(latest, choices, threshold)
      both = latest.keys & choices.keys
      result = { candidates: both.size, agree: 0, wrong_attach: 0, missed: 0 }
      both.each do |key|
        would = latest[key].to_f >= threshold
        if would == (choices[key] == "attached") then result[:agree] += 1
        elsif would then result[:wrong_attach] += 1
        else result[:missed] += 1
        end
      end
      result
    end

    private

    def command_name = "chi context report"

    def report(days)
      cutoff = @now - (days * 86_400)
      records = ContextCandidatesLog.log_for(@state_dir).records.select { |line| after?(line["at"], cutoff) }
      counts = self.class.counts(records, threshold: Config.get("context.candidates.threshold").to_f,
                                          offer_threshold: Config.get("context.candidates.offer_threshold").to_f)
      print_counts(counts, days)
    end

    def after?(iso, cutoff)
      Time.iso8601(iso.to_s) >= cutoff
    rescue ArgumentError
      false
    end

    def print_counts(counts, days)
      @stdout.puts("chi context report: the last #{days} day#{"s" unless days == 1}, #{counts[:sessions]} session" \
                   "#{"s" unless counts[:sessions] == 1} (mode #{Config.get("context.candidates.mode")})")
      @stdout.puts("  candidates: proposed #{counts[:proposed]} · mentioned #{counts[:mentioned]} · " \
                   "attached by you #{counts[:attached]} · declined #{counts[:declined]} · " \
                   "detached #{counts[:detached]} · withdrawn #{counts[:withdrawn]}")
      @stdout.puts("  on mode: judge attached #{counts[:judge_attached]} · you removed #{counts[:judge_removed]} of them " \
                   "later · carded #{counts[:carded]} · /context attach #{counts[:command_attached]} · " \
                   "/context decline #{counts[:command_declined]} (the card's buttons)")
      @stdout.puts("  judge: #{counts[:asks]} asks · judged #{counts[:stated]} · no task yet #{counts[:unstated]} · " \
                   "#{counts[:candidates_judged]} candidates judged")
      return if counts[:candidates_judged].zero?

      @stdout.puts("  would attach (each candidate's latest judged ask):")
      counts[:would].each do |threshold, count|
        mark = { counts[:threshold] => "  threshold", counts[:offer_threshold] => "  offer_threshold" }[threshold]
        @stdout.puts(format("    ≥ %.1f  %d%s", threshold, count, mark))
      end
      agreement = counts[:agreement]
      @stdout.puts("  against your own choice (#{agreement[:candidates]} judged candidates you attached, " \
                   "mentioned or declined), at #{counts[:threshold]}: agree #{agreement[:agree]} · " \
                   "would attach what you declined #{agreement[:wrong_attach]} · " \
                   "would miss what you attached #{agreement[:missed]}")
    end
  end
end
