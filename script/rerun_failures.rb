#!/usr/bin/env ruby
# frozen_string_literal: true

# CI's "passed on rerun" check: after a failed parallel_rspec, rerun only the
# examples that failed, with plain rspec, and say in the job summary whether
# they passed this time (a flake) or failed again.
#
#   ruby script/rerun_failures.rb --job NAME [--log PATH] [--rspec CMD]
#
# The ids are the rerun lines parallel_tests' FailuresLogger appends to
# tmp/parallel_failures.log (.rspec_parallel): `rspec ./spec/x_spec.rb:12 # …`,
# colour stripped; or rspec's `--format json` report (its failed examples'
# ids and full descriptions; rake bundles:specs' tmp/bundle_failures.json). --rspec is the rerun's command (default
# `bundle exec rspec`; the bundles job reruns on the bundle test kit alone). The summary goes to $GITHUB_STEP_SUMMARY (stdout without
# one): "Flaky: passed on rerun" or "Failed twice", with the ids, the Ruby
# version and the job. It always exits 1: a flake still fails the job. See
# docs/testing.md (Flakes).

require "json"
require "optparse"
require "shellwords"

class RerunFailures
  DEFAULT_LOG = "tmp/parallel_failures.log"
  # More failures than this is a real breakage, not a flake: no rerun.
  MAX_RERUN = 20

  Failure = Data.define(:id, :description)

  # The FailuresLogger's lines, colorized when colour is on.
  RERUN_LINE = /\Arspec (\S+)(?: # (.*))?\s*\z/
  def self.parse(text)
    return parse_json(text) if text.lstrip.start_with?("{")

    text.gsub(/\e\[[\d;]*m/, "").each_line.filter_map do |line|
      next unless (match = line.match(RERUN_LINE))

      Failure.new(id: match[1], description: match[2].to_s.strip)
    end.uniq(&:id)
  end

  # rspec's --format json: each failed example's id (`./x_spec.rb[1:2]`,
  # which reruns it alone) and full description, as the FailuresLogger's
  # rerun lines have it. A report cut short (a crash mid-write) has none.
  def self.parse_json(text)
    examples = JSON.parse(text).fetch("examples", [])
    examples.filter_map do |example|
      next unless example["status"] == "failed"

      Failure.new(id: example["id"].to_s, description: example["full_description"].to_s.strip)
    end.uniq(&:id)
  rescue JSON::ParserError
    []
  end

  # runner: takes the ids, returns true when they all pass.
  def initialize(log:, job:, runner:, summary:, ruby: RUBY_VERSION)
    @log = log
    @job = job
    @runner = runner
    @summary = summary
    @ruby = ruby
  end

  def run
    failures = File.exist?(@log) ? self.class.parse(File.read(@log)) : []
    @summary.call(report(failures, verdict(failures)))
    1
  end

  private

  def verdict(failures)
    return :none if failures.empty?
    return :too_many if failures.size > MAX_RERUN

    @runner.call(failures.map(&:id)) ? :flaky : :failed_twice
  end

  def report(failures, verdict)
    lines = [heading(verdict, failures.size), "", "Job: #{@job} · Ruby #{@ruby}", ""]
    return lines.join("\n") + "\n" if failures.empty?

    lines << "| Example | Description |" << "|---|---|"
    failures.each { |f| lines << "| `#{cell(f.id)}` | #{cell(f.description)} |" }
    lines.join("\n") + "\n"
  end

  def heading(verdict, count)
    case verdict
    when :flaky then "### Flaky: passed on rerun"
    when :failed_twice then "### Failed twice"
    when :too_many then "### Failed: #{count} examples, not rerun (more than #{MAX_RERUN})"
    else "### Failed, nothing to rerun (no example ids in #{@log}: a load error or a crash outside an example?)"
    end
  end

  def cell(text) = text.gsub("|", "\\|")
end

if $PROGRAM_NAME == __FILE__
  options = { log: RerunFailures::DEFAULT_LOG, job: ENV.fetch("GITHUB_JOB", "local"), rspec: "bundle exec rspec" }
  OptionParser.new do |opts|
    opts.banner = "usage: ruby script/rerun_failures.rb --job NAME [--log PATH] [--rspec CMD]"
    opts.on("--job NAME", "the job's name in the summary") { |v| options[:job] = v }
    opts.on("--log PATH", "the failures log (#{RerunFailures::DEFAULT_LOG})") { |v| options[:log] = v }
    opts.on("--rspec CMD", "the rerun's command (bundle exec rspec)") { |v| options[:rspec] = v }
  end.parse!

  summary_path = ENV.fetch("GITHUB_STEP_SUMMARY", "")
  summary = lambda do |text|
    puts text
    File.write(summary_path, text, mode: "a") unless summary_path.empty?
  end
  runner = lambda do |ids|
    puts "Rerunning #{ids.size} failed example(s): #{ids.join(" ")}"
    system(*Shellwords.split(options[:rspec]), *ids)
  end
  exit RerunFailures.new(log: options[:log], job: options[:job], runner:, summary:).run
end
