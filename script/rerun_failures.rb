#!/usr/bin/env ruby
# frozen_string_literal: true

# CI's "passed on rerun" check: after a failed parallel_rspec, rerun only the
# examples that failed, with plain rspec, and say in the job summary whether
# they passed this time (a flake) or failed again.
#
#   ruby script/rerun_failures.rb --job NAME [--log PATH]
#
# The ids are the rerun lines parallel_tests' FailuresLogger appends to
# tmp/parallel_failures.log (.rspec_parallel): `rspec ./spec/x_spec.rb:12 # …`,
# colour stripped. The summary goes to $GITHUB_STEP_SUMMARY (stdout without
# one): "Flaky: passed on rerun" or "Failed twice", with the ids, the Ruby
# version and the job. It always exits 1: a flake still fails the job. See
# docs/testing.md (Flakes).

require "optparse"

class RerunFailures
  DEFAULT_LOG = "tmp/parallel_failures.log"
  # More failures than this is a real breakage, not a flake: no rerun.
  MAX_RERUN = 20

  Failure = Data.define(:id, :description)

  # The FailuresLogger's lines, colorized when colour is on.
  def self.parse(text)
    text.gsub(/\e\[[\d;]*m/, "").each_line.filter_map do |line|
      next unless (match = line.match(/\Arspec (\S+)(?: # (.*))?\s*\z/))

      Failure.new(id: match[1], description: match[2].to_s.strip)
    end.uniq(&:id)
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
  options = { log: RerunFailures::DEFAULT_LOG, job: ENV.fetch("GITHUB_JOB", "local") }
  OptionParser.new do |opts|
    opts.banner = "usage: ruby script/rerun_failures.rb --job NAME [--log PATH]"
    opts.on("--job NAME", "the job's name in the summary") { |v| options[:job] = v }
    opts.on("--log PATH", "the failures log (#{RerunFailures::DEFAULT_LOG})") { |v| options[:log] = v }
  end.parse!

  summary_path = ENV.fetch("GITHUB_STEP_SUMMARY", "")
  summary = lambda do |text|
    puts text
    File.write(summary_path, text, mode: "a") unless summary_path.empty?
  end
  runner = lambda do |ids|
    puts "Rerunning #{ids.size} failed example(s): #{ids.join(" ")}"
    system("bundle", "exec", "rspec", *ids)
  end
  exit RerunFailures.new(log: options[:log], job: options[:job], runner:, summary:).run
end
