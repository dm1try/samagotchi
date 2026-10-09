# frozen_string_literal: true

require "tmpdir"
require_relative "live_fixtures"
require_relative "../llm_context_bench/bench_fixtures"

RSpec.describe "the llm_context live harness" do
  let(:dir) { Dir.mktmpdir("live-harness-") }

  after { FileUtils.rm_rf(dir) }

  describe LLMContextLive::TaskFile do
    def load(yaml, changed: "lib/cart.rb\nspec/cart_spec.rb\n")
      path = File.join(dir, "tasks.yml")
      File.write(path, yaml)
      described_class.load(path, git: ->(_argv) { changed })
    end

    it "reads the hidden specs, regression specs and fix set from the fix commit unless given" do
      file = load("source_repo: /src\ntasks:\n  T1:\n    fix: abc\n    turns: [one, two]\n")

      task = file.tasks.first
      expect(task.to_h).to include(id: "T1", fix: "abc", hidden: %w[spec/cart_spec.rb], regression: %w[spec/cart_spec.rb],
                                   fix_files: %w[lib/cart.rb spec/cart_spec.rb])
      expect(LLMContextLive::Task.hidden_path(task.hidden.first)).to eq("spec/cart_p6hidden_spec.rb")
    end

    it "takes a hidden spec from hidden/<task>/ next to the tasks file when there is one" do
      FileUtils.mkdir_p(File.join(dir, "hidden", "T1", "spec"))
      File.write(File.join(dir, "hidden", "T1", "spec", "cart_spec.rb"), "# the contract only")
      task = load("source_repo: /src\ntasks:\n  T1:\n    fix: abc\n    turns: [one]\n  T2:\n    fix: def\n    turns: [one]\n").tasks

      expect(task.first.override("spec/cart_spec.rb")).to eq("# the contract only")
      expect(task.last.override("spec/cart_spec.rb")).to be_nil
    end

    it "puts the run's repo into a turn and refuses an unknown task" do
      file = load("source_repo: /src\ntasks:\n  T1:\n    fix: abc\n    turns: ['look in {repo}/lib']\n")

      expect(file.tasks.first.turn_text(0, repo: "/runs/r/repo")).to eq("look in /runs/r/repo/lib")
      expect { file.select(%w[T9]) }.to raise_error(ArgumentError, /T9/)
    end
  end

  describe LLMContextLive::Ledger do
    subject(:ledger) { described_class.new(dir) }

    it "blocks a run at the cap and on the stop file" do
      ledger.add("T1-none-s1", 3.5)
      ledger.add("T1-stale-s1", 1.25)

      expect(ledger.total).to eq(4.75)
      expect(ledger.blocked(5.0)).to be_nil
      expect(ledger.blocked(4.5)).to include("$4.75 of $4.50")
      ledger.stop!("a payment error in T1-stale-s1")
      expect(ledger.blocked(nil)).to include("STOP", "payment error")
    end
  end

  describe LLMContextLive::Report do
    def results(none:, challenger:, none_pass: [true] * 3, challenger_pass: [true] * 3)
      %w[T1 T2].flat_map do |task|
        none.each_with_index.map { |re_reads, i| LiveFixtures.result(task: task, arm: "none", sample: i + 1, re_reads: re_reads, files_read: 6 + i, pass: none_pass[i]) } +
          challenger.each_with_index.map { |re_reads, i| LiveFixtures.result(task: task, arm: "stale_forget", sample: i + 1, re_reads: re_reads, files_read: 2, pass: challenger_pass[i]) }
      end
    end

    it "gives each task × arm its pass count and the medians with their spread" do
      report = described_class.new(results(none: [4, 6, 9], challenger: [1, 2, 2]), { "T1-none-s1" => { "grade" => 2 } })

      group = report.to_h[:groups].find { |row| row[:task] == "T1" && row[:arm] == "none" }
      expect(group).to include(n: 3, pass: 3, grades: [2])
      expect(group[:metrics][:re_reads]).to eq(median: 6, min: 4, max: 9)
      expect(report.text).to include("T1 none: pass 3/3, grade 2", "re_reads               6 (4–9)")
    end

    it "passes the gate when stale_forget is below none's spread on re-reads and scope, success not lower" do
      report = described_class.new(results(none: [4, 6, 9], challenger: [1, 2, 2]))

      expect(report.gate).to include(verdict: "PASS")
      expect(report.gate[:tasks]["T1"]).to eq(re_reads: "better", scope: "better")
    end

    it "calls a difference within none's spread the same, and fails on lower success" do
      report = described_class.new(results(none: [1, 3, 9], challenger: [2, 3, 4], challenger_pass: [true, false, false]))

      expect(report.gate[:tasks]["T1"][:re_reads]).to eq("same")
      expect(report.gate).to include(verdict: "FAIL", success: { challenger: 2, baseline: 6 })
    end
  end

  describe LLMContextLive::Collector do
    let(:workspace) { LLMContextLive::Workspace.new(dir) }
    let(:shell) { LLMContextLive::Shell.new }

    def git(*args) = shell.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", workspace.repo, *args])

    before do
      FileUtils.mkdir_p(File.join(workspace.repo, "lib"))
      File.write(File.join(workspace.repo, "lib", "cart.rb"), "class Cart\nend\n")
      git("init", "-q")
      git("add", "-A")
      git("commit", "-qm", "base")
      File.write(File.join(workspace.repo, "lib", "cart.rb"), "class Cart\n  def total = 0\nend\n")
      File.write(File.join(workspace.repo, "lib", "notes.rb"), "# new\n")
    end

    it "reads the session's steps, re-reads, tokens and scope, and the diff against the base commit" do
      id = "11111111-2222-3333-4444-555555555555"
      BenchFixtures.write_session(workspace.sessions_dir, messages: BenchFixtures.chat_messages, id: id)
      analytics = File.join(workspace.sessions_dir, id, "analytics.json")
      FileUtils.mkdir_p(File.dirname(analytics))
      File.write(analytics, JSON.generate(turn_records: [
        { prompt_tokens_sum: 1000, prompt_tokens: 400, prompt_tokens_max: 500, cached_tokens_sum: 600, cost: 0.01 },
        { prompt_tokens_sum: 2000, prompt_tokens: 700, cached_tokens_sum: 1500, reprefill_tokens_sum: 90, cost: 0.02 }
      ]))

      metrics = described_class.new(shell: shell).collect(LiveFixtures.task(fix_files: %w[lib/cart.rb]), workspace, id)

      expect(metrics).to include(steps: 6, edits: 1, reads: 2, re_reads: 1, re_reads_after_stub: 0, prompt_tokens: 3000,
                                 cached_tokens: 2100, reprefill_tokens: 90, cost: 0.03, peak_context: 700, files_read: 1,
                                 files_read_outside: 0, files_changed: 2, files_changed_outside: 1, diff_lines: 2)
    end

    it "has nothing for a run whose session never started" do
      expect(described_class.new(shell: shell).collect(LiveFixtures.task, workspace, nil)).to eq({})
    end
  end

  describe LLMContextLive::Workspace do
    # runs/ is kept and shared: the host copy must carry no key itself.
    it "copies the model's host without a literal api_key, keeping api_key_env" do
      hosts = { "or" => { "url" => "https://example.test/v1", "api" => "openai", "api_key_env" => "OR_KEY",
                          "api_key" => "sk-secret" },
                "other" => { "host" => "10.0.0.1" } }

      path = described_class.new(dir).write_config(model: "or:m", hosts: hosts)

      written = File.read(path)
      expect(written).not_to include("sk-secret")
      expect(YAML.safe_load(written)["hosts"]).to eq("or" => { "url" => "https://example.test/v1", "api" => "openai",
                                                               "api_key_env" => "OR_KEY" })
    end
  end

  describe LLMContextLive::Grader do
    let(:workspace) { LLMContextLive::Workspace.new(dir) }

    before { FileUtils.mkdir_p(File.join(workspace.repo, "spec")) }

    it "copies the fix's spec in as a hidden one, runs it with the regression specs, and removes it" do
      File.write(File.join(workspace.repo, "spec", "cart_spec.rb"), "# the model's")
      hidden = File.join(workspace.repo, "spec", "cart_p6hidden_spec.rb")
      seen = nil
      shell = LiveFixtures::FakeShell.new
                                     .on(%r{git -C /src show abc1234:spec/cart_spec.rb}, LiveFixtures.ran("# the fix's"))
                                     .on(/rspec/) do |argv, _options|
        seen = [argv.last(2), File.read(hidden)]
        out = argv[argv.index("--out") + 1]
        File.write(out, JSON.generate(summary: { example_count: 5, failure_count: 1 },
                                      examples: [{ status: "failed", file_path: "./spec/cart_p6hidden_spec.rb", full_description: "Cart rounds" }]))
        LiveFixtures.ran(status: 1)
      end

      grade = described_class.new(shell: shell).grade(LiveFixtures.task, workspace, source_repo: "/src")

      expect(seen).to eq([%w[spec/cart_p6hidden_spec.rb spec/cart_spec.rb], "# the fix's"])
      expect(grade.to_h).to include(pass: false, examples: 5, failures: 1, hidden_failures: 1, failed: ["Cart rounds"])
      expect(File.exist?(hidden)).to be(false)
    end
  end

  describe LLMContextLive::Runner do
    let(:task) { LiveFixtures.task }
    let(:arms) { LLMContextLive::ARMS.values_at("none", "stale_forget") }

    it "plans sample-major: one run of each task × arm before a second" do
      ids = described_class.plan([task, LiveFixtures.task(id: "T2")], arms, 2).map(&:id)

      expect(ids).to eq(%w[T1-none-s1 T1-stale_forget-s1 T2-none-s1 T2-stale_forget-s1
                           T1-none-s2 T1-stale_forget-s2 T2-none-s2 T2-stale_forget-s2])
    end

    it "skips runs with a result, starts at most --limit, and starts none past the cap" do
      file = instance_double(LLMContextLive::TaskFile, source_repo: "/src")
      runner = described_class.new(root: dir, task_file: file, chi: "/opt/chi", log: StringIO.new, model: "or:m",
                                   cap: 1.0, limit: 2, jobs: 1)
      started = []
      allow(runner).to receive(:one) { |run| started << run.id }
      planned = described_class.plan([task], arms, 2)
      FileUtils.mkdir_p(File.join(dir, "results"))
      File.write(runner.result_path("T1-none-s1"), "{}")

      expect(runner.run(planned)).to eq(0)
      expect(started).to eq(%w[T1-stale_forget-s1 T1-none-s2])

      LLMContextLive::Ledger.new(dir).add("T1-stale_forget-s1", 1.5)
      started.clear
      expect(runner.run(planned)).to eq(1)
      expect(started).to be_empty
    end
  end
end
