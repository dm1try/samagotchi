# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../script/llm_context_bench/cli"
require_relative "bench_fixtures"

RSpec.describe LLMContextBench::Strategies::ForgetOutputs do
  let(:dir) { Dir.mktmpdir("bench-forget-") }
  let(:spec_log) { (1..40).map { |n| "spec #{n}: ok" }.join("\n") }
  let(:replay) { LLMContextBench::Replay.load(BenchFixtures.write_session(dir, messages: messages)) }
  let(:kase) { LLMContextBench::Case.new(replay: replay, turn: 0) }

  after { FileUtils.rm_rf(dir) }

  # A chat session (synthetic): turn 0 reads two files and runs three
  # commands, then answers; turn 1 asks for more.
  def messages
    steps = [%w[c1 read path lib/a.rb], %w[c2 execute command rspec], %w[c3 read path lib/b.rb],
             %w[c4 execute command ls], ["c5", "execute", "command", "git status"]]
    [{ "role" => "system", "content" => "You are a coding agent." }, BenchFixtures.user("Look around."),
     *steps.flat_map do |id, name, key, value|
       [BenchFixtures.model("", calls: [BenchFixtures.call(id, name, { key => value })]),
        BenchFixtures.result(id, "[#{name}]\n#{spec_log}")]
     end,
     BenchFixtures.model("a.rb and b.rb are fine; the spec passes."), BenchFixtures.user("Now fix c.rb."),
     BenchFixtures.model("Done.")]
  end

  def answer(*calls)
    { "choices" => [{ "message" => { "content" => "", "tool_calls" => calls.each_with_index.map do |(name, args), n|
      { "id" => "f#{n}", "type" => "function", "function" => { "name" => name, "arguments" => JSON.generate(args) } }
    end } }] }
  end

  def strategy(response, budget: 100)
    asked = []
    picker = lambda do |the_case, sent, tools|
      asked << [the_case, sent, tools]
      response
    end
    [described_class.new(picker: picker, budget: budget), asked]
  end

  it "asks with what chi would send at the next turn's start: ids on each output, its offer line, its tools" do
    forget, asked = strategy(answer)
    forget.plans(kase)

    _, sent, tools = asked.first
    expect(tools.map { |tool| tool[:function][:name] }).to include("read", "forget_outputs")
    expect(tools.last[:function][:description]).to include("Policy: Tidy at subtask boundaries")
    expect(sent.select { |message| message[:role] == "tool" }.map { |message| message[:content][0, 14] })
      .to eq(["[read]\n[#t1] s", "[execute]\n[#t2", "[read]\n[#t3] s", "[execute]\n[#t4", "[execute]\n[#t5"])
    expect(sent[-2]).to include(role: "user")
    expect(sent.last[:content]).to start_with("[CONTEXT: ~").and include("over the budget", "forget_outputs")
  end

  it "runs a forget_outputs call through chi: the forgets it lets through, the ids it refuses, the note" do
    note = "a.rb, the spec: nothing to fix (VERIFIED). NEXT: c.rb"
    forget, = strategy(answer(["read", { "path" => "lib/c.rb" }], ["forget_outputs", { "ids" => %w[t1 t2 t5], "note" => note }]))

    plan = forget.plans(kase).first

    expect(plan).to have_attributes(how: "called", invalid_ids: 1, note_chars: note.length, model: replay.model_name)
    expect(plan.edits.map { |edit| [edit.output_id, edit.note, edit.applies_at] })
      .to eq([["e3.1", note, kase.at], ["e5.1", note, kase.at]])
    result = LLMContextBench::Scorer.new.score(plan)
    expect(result).to have_attributes(forgotten: 2, note_chars: note.length)
    expect(result.freed).to be > 0
  end

  it "counts a model that doesn't call the tool, and a case it couldn't ask" do
    expect(strategy(answer(["read", { "path" => "lib/c.rb" }])).first.plans(kase).first)
      .to have_attributes(how: "no_call", edits: [])
    expect(strategy(nil).first.plans(kase).first.how).to eq("unasked")
    expect { described_class.new(picker: nil).plans(kase) }.to raise_error(LLMContextBench::NotBuilt, /needs a model/)
  end

  describe LLMContextBench::Strategies::ForgetAnswers do
    it "saves each case's answer and reads it back, asking nothing twice, and stops at --max-cost" do
      asks = 0
      ask = lambda do |_messages, _tools|
        asks += 1
        answer.merge("usage" => { "cost" => 0.5 })
      end
      answers = described_class.new(dir: File.join(dir, "out"), label: "acme", ask: ask, max_cost: 0.5, log: StringIO.new)

      2.times { answers.call(kase, [], []) }
      expect(asks).to eq(1)
      expect(File).to exist(answers.path(kase))
      other = LLMContextBench::Case.new(replay: replay, turn: 1)
      expect { answers.call(other, [], []) }.to raise_error(LLMContextBench::LivePick::PaymentStop, /max-cost/)
    end

    it "doesn't save an error answer: a rerun asks again" do
      answers = described_class.new(dir: File.join(dir, "out"), label: "acme", ask: ->(*) { { "error" => "503" } },
                                    log: StringIO.new)

      expect(answers.call(kase, [], [])).to eq("error" => "503")
      expect(File).not_to exist(answers.path(kase))
    end
  end

  describe "the CLI" do
    let(:out) { StringIO.new }
    let(:err) { StringIO.new }

    it "scores forget_outputs next to none and stale, with its call rate and notes, from a model it asks" do
      replay
      response = Samagotchi::LLM::ChatResponse.new(
        text: "", reasoning: "", finish_reason: "tool_calls", usage: Samagotchi::LLM::Usage.none,
        tool_calls: [Samagotchi::LLM::ToolCall.new(id: "f", name: "forget_outputs",
                                                   arguments: { "ids" => ["t1"], "note" => "a.rb is fine" })]
      )
      chat = BenchFixtures::FakeChat.new(response)
      cli = LLMContextBench::CLI.new([dir, "--strategy", "none,stale,forget_outputs", "--forget-model", "fake:m",
                                      "--out", File.join(dir, "answers"), "--min-turn-tool", "0", "--no-profile"],
                                     out: out, err: err, chat_adapter: ->(_ref) { [chat, "m"] })

      expect(cli.run).to eq(0)
      row = out.string.lines.grep(/\A  forget_outputs /).first
      expect(row).to include("1/5", "1 called", "call rate 100%, notes 12 chars")
      expect(out.string.lines.grep(/\A  (none|stale) /).size).to eq(2)
      expect(chat.requests.size).to eq(1)
    end

    it "needs --out with --forget-model" do
      expect(LLMContextBench::CLI.new([dir, "--strategy", "forget_outputs", "--forget-model", "x"], out: out, err: err).run)
        .to eq(2)
      expect(err.string).to include("--forget-model needs --out DIR")
    end
  end
end
