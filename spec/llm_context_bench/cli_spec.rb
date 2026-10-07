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
    expect(run(dir, "--min-turn-tool", "0", "--strategy", "none,forget_all,forget_outputs")).to eq(0)

    text = out.string
    expect(text).to include("llm_context bench: 2 sessions, 2 cases from #{dir}", "Profile (none, every session)",
                            "reads: 3 over 2 files")
    expect(text.lines.grep(/\A  forget_all /).map { |line| line.split[1] }).to eq(%w[acme/coder-1 local-qwen])
    expect(text).to include("forget_outputs: skipped, forget_outputs needs a model to ask")
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

  describe "how each case ends" do
    # Turn 0 of this one ends on a tool result: the answer is cut out.
    before do
      BenchFixtures.write_session(dir, messages: BenchFixtures.chat_messages.reject.with_index { |_m, i| i == 6 },
                                       id: "cccccccc-0000-4000-8000-000000000000")
    end

    it "keeps answer-ended turns by default, all under --ends any, and reports the endings" do
      run(dir, "--min-turn-tool", "0", "--no-profile", "--per-case")
      expect(out.string).to include("3 sessions, 2 cases", "cases end with: answer 2")

      out.truncate(0)
      out.rewind
      run(dir, "--min-turn-tool", "0", "--no-profile", "--per-case", "--ends", "any")
      expect(out.string).to include("3 sessions, 3 cases", "cases end with: answer 2, tool_result 1")
      expect(out.string.lines.grep(/\A  forget_all .* cccccccc_t0 /).first.split[4]).to eq("tool_result")
    end

    it "says what each case ends with in the JSON" do
      run(dir, "--json", "--no-profile", "--min-turn-tool", "0", "--ends", "any")
      data = JSON.parse(out.string)
      expect(data["case_ends"]).to eq("aaaaaaaa_t0" => "answer", "bbbbbbbb_t0" => "answer", "cccccccc_t0" => "tool_result")
      expect(data["cases"].map { |c| [c["case_name"], c["ends"]] }.uniq).to include(%w[cccccccc_t0 tool_result])
    end

    it "keeps named cases as named, and says which --ends answer drops" do
      File.write(File.join(dir, "cases.txt"), "aaaaaaaa_t0\ncccccccc_t0\n")
      run(dir, "--cases", File.join(dir, "cases.txt"), "--no-profile")
      expect(out.string).to include("2 cases", "answer 1, tool_result 1")

      run(dir, "--cases", File.join(dir, "cases.txt"), "--no-profile", "--ends", "answer")
      expect(err.string).to include("--ends answer skipped 1 named case(s) that don't end with an answer")
    end
  end

  it "refuses a folder that isn't there" do
    expect(run(File.join(dir, "missing"))).to eq(2)
    expect(err.string).to include("no sessions directory")
  end
end
