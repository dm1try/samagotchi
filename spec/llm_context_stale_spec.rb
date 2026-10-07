# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm_context_stale"
require "samagotchi/llm_context_view"
require "samagotchi/context_note"

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

  def found(conversation) = described_class.edits(conversation, now: now, root: root)

  def stubbed(conversation) = found(conversation).to_h { |index, edit| [edit.id, [index, edit.note]] }

  describe "chat entries" do
    it "stubs a read a later read of the whole file supersedes, naming what superseded it" do
      conversation = [head, { role: "user", content: "go" },
                      chat_model(chat_call("c1", "read", { "path" => "lib/cart.rb" })),
                      chat_result("c1", "read", body, "t1"),
                      chat_model(chat_call("c2", "read", { "path" => "/work/shop/lib/cart.rb" })),
                      chat_result("c2", "read", body, "t2")]

      expect(stubbed(conversation)).to eq("t1" => [3, "lib/cart.rb: superseded by a later read"])
      expect(found(conversation).first.last).to have_attributes(kind: :stale, by: "chi", staged_at: now, applied_at: now)
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

  describe ".apply!" do
    it "saves the edits on the entries, which the view under stale sends as stubs, and adds none the second time" do
      conversation = [head, chat_model(chat_call("c1", "read", { "path" => "lib/cart.rb" })),
                      chat_result("c1", "read", body, "t1"),
                      chat_model(chat_call("c2", "read", { "path" => "lib/cart.rb" })),
                      chat_result("c2", "read", body, "t2")]
      original = conversation[2]

      expect(described_class.apply!(conversation, now: now, root: root).map(&:id)).to eq(%w[t1])
      expect(described_class.apply!(conversation, now: now, root: root)).to be_empty

      sent = Samagotchi::LLMContextView.new(strategy: [:stale]).messages(conversation)
      expect(sent[2][:content]).to eq("[read] lib/cart.rb: superseded by a later read")
      expect(Samagotchi::LLMContextView.new.messages(conversation)[2][:content]).to eq("[read]\n#{body}")
      expect(conversation[2]).to equal(original)
      expect(original[:content]).to eq("[read]\n#{body}")
    end
  end
end
