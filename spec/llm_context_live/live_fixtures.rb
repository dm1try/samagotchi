# frozen_string_literal: true

require "json"
require_relative "../../script/llm_context_live/runner"
require_relative "../../script/llm_context_live/report"

# Fakes for the llm_context live harness specs (script/llm_context_live):
# synthetic data only, never a real session.
module LiveFixtures
  # A Shell whose commands answer from a list of [matcher, Ran or block]
  # (the first match wins; a block gets the argv and options), keeping
  # every call. Unmatched commands run for real (git on a temp repo).
  class FakeShell
    attr_reader :calls

    def initialize(rules = [])
      @rules = rules
      @calls = []
      @real = LLMContextLive::Shell.new
    end

    def on(matcher, ran = nil, &block)
      @rules << [matcher, ran || block]
      self
    end

    def run(argv, **options)
      @calls << argv
      rule = @rules.find { |matcher, _| matcher.is_a?(Proc) ? matcher.call(argv) : argv.join(" ").match?(matcher) }
      return @real.run(argv, **options) unless rule

      answer = rule.last
      answer = answer.shift if answer.is_a?(Array)
      answer.respond_to?(:call) ? answer.call(argv, options) : answer
    end
  end

  module_function

  def ran(out = "", status: 0, err: "") = LLMContextLive::Ran.new(status: status, out: out, err: err)

  def json(**fields) = ran("#{JSON.generate(fields)}\n")

  def task(id: "T1", turns: ["Find it in {repo}.", "Fix it."], fix_files: %w[lib/cart.rb spec/cart_spec.rb])
    LLMContextLive::Task.new(id: id, fix: "abc1234", size: "S", turns: turns, hidden: %w[spec/cart_spec.rb],
                             regression: %w[spec/cart_spec.rb], fix_files: fix_files)
  end

  # A results/<run>.json as the Runner writes it.
  def result(task:, arm:, sample:, pass: true, **metrics)
    { run: "#{task}-#{arm}-s#{sample}", task: task, arm: arm, sample: sample,
      outcome: { wall_seconds: 60, turns: [{ status: "answered", limit: false }] },
      metrics: { steps: 10, re_reads: 2, files_read: 4, files_changed_outside: 0, cost: 0.1 }.merge(metrics),
      grade: { pass: pass } }
  end
end
