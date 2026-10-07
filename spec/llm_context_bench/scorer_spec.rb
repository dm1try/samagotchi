# frozen_string_literal: true

require "tmpdir"
require_relative "../../script/llm_context_bench/scorer"
require_relative "bench_fixtures"

RSpec.describe LLMContextBench::Scorer do
  let(:dir) { Dir.mktmpdir("bench-scorer-") }
  let(:chat) { LLMContextBench::Replay.load(BenchFixtures.write_session(dir, messages: BenchFixtures.chat_messages)) }
  let(:kase) { LLMContextBench::Case.new(replay: chat, turn: 0) }
  let(:scorer) { described_class.new }

  after { FileUtils.rm_rf(dir) }

  def score(strategy) = scorer.score(strategy.plans(kase).first)

  describe "the case" do
    it "is scored at the next turn's first request, over the outputs before it" do
      expect(kase.name).to eq("#{chat.short_id}_t0")
      expect(kase.at).to eq(3)
      expect(kase.outputs.map(&:id)).to eq(%w[e3.1 e5.1])
    end

    it "is selected by name or by the turn's own tool tokens" do
      expect(LLMContextBench::Cases.select([chat], min_turn_tool: 0).map(&:name)).to eq([kase.name])
      expect(LLMContextBench::Cases.select([chat])).to be_empty
      expect(LLMContextBench::Cases.select([chat], names: [kase.name]).map(&:turn)).to eq([0])
    end
  end

  describe "none" do
    it "changes nothing and still counts the base rate" do
      result = score(LLMContextBench::Strategies::None.new)

      expect(result).to have_attributes(forgotten: 0, freed: 0.0, re_prefilled: 0, wrong_strict: 0, outputs: 2,
                                        need_strict: 1, need_loose: 1, model: "acme/coder-1", policy: "-")
      expect(result.tool_tokens).to eq(kase.outputs.sum(&:tokens))
    end
  end

  describe "forget_all" do
    subject(:result) { score(LLMContextBench::Strategies::ForgetAll.new) }

    let(:read_text) { chat.messages[3][:content] }
    let(:execute_text) { chat.messages[5][:content] }

    it "frees what the view's stubs leave out" do
      expected = (read_text.length - "[read] (forgotten) ".length + execute_text.length -
                  "[execute] (forgotten) ".length) / 4.0
      expect(result.freed).to eq(expected)
    end

    it "counts the forgotten outputs the next turn needs, and the one its first step re-reads" do
      expect(result).to have_attributes(forgotten: 2, wrong_strict: 1, wrong_loose: 1, one_step_outputs: 1)
    end

    it "counts the cached prompt from the first stub on as prefilled again" do
      view = scorer.view(chat, 3, LLMContextBench::Strategies::ForgetAll.new.plans(kase).first.edits)
      expect(view[3][:content]).to eq("[read] (forgotten) ")
      expect(result.re_prefilled).to eq(view[3...7].sum { |entry| chat.entry_tokens(entry) })
    end
  end

  describe "picks" do
    let(:picks_dir) { File.join(dir, "picks") }
    let(:picks) { LLMContextBench::Strategies::Picks.new(label: "acme", dir: picks_dir) }

    def response(ids, note, name: "context_edit", key: "forget")
      { "choices" => [{ "message" => { "tool_calls" => [
        { "function" => { "name" => name, "arguments" => JSON.generate(key => ids, "note" => note) } }
      ] } }] }
    end

    def write_pick(variant, record)
      FileUtils.mkdir_p(picks_dir)
      File.write(File.join(picks_dir, "#{kase.name}.#{variant}.json"), JSON.generate(record))
    end

    it "reads the spike's entry ids: t2 is the second tool_response entry" do
      write_pick("pick", "unforced" => response(["t2"], "the spec fails on rounding"))
      plan = picks.plans(kase).first

      expect(plan).to have_attributes(model: "acme", policy: "pick", how: "unforced", invalid_ids: 0)
      expect(plan.edits.map { |edit| [edit.output_id, edit.note] }).to eq([["e5.1", "the spec fails on rounding"]])
    end

    it "reads run ids, ranges and the forced pick, notes a pointer on all but the first, and counts unknown ids" do
      write_pick("pick_soft_s2", "unforced" => { "choices" => [{ "message" => { "content" => "no" } }] },
                                 "forced" => response(["t1-t2", "#t9"], "cart rounds", name: "forget_outputs", key: "ids"),
                                 "bench" => { "id_scheme" => "run" })
      plan = picks.plans(kase).first

      expect(plan).to have_attributes(policy: "pick_soft", how: "forced", invalid_ids: 1)
      expect(plan.edits.map(&:note)).to eq(["cart rounds", "see the note on #t1"])
      expect(picks.case_names).to eq([kase.name])
    end

    it "stubs every run of a native joined entry a spike id names" do
      native = LLMContextBench::Replay.load(BenchFixtures.write_session(dir, messages: BenchFixtures.native_messages))
      native_case = LLMContextBench::Case.new(replay: native, turn: 0)
      FileUtils.mkdir_p(picks_dir)
      File.write(File.join(picks_dir, "#{native_case.name}.pick.json"),
                 JSON.generate("unforced" => response(["t1"], "two specs")))
      plan = picks.plans(native_case).first

      expect(plan.edits.map(&:output_id)).to eq(%w[e3.1 e3.2])
      view = scorer.view(native, native_case.at, plan.edits)
      expect(view[3][:content]).to eq("[execute] (forgotten) two specs\n\n---\n\n[read] (forgotten) two specs")
      expect(scorer.score(plan).freed).to be > 0
    end

    it "parses the id forms a model writes" do
      expect(LLMContextBench::Strategies::Picks.parse_ids(%w[t1 #t2 t4-t6 t7–#t8])).to eq(%w[t1 t2 t4 t5 t6 t7 t8])
    end
  end

  describe "stale" do
    # Turn 0 reads lib/cart.rb, runs the spec, reads the file again and
    # edits it (an edit supersedes nothing); turn 1 asks for more. Scored
    # at turn 1's first request.
    let(:messages) do
      body = (1..30).map { |n| "#{n}: line #{n} of CartTotals" }.join("\n")
      [{ "role" => "system", "content" => "You are a coding agent." },
       BenchFixtures.user("Fix the rounding."),
       BenchFixtures.model("", calls: [BenchFixtures.call("c1", "read", { "path" => "lib/cart.rb" })]),
       BenchFixtures.result("c1", "[read]\n#{body}"),
       BenchFixtures.model("", calls: [BenchFixtures.call("c2", "execute", { "command" => "rspec" })]),
       BenchFixtures.result("c2", "[execute]\n1 failure"),
       BenchFixtures.model("", calls: [BenchFixtures.call("c3", "read", { "path" => "#{BenchFixtures::WORKDIR}/lib/cart.rb" })]),
       BenchFixtures.result("c3", "[read]\n#{body}"),
       BenchFixtures.model("", calls: [BenchFixtures.call("c4", "edit", { "path" => "lib/cart.rb", "old_text" => "1",
                                                                          "new_text" => "2" })]),
       BenchFixtures.result("c4", "[edit]\nEdited lib/cart.rb"),
       BenchFixtures.model("Fixed."),
       BenchFixtures.user("Now the taxes."),
       BenchFixtures.model("On it.")]
    end
    let(:replay) { LLMContextBench::Replay.load(BenchFixtures.write_session(dir, messages: messages)) }
    let(:stale_case) { LLMContextBench::Case.new(replay: replay, turn: 0) }

    it "stubs each read at the request after the call that superseded it, as chi does, and scores it" do
      plan = LLMContextBench::Strategies.build("stale").plans(stale_case).first

      expect(plan.edits.map { |edit| [edit.output_id, edit.applies_at, edit.note] })
        .to eq([["e3.1", 3, "lib/cart.rb: superseded by a later read"]])
      expect(scorer.view(replay, stale_case.at, plan.edits)[3][:content]).to eq("[read] lib/cart.rb: superseded by a later read")
      result = scorer.score(plan)
      expect(result).to have_attributes(strategy: "stale", model: "acme/coder-1", forgotten: 1)
      expect(result.freed).to be > 0
      expect(result.re_prefilled).to be > 0
      # The scorer's proxy counts any later call on the file, the edit the
      # first stub reaches included (the newer read it edits against stays).
      expect(result).to have_attributes(wrong_strict: 1, one_step_outputs: 1)
    end
  end

  describe "the slots" do
    it "names forget_outputs as not built yet, with its phase" do
      expect { LLMContextBench::Strategies.build("forget_outputs").plans(kase) }.to raise_error(LLMContextBench::NotBuilt, /P4/)
      expect { LLMContextBench::Strategies.build("summarize") }.to raise_error(ArgumentError, /unknown strategy/)
    end
  end
end
