# frozen_string_literal: true

require "tmpdir"
require_relative "../../script/llm_context_bench/replay"
require_relative "bench_fixtures"

RSpec.describe LLMContextBench::Replay do
  let(:dir) { Dir.mktmpdir("bench-replay-") }

  after { FileUtils.rm_rf(dir) }

  def replay(messages, **)
    described_class.load(BenchFixtures.write_session(dir, messages: messages, **))
  end

  describe "a chat session" do
    subject(:chat) { replay(BenchFixtures.chat_messages) }

    it "makes each model entry a request and each user input a turn" do
      expect(chat.requests).to eq([2, 4, 6, 8, 10, 12])
      expect(chat.turns).to eq([1...7, 7...13])
      expect(chat.turn_of(0)).to eq(-1)
      expect(chat.turn_of(9)).to eq(1)
    end

    it "pairs each output with its call by tool_call_id and names it by ToolIds" do
      expect(chat.outputs.map { |o| [o.id, o.name, o.request, o.turn] })
        .to eq([["e3.1", "read", 0, 0], ["e5.1", "execute", 1, 0], ["e9.1", "read", 3, 1], ["e11.1", "edit", 4, 1]])
    end

    it "targets a path relative to its project, a sibling worktree's alike" do
      expect(chat.outputs.first.target.keys).to eq(["lib/cart.rb"])
      expect(chat.outputs[2].target.keys).to eq(["lib/cart.rb"])
      expect(chat.outputs[1].target).to have_attributes(keys: ["spec/cart_spec.rb"],
                                                        command: "bundle exec rspec spec/cart_spec.rb")
    end

    it "keeps the identifiers an output was first to bring in (CartTotals came with the user's message)" do
      expect(chat.outputs.first.new_idents).to contain_exactly("lib/cart.rb", "rounded_total")
      expect(chat.outputs[2].new_idents).to be_empty
    end

    it "counts what a request resends: content and call arguments, never the stored thinking" do
      entry = chat.messages[2]
      expect(chat.entry_tokens(entry)).to eq(JSON.generate(entry[:tool_calls].first[:arguments]).length / 4.0)
    end

    it "shortens the model name past its host prefix" do
      expect(chat.model_name).to eq("acme/coder-1")
    end
  end

  describe "a native session" do
    subject(:native) { replay(BenchFixtures.native_messages, model: "local-qwen") }

    it "reads the calls from the model text and pairs a joined entry's runs with them in order" do
      expect(native.calls.first.map(&:name)).to eq(%w[execute read])
      expect(native.outputs.map { |o| [o.id, o.name, o.run] })
        .to eq([["e3.1", "execute", 0], ["e3.2", "read", 1], ["e7.1", "execute", 0]])
      expect(native.outputs[1].target.keys).to eq(["spec/spec_helper.rb"])
    end

    it "splits the model text into prose, inline thinking and calls" do
      prose, thinking, calls = native.parts(native.messages[2])
      expect([prose, thinking, calls.size]).to eq(["Looking.", "Two calls.", 2])
    end
  end

  describe "re-reads and stubs" do
    def read_result(call_id, tool_id, path, edit: nil)
      entry = BenchFixtures.result(call_id, "[read] #{path}\n1: class Cart\n2: end").merge("tool_ids" => [tool_id])
      entry["edits"] = { tool_id => edit } if edit
      entry
    end

    def edit(kind, applied: true)
      { "kind" => kind, "note" => "Cart is two lines", "by" => "model", "staged_at" => "2026-10-01T10:00:00Z",
        "applied_at" => applied ? "2026-10-01T10:01:00Z" : nil }
    end

    def read_call(id, path) = BenchFixtures.call(id, "read", { "path" => path })

    # t1 lib/cart.rb (stale: t3 superseded it), t2 lib/tax.rb (forgotten
    # at request 3), t3 lib/cart.rb, t4 lib/tax.rb (after the forget),
    # t5 lib/cart.rb (after t1's stale stub).
    let(:messages) do
      [
        { "role" => "system", "content" => "You are a coding agent." },
        BenchFixtures.user("Read the cart and the tax."),
        BenchFixtures.model("", calls: [read_call("c1", "lib/cart.rb")]),
        read_result("c1", "t1", "lib/cart.rb", edit: edit("stale")),
        BenchFixtures.model("", calls: [read_call("c2", "lib/tax.rb")]),
        read_result("c2", "t2", "lib/tax.rb", edit: edit("forget")),
        BenchFixtures.model("", calls: [read_call("c3", "lib/cart.rb")]),
        read_result("c3", "t3", "lib/cart.rb"),
        BenchFixtures.model("", calls: [BenchFixtures.call("c4", "forget_outputs", { "ids" => ["t2"], "note" => "tax is 8%" })]),
        BenchFixtures.result("c4", "[forget_outputs] forgot t2").merge("tool_ids" => ["t4"]),
        BenchFixtures.model("", calls: [read_call("c5", "lib/tax.rb")]),
        read_result("c5", "t5", "lib/tax.rb"),
        BenchFixtures.model("", calls: [read_call("c6", "lib/cart.rb")]),
        read_result("c6", "t6", "lib/cart.rb"),
        BenchFixtures.model("Done.")
      ]
    end

    it "counts re-reads, and those after a stub from the request that caused it, by kind" do
      expect(replay(messages).read_counts.to_h).to eq(reads: 5, re_reads: 3, after_stub: 2, after_forget: 1, after_stale: 1)
    end

    it "counts no stub the session never applied" do
      messages[3]["edits"]["t1"] = edit("stale", applied: false)
      messages[5]["edits"]["t2"] = edit("forget", applied: false)

      expect(replay(messages).read_counts.to_h).to include(re_reads: 3, after_stub: 0)
    end

    it "tallies the applied stubs, their tokens and the forget calls" do
      stubs = replay(messages).stubs

      expect(stubs.to_h).to include(stale: 1, forget: 1, forget_calls: 1)
      expect(stubs.stale_tokens).to be_positive
    end
  end

  describe ".from_dir" do
    it "keeps sessions of two turns or more, heaviest first, up to top" do
      small = BenchFixtures.chat_messages.first(7) + [BenchFixtures.user("ok"), BenchFixtures.model("ok")]
      BenchFixtures.write_session(dir, messages: small, id: "11111111-0000-4000-8000-000000000000")
      BenchFixtures.write_session(dir, messages: BenchFixtures.chat_messages, id: "22222222-0000-4000-8000-000000000000")
      BenchFixtures.write_session(dir, messages: BenchFixtures.chat_messages.first(7), id: "33333333-0000-4000-8000-000000000000")
      File.write(File.join(dir, "notes.json"), "{}")

      expect(described_class.from_dir(dir).map(&:short_id)).to eq(%w[22222222 11111111])
      expect(described_class.from_dir(dir, top: 1).map(&:short_id)).to eq(%w[22222222])
      expect(described_class.from_dir(dir, only: ["1111"]).map(&:short_id)).to eq(%w[11111111])
    end
  end
end
