# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm_context_stale"
require "samagotchi/llm_context_apply"
require "samagotchi/llm_context_view"
require "samagotchi/context_note"
require "samagotchi/kernel_loop"
require "samagotchi/llm/chat_loop"
require "tmpdir"
require_relative "support/fake_chat_adapter"
require_relative "support/test_kernel"

RSpec.describe Samagotchi::LLMContextStale do
  let(:now) { "2026-10-07T18:00:00.000Z" }
  let(:root) { "/work/shop" }
  let(:head) { { role: "system", content: "You are chi." } }
  let(:body) { (1..40).map { |n| "#{n}: line #{n} of the cart" }.join("\n") }

  # Chat format: a model entry with its calls, a result per call.
  def chat_call(id, name, args) = { id: id, name: name, arguments: args }
  def chat_model(*calls) = { role: "model", content: "", tool_calls: calls }

  def chat_result(id, name, text, tool_id)
    { role: "tool_response", content: "[#{name}]\n#{text}", tool_call_id: id, tool_ids: [tool_id] }
  end

  # Native (Qwen XML) format: the calls in the model text, one joined result.
  def qwen_call(name, params)
    body = params.map { |key, value| "<parameter=#{key}>\n#{value}\n</parameter>" }.join("\n")
    "<tool_call>\n<function=#{name}>\n#{body}\n</function>\n</tool_call>"
  end

  def joined(*runs, ids: nil)
    { role: "tool_response", content: runs.map { |name, text| "[#{name}]\n#{text}" }.join("\n\n---\n\n"),
      tool_ids: ids }.compact
  end

  def found(conversation) = described_class.found(conversation, root: root)

  def stubbed(conversation) = found(conversation).to_h { |stale| [stale.run.ref.id, [stale.run.index, stale.note]] }

  describe "chat entries" do
    it "stubs a read a later read of the whole file supersedes, naming what superseded it" do
      conversation = [head, { role: "user", content: "go" },
                      chat_model(chat_call("c1", "read", { "path" => "lib/cart.rb" })),
                      chat_result("c1", "read", body, "t1"),
                      chat_model(chat_call("c2", "read", { "path" => "/work/shop/lib/cart.rb" })),
                      chat_result("c2", "read", body, "t2")]

      expect(stubbed(conversation)).to eq("t1" => [3, "lib/cart.rb: superseded by a later read"])
      expect(found(conversation).first).not_to be_change
    end

    it "keeps a read a later edit or write of the file changed (later read only, user 2026-10-07; edits are P3's)" do
      conversation = [head,
                      chat_model(chat_call("c1", "read", { "path" => "lib/cart.rb", "start_line" => 5, "end_line" => "30" }),
                                 chat_call("c2", "read", { "path" => "lib/tax.rb" })),
                      chat_result("c1", "read", body, "t1"), chat_result("c2", "read", body, "t2"),
                      chat_model(chat_call("c3", "edit", { "path" => "lib/cart.rb", "old_text" => "a", "new_text" => "b" }),
                                 chat_call("c4", "write", { "path" => "lib/tax.rb", "content" => "x" })),
                      chat_result("c3", "edit", "Edited lib/cart.rb", "t3"), chat_result("c4", "write", "Wrote 1 byte", "t4")]

      expect(found(conversation)).to be_empty
      expect(described_class.found(conversation, root: root, changes: true).map { |stale| stale.note })
        .to eq(["lib/cart.rb lines 5-30: superseded by a later edit", "lib/tax.rb: superseded by a later write"])
    end

    it "names a later read as what superseded a read, even after an edit of it, so only a read nothing but a change superseded is a change" do
      conversation = [head,
                      chat_model(chat_call("c1", "read", { "path" => "lib/cart.rb" }), chat_call("c2", "read", { "path" => "lib/tax.rb" })),
                      chat_result("c1", "read", body, "t1"), chat_result("c2", "read", body, "t2"),
                      chat_model(chat_call("c3", "edit", { "path" => "lib/cart.rb", "old_text" => "a", "new_text" => "b" }),
                                 chat_call("c4", "edit", { "path" => "lib/tax.rb", "old_text" => "a", "new_text" => "b" })),
                      chat_result("c3", "edit", "Edited lib/cart.rb", "t3"), chat_result("c4", "edit", "Edited lib/tax.rb", "t4"),
                      chat_model(chat_call("c5", "read", { "path" => "lib/cart.rb" })),
                      chat_result("c5", "read", body, "t5")]

      found = described_class.found(conversation, root: root, changes: true)

      expect(found.map { |stale| [stale.run.ref.id, stale.by.ref.id, stale.change?] }).to eq([["t1", "t5", false], ["t2", "t4", true]])
      expect(found.first.note).to eq("lib/cart.rb: superseded by a later read")
    end

    it "keeps a read only part of a later read covers, or a later read or edit that failed" do
      conversation = [head,
                      chat_model(chat_call("c1", "read", { "path" => "lib/cart.rb", "start_line" => 1, "end_line" => 30 })),
                      chat_result("c1", "read", body, "t1"),
                      chat_model(chat_call("c2", "read", { "path" => "lib/cart.rb", "start_line" => 10 }),
                                 chat_call("c3", "edit", { "path" => "lib/cart.rb", "old_text" => "zz", "new_text" => "b" })),
                      chat_result("c2", "read", body, "t2"),
                      chat_result("c3", "edit", "Error: old text not found in lib/cart.rb", "t3"),
                      chat_model(chat_call("c4", "read", { "path" => "lib/cart.rb" })),
                      chat_result("c4", "read", "Error: file not found: lib/cart.rb", "t4")]

      expect(found(conversation)).to be_empty
    end

    it "stubs a range a later range covers, and never a read with nothing after it" do
      conversation = [head,
                      chat_model(chat_call("c1", "read", { "path" => "lib/cart.rb", "start_line" => 10, "end_line" => 20 })),
                      chat_result("c1", "read", body, "t1"),
                      chat_model(chat_call("c2", "read", { "path" => "lib/cart.rb", "start_line" => 5 })),
                      chat_result("c2", "read", body, "t2")]

      expect(stubbed(conversation)).to eq("t1" => [2, "lib/cart.rb lines 10-20: superseded by a later read"])
    end

    it "takes a call's arguments as a JSON string too, and skips a result whose call isn't in the batch before it" do
      conversation = [head,
                      chat_model(chat_call("c1", "read", '{"path":"lib/cart.rb"}')),
                      chat_result("c1", "read", body, "t1"), chat_result("c9", "read", body, "t2"),
                      chat_model(chat_call("c2", "read", { "path" => "lib/cart.rb" })),
                      chat_result("c2", "read", body, "t3")]

      expect(stubbed(conversation).keys).to eq(%w[t1])
    end

    it "leaves a result whose tool_call_id isn't unique in its batch, or is empty" do
      conversation = [head,
                      chat_model(chat_call("x", "read", { "path" => "lib/a.rb" }), chat_call("x", "read", { "path" => "lib/b.rb" }),
                                 chat_call("", "read", { "path" => "lib/c.rb" })),
                      chat_result("x", "read", body, "t1"), chat_result("x", "read", body, "t2"),
                      chat_result("", "read", body, "t3"),
                      chat_model(chat_call("c4", "read", { "path" => "lib/b.rb" }), chat_call("c5", "read", { "path" => "lib/c.rb" })),
                      chat_result("c4", "read", body, "t4"), chat_result("c5", "read", body, "t5")]

      expect(found(conversation)).to be_empty
    end

    it "takes a later read that came back truncated or cut as covering nothing" do
      preview = "truncated=true\npath=lib/big.rb\npreview_strategy=head_tail\n\n[TRUNCATED_PREVIEW_HEAD]\n#{body}"
      cut = "#{body}\n[cut: 900 of 4000 chars; read it in parts]"
      conversation = [head,
                      chat_model(chat_call("c1", "read", { "path" => "lib/big.rb", "start_line" => 500, "end_line" => 600 }),
                                 chat_call("c2", "read", { "path" => "lib/cart.rb", "start_line" => 1, "end_line" => 10 })),
                      chat_result("c1", "read", body, "t1"), chat_result("c2", "read", body, "t2"),
                      chat_model(chat_call("c3", "read", { "path" => "lib/big.rb" }), chat_call("c4", "read", { "path" => "lib/cart.rb" })),
                      chat_result("c3", "read", preview, "t3"), chat_result("c4", "read", cut, "t4")]

      expect(found(conversation)).to be_empty
    end

    it "leaves a result that doesn't open with its call's lead (a corrected call's ran-as line)" do
      ran_as = chat_result("c1", "read", body, "t1").merge(content: "ran as: read path=lib/cart.rb\n[read]\n#{body}")
      conversation = [head, chat_model(chat_call("c1", "read", { "path" => "lib/crat.rb" })), ran_as,
                      chat_model(chat_call("c2", "read", { "path" => "lib/crat.rb" })),
                      chat_result("c2", "read", body, "t2")]

      expect(found(conversation)).to be_empty
    end

    it "skips a run that already has an edit, and a stub that frees nothing" do
      edited = chat_result("c1", "read", body, "t1")
                 .merge(edits: { "t1" => { "kind" => "forget", "note" => "n", "applied_at" => now } })
      conversation = [head, chat_model(chat_call("c1", "read", { "path" => "lib/cart.rb" }),
                                       chat_call("c2", "read", { "path" => "lib/tax.rb" })),
                      edited, chat_result("c2", "read", "1: x", "t2"),
                      chat_model(chat_call("c3", "read", { "path" => "lib/cart.rb" }),
                                 chat_call("c4", "read", { "path" => "lib/tax.rb" })),
                      chat_result("c3", "read", body, "t3"), chat_result("c4", "read", "1: x", "t4")]

      expect(found(conversation)).to be_empty
    end
  end

  describe "native entries" do
    it "pairs a joined result's runs with the calls in the model text, Qwen and Gemma alike" do
      gemma = "<|tool_call>call:read{path:<|\"|>lib/tax.rb<|\"|>}<tool_call|>"
      conversation = [head, { role: "user", content: "go" },
                      { role: "model", content: "<think>two</think>#{qwen_call("execute", "command" => "ls")}" \
                                                "#{qwen_call("read", "path" => "lib/cart.rb")}" },
                      joined(["execute", "cart.rb"], ["read", body], ids: %w[t1 t2]),
                      { role: "model", content: gemma },
                      joined(["read", body], ids: %w[t3]),
                      { role: "model", content: "#{qwen_call("edit", "path" => "lib/cart.rb", "old_text" => "a",
                                                                      "new_text" => "b")}\n#{qwen_call("read", "path" => "lib/tax.rb")}" },
                      joined(%w[edit ok], ["read", body], ids: %w[t4 t5])]

      expect(stubbed(conversation)).to eq("t3" => [5, "lib/tax.rb: superseded by a later read"])
    end

    it "leaves a joined result whose parts don't open with the batch's call names" do
      fooled = { role: "tool_response", tool_ids: %w[t1 t2],
                 content: "[read]\n#{body}\n\n---\n\nran as: read path=lib/b.rb\n[read]\nb\n\n---\n\n[x] inside b" }
      conversation = [head,
                      { role: "model", content: qwen_call("read", "path" => "lib/cart.rb") + qwen_call("read", "path" => "lib/b.rb") },
                      fooled,
                      { role: "model", content: qwen_call("read", "path" => "lib/cart.rb") },
                      joined(["read", body], ids: %w[t3])]

      expect(found(conversation)).to be_empty
    end

    it "names a legacy entry's run by its derived id, the same with or without the system head" do
      stored = [{ role: "user", content: "go" },
                { role: "model", content: qwen_call("read", "path" => "lib/cart.rb") }, joined(["read", body]),
                { role: "model", content: qwen_call("read", "path" => "lib/cart.rb") }, joined(["read", body])]
      sent = Samagotchi::ContextNote.with_system_head(stored, head)

      expect(stubbed(stored)).to eq("e3.1" => [2, "lib/cart.rb: superseded by a later read"])
      expect(stubbed(sent)).to eq("e3.1" => [3, "lib/cart.rb: superseded by a later read"])
    end
  end

  describe "a turn under stale, edits applied at the next request" do
    let(:stale) do
      Samagotchi::LLMContextStrategy::Resolved.new(layers: [:stale], strategy: [:stale], source: :config, apply: :next_request)
    end
    let(:dir) { Dir.mktmpdir("chi-stale") }
    let(:file) { File.join(dir, "cart.rb").tap { |path| File.write(path, "#{body}\n") } }

    after { FileUtils.remove_entry(dir) }

    def under(kernel, llm_context)
      kernel.turn_settings = Samagotchi::LLM::TurnSettings.none.with(llm_context: llm_context)
      kernel
    end

    describe "the native loop" do
      def prompts(llm_context)
        responses = [qwen_call("read", "path" => file), qwen_call("read", "path" => file), "Done."]
        sent = []
        client = test_client
        allow(client).to receive(:complete) do |prompt, on_chunk: nil, **|
          sent << prompt
          text = responses.shift
          on_chunk&.call(content: text, payload: { "content" => text })
          text
        end
        kernel = under(test_kernel(client: client, profile: Samagotchi::ModelProfile.qwen36), llm_context)
        [kernel.run([head, { role: "user", content: "read it twice" }]), sent]
      end

      it "stubs the first read in the request after the second, and keeps the original in the conversation" do
        result, sent = prompts(stale)

        expect(sent.size).to eq(3)
        expect(sent[1].scan("1: line 1 of the cart").size).to eq(1)
        expect(sent[2]).to include("[read] #{file}: superseded by a later read")
        expect(sent[2].scan("1: line 1 of the cart").size).to eq(1)
        first = result.conversation.find { |entry| entry[:role] == "tool_response" }
        expect(first[:content]).to include("1: line 1 of the cart")
        expect(Samagotchi::LLMContextEdit.on(first).values.map(&:kind)).to eq([:stale])
      end

      it "warms the next turn's prompt with the stubs it will send, on its own copy of the entries" do
        result, = prompts(nil)
        kernel = under(test_kernel(profile: Samagotchi::ModelProfile.qwen36), nil)

        warm, = kernel.warmup_prompt(result.conversation, llm_context: stale)

        expect(warm).to include("[read] #{file}: superseded by a later read")
        expect(result.conversation).to all(satisfy { |entry| !entry.key?(:edits) })
      end

      it "sends every request unchanged under none" do
        result, sent = prompts(nil)

        expect(sent[2].scan("1: line 1 of the cart").size).to eq(2)
        expect(sent[2]).not_to include("superseded")
        expect(result.conversation).to all(satisfy { |entry| !entry.key?(:edits) })
      end
    end

    describe "the chat loop" do
      def requests(llm_context)
        adapter = FakeChatAdapter.new(FakeChatAdapter.tools(["c1", "read", { "path" => file }]),
                                      FakeChatAdapter.tools(["c2", "read", { "path" => file }]),
                                      FakeChatAdapter.text("Done."))
        kernel = under(test_kernel, llm_context)
        Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter)
                                 .complete(messages: [head, { role: "user", content: "read it twice" }], model_name: "m",
                                           max_iterations: 5)
        adapter.requests
      end

      it "sends the superseded read's tool message as the stub, still paired with its call" do
        last = requests(stale).last[:messages]
        first = last.find { |message| message[:role] == "tool" && message[:tool_call_id] == "c1" }

        expect(first[:content]).to eq("[read] #{file}: superseded by a later read")
        expect(last.find { |message| message[:tool_call_id] == "c2" }[:content]).to include("1: line 1 of the cart")
      end

      it "sends the read whole under none" do
        last = requests(nil).last[:messages]

        expect(last.find { |message| message[:tool_call_id] == "c1" }[:content]).to include("1: line 1 of the cart")
      end
    end
  end

  describe ".protected_ids" do
    def read(id, path) = [chat_model(chat_call("c#{id}", "read", { "path" => path })), chat_result("c#{id}", "read", body, "t#{id}")]

    def change(id, path, text = "Edited #{path}")
      [chat_model(chat_call("c#{id}", "edit", { "path" => path, "old_text" => "a", "new_text" => "b" })),
       chat_result("c#{id}", "edit", text, "t#{id}")]
    end

    it "names every read of each file an edit touched in the last steps, a failed edit too" do
      conversation = [head, *read(1, "lib/cart.rb"), *read(2, "lib/cart.rb"), *read(3, "lib/tax.rb"), *read(4, "lib/old.rb"),
                      *change(5, "lib/old.rb"), *change(6, "lib/cart.rb"), *change(7, "lib/tax.rb", "Error: old text not found"),
                      chat_model(chat_call("c8", "read", { "path" => "lib/tax.rb" })),
                      chat_result("c8", "read", "Error: file not found", "t8")]

      expect(described_class.protected_ids(conversation, steps: 3, root: root)).to eq(Set["t1", "t2", "t3", "t8"])
      expect(described_class.protected_ids(conversation, steps: 4, root: root)).to eq(Set["t1", "t2", "t3", "t4", "t8"])
      expect(described_class.protected_ids(conversation, steps: 0, root: root)).to be_empty
    end

    it "keeps an earlier range read of the file as well as the latest one (the edit may be in either)" do
      ranged = lambda do |id, first, last|
        [chat_model(chat_call("c#{id}", "read", { "path" => "lib/a.rb", "start_line" => first, "end_line" => last })),
         chat_result("c#{id}", "read", body, "t#{id}")]
      end
      conversation = [head, *ranged.call(1, 1, 100), *ranged.call(2, 300, 305), *change(3, "lib/a.rb")]

      expect(described_class.protected_ids(conversation, steps: 3, root: root)).to eq(Set["t1", "t2"])
    end

    it "keeps the whole read when the later one came back as a preview or cut (it is the only complete copy)" do
      cut = "#{body}\n[cut: 900 of 4000 chars; read it in parts]"
      conversation = [head, *read(1, "lib/a.rb"),
                      chat_model(chat_call("c2", "read", { "path" => "lib/a.rb" })), chat_result("c2", "read", cut, "t2"),
                      *change(3, "lib/a.rb")]

      expect(described_class.protected_ids(conversation, steps: 3, root: root)).to include("t1")
    end

    it "counts a step per model entry with calls, an answer between none" do
      conversation = [head, *read(1, "lib/cart.rb"), *change(2, "lib/cart.rb"), { role: "model", content: "Done." },
                      { role: "user", content: "next" }, *read(3, "lib/tax.rb"), *read(4, "lib/tax.rb")]

      expect(described_class.protected_ids(conversation, steps: 3, root: root)).to eq(Set["t1"])
      expect(described_class.protected_ids(conversation, steps: 2, root: root)).to be_empty
    end
  end

  describe "applied (LLMContextApply)" do
    def apply!(conversation)
      Samagotchi::LLMContextApply.run!(conversation, layers: [:stale], rule: :next_request, moment: :request, protect_steps: 3,
                                                     root: root, now: now).applied
    end

    it "saves the edits on the entries, which the view under stale sends as stubs, and adds none the second time" do
      conversation = [head, chat_model(chat_call("c1", "read", { "path" => "lib/cart.rb" })),
                      chat_result("c1", "read", body, "t1"),
                      chat_model(chat_call("c2", "read", { "path" => "lib/cart.rb" })),
                      chat_result("c2", "read", body, "t2")]
      original = conversation[2]

      expect(apply!(conversation).map(&:id)).to eq(%w[t1])
      expect(apply!(conversation)).to be_empty

      sent = Samagotchi::LLMContextView.new(strategy: [:stale]).messages(conversation)
      expect(sent[2][:content]).to eq("[read] lib/cart.rb: superseded by a later read")
      expect(Samagotchi::LLMContextView.new.messages(conversation)[2][:content]).to eq("[read]\n#{body}")
      expect(conversation[2]).to equal(original)
      expect(original[:content]).to eq("[read]\n#{body}")
    end
  end
end
