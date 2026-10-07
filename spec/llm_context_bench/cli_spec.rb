# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../script/llm_context_bench/cli"
require_relative "bench_fixtures"

RSpec.describe LLMContextBench::CLI do
  let(:dir) { Dir.mktmpdir("bench-cli-") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  before do
    BenchFixtures.write_session(dir, messages: BenchFixtures.chat_messages, id: "aaaaaaaa-0000-4000-8000-000000000000")
    BenchFixtures.write_session(dir, messages: BenchFixtures.native_messages, model: "local-qwen",
                                     id: "bbbbbbbb-0000-4000-8000-000000000000")
  end

  after { FileUtils.rm_rf(dir) }

  def run(*argv, env: {}) = described_class.new(argv, env: env, out: out, err: err).run

  it "prints the profile and a row per strategy and model, and says what isn't built" do
    expect(run(dir, "--min-turn-tool", "0", "--strategy", "none,forget_all,stale")).to eq(0)

    text = out.string
    expect(text).to include("llm_context bench: 2 sessions, 2 cases from #{dir}", "Profile (none, every session)",
                            "reads: 3 over 2 files")
    expect(text.lines.grep(/\A  forget_all /).map { |line| line.split[1] }).to eq(%w[acme/coder-1 local-qwen])
    expect(text).to include("stale: skipped, stale is not built yet (P2")
  end

  it "reads the sessions folder from the environment and answers JSON" do
    expect(run("--json", "--no-profile", "--min-turn-tool", "0", "--session", "aaaa",
               env: { "LLM_CONTEXT_BENCH_SESSIONS" => dir })).to eq(0)

    data = JSON.parse(out.string)
    expect(data).to include("sessions" => 1, "profile" => nil)
    expect(data["rows"].map { |row| row["strategy"] }).to eq(%w[none forget_all])
    expect(data["cases"].first).to include("case_name" => "aaaaaaaa_t0", "freed" => 0.0)
  end

  it "scores only the cases a --cases file names" do
    File.write(File.join(dir, "cases.txt"), "# one\nbbbbbbbb_t0\n")

    run(dir, "--cases", File.join(dir, "cases.txt"), "--per-case", "--no-profile")
    expect(out.string.lines.grep(/_t0/).map { |line| line.split[3] }.uniq).to eq(%w[bbbbbbbb_t0])
  end

  it "refuses a folder that isn't there" do
    expect(run(File.join(dir, "missing"))).to eq(2)
    expect(err.string).to include("no sessions directory")
  end
end
