# frozen_string_literal: true

require "spec_helper"
require "samagotchi/working_set"

RSpec.describe Samagotchi::WorkingSet do
  let(:now) { "2026-10-22T18:00:00.000Z" }
  let(:root) { "/work/shop" }
  let(:head) { { role: "system", content: "You are chi." } }
  let(:body) { (1..40).map { |n| "#{n}: line #{n} of the cart" }.join("\n") }
  let(:cart) { "/work/shop/lib/cart.rb" }
  let(:tax) { "/work/shop/lib/tax.rb" }
  # The files as they are now, by path: [mtime_ns, size]; a path that
  # isn't here is gone.
  let(:disk) { { cart => [1_000_000_000_500, 900], tax => [2_000_000_000_000, 400] } }
  let(:stat) do
    lambda do |path|
      mtime_ns, size = disk.fetch(path) { raise Errno::ENOENT, path }
      Struct.new(:mtime, :size).new(Time.at(mtime_ns / 1_000_000_000, mtime_ns % 1_000_000_000, :nsec), size)
    end
  end

  def stamp(path, at = disk[path]) = { path: path, mtime_ns: at[0], size: at[1] }

  # Chat format: a model entry with its calls, a result per call.
  def chat_call(id, name, args) = { id: id, name: name, arguments: args }
  def chat_model(*calls) = { role: "model", content: "", tool_calls: calls }

  def chat_result(id, name, text, tool_id, stamp: nil, edits: nil)
    { role: "tool_response", content: "[#{name}]\n#{text}", tool_call_id: id, tool_ids: [tool_id],
      tool_stamps: stamp && [stamp], edits: edits }.compact
  end

  # Native (Qwen XML) format: the calls in the model text, one joined result.
  def qwen_call(name, params)
    lines = params.map { |key, value| "<parameter=#{key}>\n#{value}\n</parameter>" }.join("\n")
    "<tool_call>\n<function=#{name}>\n#{lines}\n</function>\n</tool_call>"
  end

  def qwen_model(*calls) = { role: "model", content: calls.join("\n") }

  def joined(*runs, ids: nil, stamps: nil)
    { role: "tool_response", content: runs.map { |name, text| "[#{name}]\n#{text}" }.join("\n\n---\n\n"),
      tool_ids: ids, tool_stamps: stamps }.compact
  end

  def edit(kind, note, keep: nil, applied: true)
    { "kind" => kind, "note" => note, "by" => kind == "forget" ? "model" : "chi", "staged_at" => now,
      "applied_at" => applied ? now : nil, "keep" => keep }.compact
  end

  def build(conversation, strategy: :none) = described_class.build(conversation, cwd: root, strategy: strategy, stat: stat)

  def states(conversation, **options) = build(conversation, **options).items.to_h { |item| [item.key, item.state] }

  def read_turn(path, id, tool_id, **options)
    [chat_model(chat_call(id, "read", { "path" => path })), chat_result(id, "read", body, tool_id, **options)]
  end

  describe "chat entries" do
    it "lists each file, memory and URL once, in first-seen order, with its ops, count, first id and tokens" do
      conversation = [head, { role: "user", content: "go" },
                      chat_model(chat_call("c1", "read", { "path" => "lib/cart.rb" }),
                                 chat_call("c2", "memory_read", { "name" => "style" }),
                                 chat_call("c3", "web_fetch", { "url" => "https://x.dev/a  b" })),
                      chat_result("c1", "read", body, "t1", stamp: stamp(cart)),
                      chat_result("c2", "memory_read", "be brief", "t2"),
                      chat_result("c3", "web_fetch", "page", "t3"),
                      chat_model(chat_call("c4", "edit", { "path" => cart, "old_text" => "a", "new_text" => "b" }),
                                 chat_call("c5", "memory_write", { "name" => "style", "content" => "x", "scope" => "project" })),
                      chat_result("c4", "edit", "Edited", "t4", stamp: stamp(cart)),
                      chat_result("c5", "memory_write", "Saved", "t5")]

      snapshot = build(conversation)

      expect(snapshot.at).to eq(conversation.size)
      expect(snapshot.items.map(&:to_h)).to eq([
        { kind: "file", key: cart, state: "live", tokens: ((body.length + 7) / 4.0).ceil,
          ops: %w[read edit], count: 2, first_id: "t1" },
        { kind: "memory", key: "style", state: "live", tokens: 6, ops: %w[read write],
          count: 2, first_id: "t2" },
        { kind: "url", key: "https://x.dev/a b", state: "live", tokens: 4, ops: %w[read],
          count: 1, first_id: "t3" }
      ])
    end

    it "is empty for a conversation without tool runs" do
      expect(build([head, { role: "user", content: "hi" }, { role: "model", content: "hello" }])).to be_empty
    end
  end

  describe "native joined entries" do
    it "pairs each run of the batch with its call and reads its stamp by the run's place" do
      conversation = [head, { role: "user", content: "go" },
                      qwen_model(qwen_call("execute", command: "ls"), qwen_call("read", path: "lib/cart.rb"),
                                 qwen_call("read", path: "lib/tax.rb")),
                      joined(%w[execute files], ["read", body], ["read", body], ids: %w[t1 t2 t3],
                                                                                stamps: [nil, stamp(cart), stamp(tax, [1, 400])])]

      expect(states(conversation)).to eq(cart => "live", tax => "stale")
      expect(build(conversation).items.map(&:first_id)).to eq(%w[t2 t3])
    end
  end

  describe "stale" do
    it "is a file whose mtime or size changed since its latest run, or that is gone" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1", stamp: stamp(cart, [1, 900])),
                      *read_turn("lib/tax.rb", "c2", "t2", stamp: stamp(tax, [disk[tax][0], 12])),
                      *read_turn("lib/gone.rb", "c3", "t3", stamp: stamp("/work/shop/lib/gone.rb", [1, 1]))]

      expect(states(conversation)).to eq(cart => "stale", tax => "stale", "/work/shop/lib/gone.rb" => "stale")
    end

    it "is not the model's own edit after its read (the edit stamped the file)" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1", stamp: stamp(cart, [1, 10])),
                      chat_model(chat_call("c2", "edit", { "path" => "lib/cart.rb", "old_text" => "a", "new_text" => "b" })),
                      chat_result("c2", "edit", "Edited", "t2", stamp: stamp(cart))]

      expect(states(conversation)).to eq(cart => "live")
    end

    it "is a file a failed edit changed anyway: the earlier stamp stands" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1", stamp: stamp(cart, [1, 10])),
                      chat_model(chat_call("c2", "edit", { "path" => "lib/cart.rb", "old_text" => "a", "new_text" => "b" })),
                      chat_result("c2", "edit", "Error: old_text not found", "t2")]

      expect(states(conversation)).to eq(cart => "stale")
    end

    it "never comes from a run without a stamp (a session saved before them)" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1"), *read_turn("lib/gone.rb", "c2", "t2")]

      expect(states(conversation)).to eq(cart => "live", "/work/shop/lib/gone.rb" => "live")
    end

    it "reads a stamp saved with string keys (a reloaded session)" do
      saved = { "path" => cart, "mtime_ns" => disk[cart][0], "size" => disk[cart][1] }
      changed = saved.merge("size" => 1)

      expect(states([head, *read_turn("lib/cart.rb", "c1", "t1", stamp: saved)])).to eq(cart => "live")
      expect(states([head, *read_turn("lib/cart.rb", "c1", "t1", stamp: changed)])).to eq(cart => "stale")
    end
  end

  describe "forgotten" do
    let(:forget) { edit("forget", "cart totals are in lib/cart.rb") }

    it "is an item none of whose content outputs is still sent under the current strategy" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1", stamp: stamp(cart), edits: { "t1" => forget })]

      expect(states(conversation, strategy: %i[forget])).to eq(cart => "forgotten")
      expect(build(conversation, strategy: %i[forget]).items.first.tokens).to be < 20
    end

    it "is live again under none: the forget isn't applied there" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1", stamp: stamp(cart), edits: { "t1" => forget })]

      expect(states(conversation, strategy: :none)).to eq(cart => "live")
      expect(build(conversation).items.first.tokens).to eq(((body.length + 7) / 4.0).ceil)
    end

    it "is live while a forget keeps some of its lines" do
      kept = edit("forget", "cart", keep: [[1, 3]])
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1", edits: { "t1" => kept })]

      expect(states(conversation, strategy: %i[forget])).to eq(cart => "live")
    end

    it "is live with another of its reads still sent whole (the forget layer's ids shown)" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1", edits: { "t1" => forget }),
                      *read_turn("lib/cart.rb", "c2", "t2")]

      expect(states(conversation, strategy: %i[stale forget])).to eq(cart => "live")
    end

    it "ignores a staged edit (not applied yet)" do
      staged = edit("forget", "cart", applied: false)
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1", edits: { "t1" => staged })]

      expect(states(conversation, strategy: %i[forget])).to eq(cart => "live")
    end

    it "never comes from a stale stub of an old read a newer one superseded" do
      conversation = [head,
                      *read_turn("lib/cart.rb", "c1", "t1", edits: { "t1" => edit("stale", "lib/cart.rb: superseded by a later read") }),
                      *read_turn("lib/cart.rb", "c2", "t2")]

      expect(states(conversation, strategy: %i[stale])).to eq(cart => "live")
    end

    it "never comes from a stale stub an edit made (llm_context.stale_edits): the model wrote the file" do
      conversation = [head,
                      *read_turn("lib/cart.rb", "c1", "t1", edits: { "t1" => edit("stale", "lib/cart.rb: superseded by a later edit") }),
                      chat_model(chat_call("c2", "edit", { "path" => "lib/cart.rb", "old_text" => "a", "new_text" => "b" })),
                      chat_result("c2", "edit", "Edited", "t2")]

      expect(states(conversation, strategy: %i[stale])).to eq(cart => "live")
    end

    it "never comes to a file only edited or written" do
      conversation = [head, chat_model(chat_call("c1", "write", { "path" => "lib/cart.rb", "content" => "x" })),
                      chat_result("c1", "write", "Wrote", "t1", edits: { "t1" => forget })]

      expect(states(conversation, strategy: %i[forget])).to eq(cart => "live")
      expect(build(conversation, strategy: %i[forget]).items.first.tokens).to eq(0)
    end
  end

  describe "runs left out" do
    it "leaves out failed, denied and interrupted runs" do
      conversation = [head, chat_model(chat_call("c1", "read", { "path" => "lib/a.rb" }),
                                       chat_call("c2", "read", { "path" => "lib/b.rb" }),
                                       chat_call("c3", "read", { "path" => "lib/c.rb" })),
                      chat_result("c1", "read", "Error: no such file", "t1"),
                      { role: "tool_response", content: "[read] Error: denied by the user", tool_call_id: "c2", tool_ids: ["t2"] },
                      { role: "tool_response", content: Samagotchi::ToolResponse.interrupted_text("read"), tool_call_id: "c3",
                        tool_ids: ["t3"] }]

      expect(build(conversation)).to be_empty
    end

    it "keeps a partial memory_read's found names and drops the missing ones" do
      conversation = [head, chat_model(chat_call("c1", "memory_read", { "name" => "style, tone,gone" })),
                      chat_result("c1", "memory_read", "be brief\n\n---\n\nbe kind\n\n---\n\nError: memory not found: gone", "t1")]

      expect(build(conversation).items.map(&:key)).to eq(%w[style tone])
    end

    it "lists no memory for an index listing (an empty name)" do
      conversation = [head, chat_model(chat_call("c1", "memory_read", { "name" => "" })),
                      chat_result("c1", "memory_read", "Project memories:", "t1")]

      expect(build(conversation)).to be_empty
    end

    it "keeps a memory_write that removes its entry, op write" do
      conversation = [head, chat_model(chat_call("c1", "memory_write", { "name" => "old", "scope" => "project", "remove" => true })),
                      chat_result("c1", "memory_write", "Removed old", "t1")]

      expect(build(conversation).items.map(&:to_h)).to eq([{ kind: "memory", key: "old", state: "live", tokens: 0, ops: %w[write],
                                                             count: 1, first_id: "t1" }])
    end
  end

  it "builds a 500-message session in well under a second" do
    turns = (1..125).flat_map do |n|
      path = "lib/f#{n % 30}.rb"
      [{ role: "user", content: "step #{n}" },
       qwen_model(qwen_call("read", path: path), qwen_call("execute", command: "ls")),
       joined(["read", body], %w[execute files], ids: ["t#{(2 * n) - 1}", "t#{2 * n}"],
                                                 stamps: [stamp("#{root}/#{path}", [n, 900]), nil]),
       { role: "model", content: "done #{n}" }]
    end
    conversation = [head, *turns]
    expect(conversation.size).to be > 500
    build(conversation, strategy: %i[stale forget])

    # The best of three: a parallel suite's load is not the build's cost.
    elapsed_ms = Array.new(3) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      build(conversation, strategy: %i[stale forget])
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    end.min

    expect(build(conversation).items.size).to eq(30)
    # A guard against a blow-up (a quadratic walk), not a benchmark: ~10 ms
    # on an M5 Ultra, ~75 ms on a CI runner.
    expect(elapsed_ms).to be < 400
  end
end
