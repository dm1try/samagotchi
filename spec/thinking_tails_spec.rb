# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/thinking_tails"

# ThinkingTails keeps the thinking a cut, stopped or length-capped
# generation would lose, in <session dir>/thinking_tails.jsonl.
RSpec.describe Samagotchi::ThinkingTails do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = File.join(dir, "sid")
      example.run
    end
  end

  let(:clock) { -> { Time.utc(2026, 10, 4, 12, 0, 0) } }
  let(:tails) { described_class.new(session_dir: -> { @dir }, clock: clock) }

  def records = described_class.read(@dir)

  # One generation: its thinking in chunks, then +ending+.
  def generation(thinking, ending, iteration: 1)
    tails.call(type: :generation_started, iteration: iteration)
    thinking.each { |chunk| tails.call(type: :generation_chunk, iteration: iteration, thinking: chunk, text: "") }
    tails.call({ iteration: iteration }.merge(ending))
  end

  it "keeps a cut generation's thinking, with who cut it" do
    tails.call(type: :turn_started, turn_id: "t1")
    generation(["Go. ", "OK. ", "Go. "], { type: :generation_completed, finish_reason: "stopped", stopped_by: "loop-guard",
                                           stop_reason: "its thinking kept repeating itself" }, iteration: 3)

    expect(records).to eq([{ "at" => "2026-10-04T12:00:00.000Z", "turn_id" => "t1", "iteration" => 3,
                             "finish_reason" => "stopped", "stopped_by" => "loop-guard",
                             "stop_reason" => "its thinking kept repeating itself", "thinking_chars" => 12,
                             "tail" => "Go. OK. Go. " }])
  end

  it "keeps the last TAIL_CHARS of a length-capped generation" do
    long = Array.new(30) { |i| "#{i.to_s.rjust(4, "0")} #{"x" * 995}" } # 30 chunks of 1000 chars

    generation(long, { type: :generation_completed, finish_reason: "length", content_length: 0 })

    record = records.first
    expect(record).to include("finish_reason" => "length", "thinking_chars" => 30_000)
    expect(record).not_to have_key("stopped_by")
    expect(record["tail"].length).to eq(described_class::TAIL_CHARS)
    expect(record["tail"]).to start_with("0010 ").and end_with("x" * 995)
  end

  it "keeps a generation a plugin's stop_turn ended, once on the native loop's cut and cancel" do
    generation(["Let me write. "], { type: :generation_cancelled, reason: :hook })
    generation(["Writing. "], { type: :generation_completed, finish_reason: "stopped", stopped_by: "loop-guard" }, iteration: 2)
    tails.call(type: :generation_cancelled, iteration: 2, reason: :hook)

    expect(records.map { |r| r.values_at("iteration", "finish_reason", "stopped_by", "tail") })
      .to eq([[1, "cancelled", "hook", "Let me write. "], [2, "stopped", "loop-guard", "Writing. "]])
  end

  it "keeps nothing of a finished generation, a user's Stop, or a cut with no thinking" do
    generation(["Fine. "], { type: :generation_completed, finish_reason: "stop" })
    generation(["Hmm. "], { type: :generation_cancelled, reason: :user })
    generation([], { type: :generation_completed, finish_reason: "stopped", stopped_by: "loop-guard" })

    expect(File).not_to exist(File.join(@dir, described_class::FILE))
  end

  it "starts over when the stream is retried" do
    tails.call(type: :generation_started, iteration: 1)
    tails.call(type: :generation_chunk, iteration: 1, thinking: "lost ")
    tails.call(type: :generation_retrying, iteration: 1)
    tails.call(type: :generation_chunk, iteration: 1, thinking: "kept")
    tails.call(type: :generation_completed, iteration: 1, finish_reason: "length")

    expect(records.first).to include("tail" => "kept", "thinking_chars" => 4)
  end

  it "keeps the newest MAX_RECORDS" do
    (described_class::MAX_RECORDS + 2).times do |i|
      generation(["loop #{i}"], { type: :generation_completed, finish_reason: "length" }, iteration: i + 1)
    end

    expect(records.size).to eq(described_class::MAX_RECORDS)
    expect(records.first["tail"]).to eq("loop 2")
    expect(records.last["tail"]).to eq("loop #{described_class::MAX_RECORDS + 1}")
  end

  it "writes nothing without a session, and never raises" do
    quiet = described_class.new(session_dir: -> {})
    quiet.call(type: :generation_chunk, thinking: "x")
    quiet.call(type: :generation_completed, finish_reason: "length")
    broken = described_class.new(session_dir: -> { raise "no dir" })
    broken.call(type: :generation_chunk, thinking: "x")

    expect { broken.call(type: :generation_completed, finish_reason: "length") }.not_to raise_error
  end
end
