# frozen_string_literal: true

require "tmpdir"
require_relative "../../script/llm_context_bench/cli"
require_relative "bench_fixtures"

RSpec.describe LLMContextBench::Cases do
  let(:dir) { Dir.mktmpdir("bench-cases-") }
  let(:replay) { LLMContextBench::Replay.load(BenchFixtures.write_session(dir, messages: messages)) }

  after { FileUtils.rm_rf(dir) }

  def big(label) = "[execute]\nstdout:\n#{"#{label} line of output\n" * 800}"

  # Four turns, each with a big output: turn 0 ends with the model's
  # answer, turn 1 on a tool result (the session saved mid-task), turn 2 on
  # chi's turn note, turn 3 (the last, never a case) with an answer.
  def messages
    [
      { "role" => "system", "content" => "You are a coding agent." },
      BenchFixtures.user("Run the cart spec."),
      BenchFixtures.model("", calls: [BenchFixtures.call("c1", "execute", { "command" => "rspec spec/cart_spec.rb" })]),
      BenchFixtures.result("c1", big("cart")),
      BenchFixtures.model("The cart spec passes."),
      BenchFixtures.user("Now the orders spec."),
      BenchFixtures.model("", calls: [BenchFixtures.call("c2", "execute", { "command" => "rspec spec/orders_spec.rb" })]),
      BenchFixtures.result("c2", big("orders")),
      BenchFixtures.user("And the totals spec."),
      BenchFixtures.model("", calls: [BenchFixtures.call("c3", "execute", { "command" => "rspec spec/totals_spec.rb" })]),
      BenchFixtures.result("c3", big("totals")),
      { "role" => "system", "kind" => "turn_note", "content" => "[SYSTEM: the previous turn was cancelled.]" },
      BenchFixtures.user("Sum it up."),
      BenchFixtures.model("All three pass.")
    ]
  end

  def kase(turn) = LLMContextBench::Case.new(replay: replay, turn: turn)

  it "says what each case's turn ends with" do
    expect((0..2).map { |turn| kase(turn).ends }).to eq(%w[answer tool_result turn_note])
  end

  it "tells an unanswered call and an empty model entry from an answer" do
    unanswered = messages.first(3) + [BenchFixtures.user("Next.")]
    empty = messages.first(4) + [BenchFixtures.model("", thinking: "hmm"), BenchFixtures.user("Next.")]
    expect([unanswered, empty].map do |entries|
      LLMContextBench::Case.new(replay: LLMContextBench::Replay.load(BenchFixtures.write_session(dir, messages: entries)),
                                turn: 0).ends
    end).to eq(%w[tool_call empty])
  end

  it "keeps answer-ended turns by default under the turn-size rule, every turn under any" do
    expect(described_class.select([replay]).map(&:turn)).to eq([0])
    expect(described_class.select([replay], ends: "any").map(&:turn)).to eq([0, 1, 2])
  end

  it "keeps named cases as named unless asked for answer-ended ones" do
    names = (0..2).map { |turn| kase(turn).name }
    expect(described_class.select([replay], names: names).map(&:turn)).to eq([0, 1, 2])
    expect(described_class.select([replay], names: names, ends: "answer").map(&:turn)).to eq([0])
    expect { described_class.select([replay], ends: "prefer") }.to raise_error(ArgumentError, /ends/)
  end

  it "tallies the endings" do
    expect(described_class.ends_tally(%w[tool_result answer tool_result turn_note])).to eq("answer 1, tool_result 2, turn_note 1")
  end
end
