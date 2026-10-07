# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../script/llm_context_bench/cli"
require_relative "bench_fixtures"

RSpec.describe LLMContextBench::LivePick do
  let(:dir) { Dir.mktmpdir("bench-live-") }
  let(:out_dir) { File.join(dir, "picks") }
  let(:chat) { LLMContextBench::Replay.load(BenchFixtures.write_session(dir, messages: BenchFixtures.chat_messages)) }
  let(:kase) { LLMContextBench::Case.new(replay: chat, turn: 0) }

  after { FileUtils.rm_rf(dir) }

  def response(calls = [])
    Samagotchi::LLM::ChatResponse.new(text: "", reasoning: "", tool_calls: calls, finish_reason: "tool_calls",
                                      usage: Samagotchi::LLM::Usage.new(prompt_tokens: 900, completion_tokens: 40, source: :server))
  end

  def forget(ids, note, name: "forget_outputs")
    Samagotchi::LLM::ToolCall.new(id: "call_1", name: name, arguments: { "ids" => ids, "note" => note })
  end

  def picker(adapter = nil, **)
    described_class.new(adapter: adapter, model: "acme/coder-1", tool_name: "forget_outputs", policy: "subtask",
                        out_dir: out_dir, log: StringIO.new, **)
  end

  describe "#messages" do
    it "sends the conversation to the turn's end, each tool result led by its run id, then the tail line" do
      messages = picker.messages(kase)

      expect(messages.map { |m| m[:role] }).to eq(%w[system user assistant tool assistant tool assistant system])
      expect(messages[2][:tool_calls].first).to include(id: "c1", function: include(name: "read"))
      expect(messages[3]).to include(tool_call_id: "c1", content: start_with("[#t1] [read] lib/cart.rb"))
      expect(messages[5][:content]).to start_with("[#t2] [execute]")
      expect(messages.last[:content]).to include("you may free context with forget_outputs")
      expect(messages.to_s).not_to include("Look at the cart.")
    end

    it "gives a native batch's calls ids its runs answer, and drops the inline thinking" do
      native = LLMContextBench::Replay.load(BenchFixtures.write_session(dir, messages: BenchFixtures.native_messages))
      messages = picker.messages(LLMContextBench::Case.new(replay: native, turn: 0))

      expect(messages[2]).to include(content: "Looking.")
      expect(messages[2][:tool_calls].map { |call| call[:id] }).to eq(%w[n2_0 n2_1])
      expect(messages[3..4].map { |m| [m[:tool_call_id], m[:content].lines.first.chomp] })
        .to eq([["n2_0", "[#t1] [execute]"], ["n2_1", "[#t2] [read] spec/spec_helper.rb"]])
    end
  end

  describe "#tools" do
    it "offers chi's chat tools and the forget tool under the name under test, the policy line in its description" do
      tools = picker.tools
      expect(tools.map { |tool| tool[:function][:name] }).to include("read", "execute")
      expect(tools.last[:function]).to include(name: "forget_outputs", description: end_with(described_class::POLICY_LINE))

      other = picker(tool_name: "forget_llm_context", policy: "now").tools.last[:function]
      expect(other[:name]).to eq("forget_llm_context")
      expect(other[:description]).to eq(described_class::DESCRIPTION)
    end
  end

  describe "#run" do
    it "saves each pick where Picks scores it, and never asks again for a saved one" do
      adapter = BenchFixtures::FakeChat.new(response([forget(["t2"], "spec fails on rounding")]))
      written = picker(adapter).run([kase])

      expect(written).to eq([File.join(out_dir, "#{kase.name}.pick_forget_outputs_subtask_s1.json")])
      expect(adapter.requests.first).to include(model: "acme/coder-1", options: include(temperature: 0.6))
      expect(picker(BenchFixtures::FakeChat.new).run([kase])).to be_empty

      plan = LLMContextBench::Strategies::Picks.new(label: "acme", dir: out_dir).plans(kase).first
      expect(plan).to have_attributes(policy: "pick_forget_outputs_subtask", how: "unforced")
      expect(plan.edits.map(&:output_id)).to eq(%w[e5.1])
    end

    it "asks once more with the tool forced when the model didn't call it" do
      adapter = BenchFixtures::FakeChat.new(response, response([forget(["t1"], "cart")]))
      picker(adapter).run([kase])

      expect(adapter.requests.last[:options]).to include(tool_choice: { type: "function", function: { name: "forget_outputs" } })
      plan = LLMContextBench::Strategies::Picks.new(label: "acme", dir: out_dir).plans(kase).first
      expect(plan.how).to eq("forced")
    end
  end

  it "estimates the requests and prompt tokens of a run" do
    estimate = picker(samples: 2).estimate([kase])
    expect(estimate).to include(requests: 2, prompt_tokens: 2 * JSON.generate(picker.messages(kase)).length / 4.0)
  end

  it "refuses a host that isn't a chat host" do
    registry = instance_double(Samagotchi::HostRegistry, host_for_model: [double(name: "local", chat?: false), "m"])
    expect { described_class.chat_adapter("local:m", registry: registry) }.to raise_error(ArgumentError, /isn't a chat host/)
  end

  describe "the CLI's --live" do
    let(:out) { StringIO.new }
    let(:err) { StringIO.new }

    def run(*argv) = LLMContextBench::CLI.new(argv, env: {}, out: out, err: err).run

    before { BenchFixtures.write_session(dir, messages: BenchFixtures.chat_messages) }

    it "counts a run's requests and tokens on --dry-run, calling nothing" do
      expect(run(dir, "--live", "acme/coder-1", "--dry-run", "--min-turn-tool", "0", "--samples", "2")).to eq(0)
      expect(out.string).to match(/\A1 case\(s\) × 2 sample\(s\): 2 requests/)
    end

    it "needs --out" do
      expect(run(dir, "--live", "acme/coder-1")).to eq(2)
      expect(err.string).to include("--live needs --out DIR")
    end
  end
end
