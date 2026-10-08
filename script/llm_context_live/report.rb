# frozen_string_literal: true

require "json"
require "yaml"

module LLMContextLive
  # The scoring table over a matrix root's results (results/<run>.json)
  # and manual grades (grades.yml: run id => {grade: 0|1|2, note: …}):
  # per task × arm the success count and each metric's median and spread
  # (min–max), and the gate.
  #
  # The gate (plan P6): [stale, forget] beats none on re-reads and scope,
  # with success not lower. Per task, a metric is "better" when the
  # stale_forget median is below none's whole spread, "worse" when above
  # it, else "same" (within the noise: plan "read nothing into a difference
  # within one sample's spread"). It passes when, for both re-reads and
  # scope (files read + files changed outside the fix's set), better tasks
  # outnumber worse ones, and stale_forget passed at least as many runs as
  # none.
  class Report
    METRICS = %i[steps re_reads re_reads_after_stub prompt_tokens cached_tokens reprefill_tokens cost peak_context
                 forget_calls forget_ids forget_freed stale_stubs files_read files_read_outside files_changed_outside
                 diff_lines wall_seconds].freeze
    GATE = { re_reads: ->(m) { m[:re_reads] }, scope: ->(m) { m[:files_read].to_i + m[:files_changed_outside].to_i } }.freeze
    CHALLENGER = "stale_forget"
    BASELINE = "none"

    def self.load(root)
      results = Dir.glob(File.join(root, "results", "*.json")).map { |path| JSON.parse(File.read(path), symbolize_names: true) }
      grades_path = File.join(root, "grades.yml")
      grades = File.file?(grades_path) ? YAML.safe_load_file(grades_path) || {} : {}
      new(results, grades)
    end

    def initialize(results, grades = {})
      @results = results.sort_by { |result| [result[:task], result[:arm], result[:sample]] }
      @grades = grades
    end

    def groups
      @groups ||= @results.group_by { |result| [result[:task], result[:arm]] }
    end

    def to_h
      { runs: @results.size, cost: @results.sum { |result| result.dig(:metrics, :cost).to_f }.round(4),
        groups: groups.map { |(task, arm), runs| group_h(task, arm, runs) }, gate: gate }
    end

    def text
      lines = ["#{@results.size} run(s), cost $#{format("%.2f", to_h[:cost])}", ""]
      groups.each do |(task, arm), runs|
        summary = group_h(task, arm, runs)
        lines << "#{task} #{arm}: pass #{summary[:pass]}/#{summary[:n]}, grade #{summary[:grades].join(" ").then { |g| g.empty? ? "-" : g }}" \
                 "#{" (limit #{summary[:limits]})" if summary[:limits].positive?}"
        METRICS.each do |metric|
          stat = summary[:metrics][metric]
          lines << format("  %-22s %s", metric, stat ? spread(stat) : "-")
        end
      end
      lines << "" << "gate (#{CHALLENGER} vs #{BASELINE}): #{gate[:verdict]}"
      gate[:tasks].each do |task, verdicts|
        lines << "  #{task}: #{verdicts.map { |metric, verdict| "#{metric} #{verdict}" }.join(", ")}"
      end
      lines << "  success: #{CHALLENGER} #{gate[:success][:challenger]}, #{BASELINE} #{gate[:success][:baseline]}"
      lines.join("\n")
    end

    def gate
      @gate ||= begin
        tasks = groups.keys.map(&:first).uniq.select do |task|
          groups.key?([task, CHALLENGER]) && groups.key?([task, BASELINE])
        end
        verdicts = tasks.to_h do |task|
          [task, GATE.to_h { |name, value| [name, compare(task, value)] }]
        end
        success = { challenger: passes(tasks, CHALLENGER), baseline: passes(tasks, BASELINE) }
        ok = !tasks.empty? && GATE.keys.all? do |name|
          votes = verdicts.values.map { |verdict| verdict[name] }
          votes.count("better") > votes.count("worse")
        end && success[:challenger] >= success[:baseline]
        { verdict: if tasks.empty?
                     "no task has both arms"
                   else
                     (ok ? "PASS" : "FAIL")
                   end, tasks: verdicts, success: success }
      end
    end

    private

    def group_h(task, arm, runs)
      metrics = METRICS.to_h { |metric| [metric, stat(runs.map { |run| value(run, metric) }.compact)] }
      { task: task, arm: arm, n: runs.size, pass: runs.count { |run| run.dig(:grade, :pass) },
        limits: runs.count { |run| Array(run.dig(:outcome, :turns)).any? { |turn| turn[:limit] } },
        grades: runs.filter_map { |run| @grades.dig(run[:run], "grade") }, metrics: metrics.compact }
    end

    def value(run, metric)
      metric == :wall_seconds ? run.dig(:outcome, :wall_seconds) : run.dig(:metrics, metric)
    end

    def compare(task, value)
      challenger = groups[[task, CHALLENGER]].map { |run| value.call(run[:metrics] || {}).to_f }
      baseline = groups[[task, BASELINE]].map { |run| value.call(run[:metrics] || {}).to_f }
      median = median(challenger)
      return "better" if median < baseline.min
      return "worse" if median > baseline.max

      "same"
    end

    def passes(tasks, arm) = tasks.sum { |task| groups[[task, arm]].count { |run| run.dig(:grade, :pass) } }

    def stat(values)
      return nil if values.empty?

      { median: median(values), min: values.min, max: values.max }
    end

    def median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    def spread(stat)
      return number(stat[:median]) if stat[:min] == stat[:max]

      "#{number(stat[:median])} (#{number(stat[:min])}–#{number(stat[:max])})"
    end

    def number(value)
      return format("%.3f", value) if value.is_a?(Float) && value < 10
      return "#{(value / 1000.0).round(1)}k" if value.to_f >= 10_000

      value.is_a?(Float) ? value.round(1).to_s : value.to_s
    end
  end
end
