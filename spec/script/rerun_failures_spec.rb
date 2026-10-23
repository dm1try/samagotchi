# frozen_string_literal: true

require "tmpdir"
require "yaml"
require_relative "../../script/rerun_failures"

# CI's "passed on rerun" check (script/rerun_failures.rb): the failed ids from
# parallel_tests' failures log (or rspec's failures list), rerun once, and the summary that says which.
RSpec.describe RerunFailures do
  let(:dir) { Dir.mktmpdir("rerun-failures-") }
  let(:log) { File.join(dir, "parallel_failures.log") }
  let(:summaries) { [] }
  let(:reruns) { [] }
  # The FailuresLogger's output: each process appends its own block.
  let(:colorized) do
    "\nFailed examples:\n\n" \
      "\e[31mrspec ./spec/worker_spec.rb:12\e[0m \e[36m# Worker wakes on a note | and replies\e[0m\n" \
      "\e[31mrspec ./lib/samagotchi/bundles/system/spec/hook_spec.rb[1:2:3]\e[0m \e[36m# a hook\e[0m\n" \
      "\nFailed examples:\n\n" \
      "rspec ./spec/bridge_spec.rb:40 # Bridge streams\n" \
      "rspec ./spec/worker_spec.rb:12 # Worker wakes on a note | and replies\n"
  end

  after { FileUtils.rm_rf(dir) }

  def run(passes: true)
    runner = lambda do |ids|
      reruns << ids
      passes
    end
    described_class.new(log:, job: "rspec (Ruby 3.4)", runner:, summary: summaries.method(:<<), ruby: "3.4.7").run
  end

  describe ".parse" do
    it "reads the ids and descriptions, colour stripped, duplicates dropped" do
      failures = described_class.parse(colorized)

      expect(failures.map(&:id)).to eq(
        ["./spec/worker_spec.rb:12", "./lib/samagotchi/bundles/system/spec/hook_spec.rb[1:2:3]",
         "./spec/bridge_spec.rb:40"]
      )
      expect(failures.first.description).to eq("Worker wakes on a note | and replies")
    end

    it "reads rspec's --format failures list too (rake bundles:specs), a description with colons kept whole" do
      list = "./lib/samagotchi/bundles/ruby/spec/hook_spec.rb:7:runs: then stops\n" \
             "./lib/samagotchi/bundles/ruby/spec/hook_spec.rb[1:2]:in a shared group\n"

      failures = described_class.parse(list)

      expect(failures.map(&:id)).to eq(["./lib/samagotchi/bundles/ruby/spec/hook_spec.rb:7",
                                        "./lib/samagotchi/bundles/ruby/spec/hook_spec.rb[1:2]"])
      expect(failures.first.description).to eq("runs: then stops")
    end

    it "ignores everything that isn't a rerun line" do
      expect(described_class.parse("Failed examples:\n\nrandom output\n")).to be_empty
    end
  end

  it "reruns the failed ids once and reports a flake when they pass, still exiting 1" do
    File.write(log, colorized)

    expect(run(passes: true)).to eq(1)
    expect(reruns).to eq([["./spec/worker_spec.rb:12", "./lib/samagotchi/bundles/system/spec/hook_spec.rb[1:2:3]",
                           "./spec/bridge_spec.rb:40"]])
    expect(summaries.join).to start_with("### Flaky: passed on rerun\n\nJob: rspec (Ruby 3.4) · Ruby 3.4.7\n")
    expect(summaries.join).to include("| `./spec/worker_spec.rb:12` | Worker wakes on a note \\| and replies |")
  end

  it "reports Failed twice when the rerun fails too" do
    File.write(log, colorized)

    expect(run(passes: false)).to eq(1)
    expect(summaries.join).to start_with("### Failed twice\n")
  end

  it "doesn't rerun when there are no ids (or no log)" do
    expect(run).to eq(1)
    expect(reruns).to be_empty
    expect(summaries.join).to start_with("### Failed, nothing to rerun")
  end

  it "doesn't rerun more failures than a flake would make" do
    File.write(log, (1..21).map { |n| "rspec ./spec/x_spec.rb:#{n} # x\n" }.join)

    expect(run).to eq(1)
    expect(reruns).to be_empty
    expect(summaries.join).to start_with("### Failed: 21 examples, not rerun (more than 20)")
  end

  it "runs in the bundles job after failed bundle specs, from their failures list, on the bundle test kit" do
    workflow = YAML.safe_load_file(File.expand_path("../../.github/workflows/ci.yml", __dir__))
    rakefile = File.read(File.expand_path("../../Rakefile", __dir__))
    steps = workflow.dig("jobs", "bundles", "steps")
    specs = steps.index { |step| step["id"] == "specs" }

    expect(steps[specs]["run"]).to eq("bundle exec rake bundles:specs")
    expect(rakefile).to include('"--format", "failures", "--out", File.join(ROOT, "tmp/bundle_failures.log")')
    expect(steps[specs + 1]).to include("if" => "failure() && steps.specs.outcome == 'failure'")
    expect(steps[specs + 1]["run"]).to include("--log tmp/bundle_failures.log")
    expect(steps[specs + 1]["run"]).to include('--rspec "bundle exec rspec --options /dev/null -r samagotchi/testing/rspec"')
  end

  it "runs in both rspec jobs, right after a failed parallel_rspec" do
    workflow = YAML.safe_load_file(File.expand_path("../../.github/workflows/ci.yml", __dir__))

    %w[rspec rspec-macos].each do |job|
      steps = workflow.dig("jobs", job, "steps")
      specs = steps.index { |step| step["id"] == "specs" }

      expect(steps[specs]["run"]).to start_with("bundle exec parallel_rspec")
      expect(steps[specs + 1]).to include("if" => "failure() && steps.specs.outcome == 'failure'")
      expect(steps[specs + 1]["run"]).to start_with("ruby script/rerun_failures.rb --job ")
    end
  end
end
