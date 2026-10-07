# frozen_string_literal: true

require_relative "scorer"

module LLMContextBench
  # The benchmark's text and JSON output: the profile (none), then one row
  # per strategy × model × policy summed over its cases.
  class Report
    STRATEGY_ORDER = %w[none forget_all stale forget_outputs picks].freeze
    SUMMED = %i[outputs tool_tokens prompt_tokens forgotten invalid_ids freed wrong_strict wrong_loose need_strict
                need_loose one_step_outputs re_prefilled].freeze

    # One row: a strategy × model × policy, its results summed.
    Row = Data.define(:strategy, :model, :policy, :cases, :how, :sums)

    attr_reader :results, :profile, :skipped

    # @param results [Array<Result>]
    # @param profile [Profile, nil]
    # @param skipped [Hash{String => String}] strategy => why it didn't run
    def initialize(results:, profile: nil, skipped: {}, sessions: 0, source: nil)
      @results = results
      @profile = profile
      @skipped = skipped
      @sessions = sessions
      @source = source
    end

    def rows
      grouped = results.group_by { |result| [result.strategy, result.model, result.policy] }
      grouped.map do |(strategy, model, policy), group|
        sums = SUMMED.to_h { |key| [key, group.sum(&key)] }
        Row.new(strategy: strategy, model: model, policy: policy, cases: group.size,
                how: group.filter_map(&:how).tally, sums: sums)
      end.sort_by { |row| [STRATEGY_ORDER.index(row.strategy) || 99, row.model, row.policy] }
    end

    def to_h
      { source: @source, sessions: @sessions, profile: profile&.to_h, skipped: skipped,
        rows: rows.map { |row| row.to_h.merge(sums: row.sums) }, cases: results.map(&:to_h) }
    end

    def text(per_case: false)
      lines = ["llm_context bench: #{@sessions} sessions, #{results.map(&:case_name).uniq.size} cases " \
               "from #{@source} (tokens are chars/4)", ""]
      lines.concat(profile_lines) if profile
      lines.concat(row_lines)
      skipped.each { |name, why| lines << "  #{name}: skipped, #{why}" }
      lines.concat(case_lines) if per_case
      "#{lines.join("\n")}\n"
    end

    private

    def k(tokens) = format("%.1fk", tokens / 1000.0)

    def pct(part, whole) = whole.zero? ? "-" : format("%.0f%%", 100.0 * part / whole)

    def profile_lines
      p = profile
      shares = Profile::RESENT.map { |key| "#{key.tr("_", " ")} #{k(p.categories[key])} (#{pct(p.categories[key], p.resent_total)})" }
      tools = p.by_tool.sort_by { |_name, row| -row[:tokens] }.first(5).map do |name, row|
        "#{name} #{k(row[:tokens])} (#{pct(row[:tokens], p.categories["tool_output"])}, n=#{row[:count]}, " \
          "mean #{(row[:tokens] / row[:count]).round})"
      end
      sizes = p.size_summary
      turns = p.turn_summary
      refs = p.references
      counts = p.reference_counts
      reads = p.reads
      [
        "Profile (none, every session)",
        "  resent #{k(p.resent_total)}: #{shares.join(", ")}",
        "  thinking (stored, not resent) #{k(p.categories["thinking"])}",
        "  tool outputs by tool: #{tools.join("; ")}",
        "  output sizes: n=#{sizes[:count]} p50 #{sizes[:p50].round} p90 #{sizes[:p90].round} p99 #{sizes[:p99].round} " \
        "max #{sizes[:max].round}; >= #{Profile::BIG}: #{pct(sizes[:big_count_share], 1)} of outputs, " \
        "#{pct(sizes[:big_token_share], 1)} of tokens",
        "  turns: n=#{turns[:count]} p50 #{k(turns[:p50] || 0)} p90 #{k(turns[:p90] || 0)} max #{k(turns[:max] || 0)}; " \
        "heaviest 10% hold #{pct(turns[:top_tenth_share] || 0, 1)} of turn tokens, " \
        "#{pct(turns[:top_tenth_tool_share] || 0, 1)} of it tool output",
        "  later turns refer to (#{counts["all"]} outputs, #{k(refs["all"])}): " +
          Profile::REFERENCES.map { |key| "#{key.tr("_", " ")} #{pct(refs[key], refs["all"])} (#{pct(counts[key], counts["all"])} of outputs)" }.join(", "),
        "  reads: #{reads[:reads]} over #{reads[:files]} files; #{reads[:files_read_twice]} files read twice or more; " \
        "#{reads[:repeat_reads]} repeat reads (#{pct(reads[:repeat_reads], reads[:reads])})",
        ""
      ]
    end

    HEADER = ["strategy", "model", "policy", "cases", "forgot/outputs", "freed/tool", "wrong strict (base)",
              "wrong loose (base)", "1-step", "re-prefilled", "notes"].freeze

    def row_lines
      table = rows.map do |row|
        s = row.sums
        notes = []
        notes << row.how.map { |how, n| "#{n} #{how}" }.join(", ") unless row.how.empty?
        notes << "#{s[:invalid_ids]} invalid ids" if s[:invalid_ids].positive?
        [row.strategy, row.model, row.policy, row.cases.to_s, "#{s[:forgotten]}/#{s[:outputs]}",
         "#{k(s[:freed])}/#{k(s[:tool_tokens])} #{pct(s[:freed], s[:tool_tokens])}",
         "#{s[:wrong_strict]} #{pct(s[:wrong_strict], s[:forgotten])} (#{pct(s[:need_strict], s[:outputs])})",
         "#{s[:wrong_loose]} #{pct(s[:wrong_loose], s[:forgotten])} (#{pct(s[:need_loose], s[:outputs])})",
         s[:one_step_outputs].to_s, k(s[:re_prefilled]), notes.join("; ")]
      end
      ["Strategies (each case scored at its next turn's first request)"] + columns([HEADER] + table) + [""]
    end

    def case_lines
      header = %w[strategy model policy case forgot/outputs freed wrong-strict wrong-loose 1-step re-prefilled]
      table = results.map do |r|
        [r.strategy, r.model, r.policy, r.case_name, "#{r.forgotten}/#{r.outputs}", k(r.freed), r.wrong_strict.to_s,
         r.wrong_loose.to_s, r.one_step_outputs.to_s, k(r.re_prefilled)]
      end
      ["Cases"] + columns([header] + table) + [""]
    end

    def columns(table)
      widths = table.transpose.map { |column| column.map(&:length).max }
      table.map { |row| "  #{row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip}" }
    end
  end
end
