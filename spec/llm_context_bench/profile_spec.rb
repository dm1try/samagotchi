# frozen_string_literal: true

require "tmpdir"
require_relative "../../script/llm_context_bench/profile"
require_relative "bench_fixtures"

RSpec.describe LLMContextBench::Profile do
  let(:dir) { Dir.mktmpdir("bench-profile-") }
  let(:chat) { LLMContextBench::Replay.load(BenchFixtures.write_session(dir, messages: BenchFixtures.chat_messages)) }
  let(:native) { LLMContextBench::Replay.load(BenchFixtures.write_session(dir, messages: BenchFixtures.native_messages)) }

  after { FileUtils.rm_rf(dir) }

  it "counts the resent tokens by category, thinking apart" do
    profile = described_class.new([chat])
    outputs = chat.outputs.sum(&:tokens)

    expect(profile.categories["tool_output"]).to eq(outputs)
    expect(profile.categories["thinking"]).to eq("Look at the cart.".length / 4.0)
    expect(profile.resent_total).to eq(chat.resent_tokens)
    expect(profile.share("tool_output")).to eq(outputs / chat.resent_tokens)
  end

  it "counts a native entry's prose, inline thinking and call arguments apart" do
    profile = described_class.new([native])

    expect(profile.categories["inline_thinking"]).to eq("Two calls.".length / 4.0)
    expect(profile.args_by_tool.keys).to contain_exactly("execute", "read")
    expect(profile.by_tool["execute"][:count]).to eq(2)
  end

  it "scores a turn's outputs against the later turns: re-read, path or identifier mentioned" do
    profile = described_class.new([chat])
    read, execute = chat.outputs.first(2)

    expect(profile.reference_counts).to include("all" => 2, "reread" => 1, "path_mention" => 1, "any" => 1)
    expect(profile.references["any"]).to eq(read.tokens)
    expect(profile.references["all"]).to eq(read.tokens + execute.tokens)
  end

  it "counts repeat reads of a file" do
    expect(described_class.new([chat]).reads).to eq(reads: 2, files: 1, files_read_twice: 1, repeat_reads: 1)
  end

  it "summarizes the output sizes, the big ones' share apart" do
    sizes = described_class.new([chat]).size_summary

    expect(sizes).to include(count: 4, big_count_share: 0.0, big_token_share: 0.0)
    expect(sizes[:max]).to eq(chat.outputs.map(&:tokens).max)
  end

  it "sums each turn and keeps the heaviest" do
    turns = described_class.new([chat, native]).turn_summary

    expect(turns[:count]).to eq(4)
    expect(turns[:heaviest].first).to include(:session, :turn, :tool, :calls, :total)
  end
end
