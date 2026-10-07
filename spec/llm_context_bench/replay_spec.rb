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
