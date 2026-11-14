# frozen_string_literal: true

require "spec_helper"
require "samagotchi/working_set"

# WorkingSet.timeline_of / .memory_now: an item's runs as the reader shows
# them (docs/internals/working-set.md, Timeline).
RSpec.describe Samagotchi::WorkingSet, ".timeline_of" do
  let(:now) { "2026-11-14T03:00:00.000Z" }
  let(:root) { "/work/shop" }
  let(:head) { { role: "system", content: "You are chi." } }
  let(:cart) { "/work/shop/lib/cart.rb" }
  let(:lines) { (1..40).map { |n| "line #{n}" } }
  let(:diff) { { text: "@@ -1,1 +1,1 @@\n-a\n+b", added: 1, removed: 1, truncated: false, new_file: false } }

  def chat_call(id, name, args) = { id: id, name: name, arguments: args }
  def chat_model(*calls) = { role: "model", content: "", tool_calls: calls }

  def chat_result(id, name, text, tool_id, **extra)
    { role: "tool_response", content: "[#{name}]\n#{text}", tool_call_id: id, tool_ids: [tool_id], **extra }
  end

  def read(id, tool_id, args = {}, text: "#{lines.join("\n")}\n", **extra)
    [chat_model(chat_call(id, "read", { "path" => "lib/cart.rb" }.merge(args))), chat_result(id, "read", text, tool_id, **extra)]
  end

  def edit_run(id, tool_id, diff)
    [chat_model(chat_call(id, "edit", { "path" => cart, "old_text" => "a", "new_text" => "b" })),
     chat_result(id, "edit", "Edited #{cart}", tool_id, tool_diffs: diff)]
  end

  def llm_edit(kind) = { "kind" => kind, "note" => "x", "by" => kind == "drop" ? "user" : "model", "staged_at" => now, "applied_at" => now }

  def timeline(conversation, kind: "file", key: cart, strategy: :none)
    described_class.timeline_of(conversation, kind: kind, key: key, strategy: strategy, cwd: root)
  end

  it "lists every run of the item in conversation order, reads with their lines and edits with their saved diffs" do
    conversation = [head, { role: "user", content: "go" }, *read("c1", "t1"),
                    *read("c2", "t2", { "start_line" => 10, "end_line" => 20 }, text: "#{lines[9..19].join("\n")}\n"),
                    *edit_run("c3", "t3", [diff]),
                    *read("c4", "t4", { "start_line" => 30, "end_line" => 99 },
                          text: "#{lines[29..].join("\n")}\n\n[read: end_line 99 exceeds 40 lines; returning lines 30-40]")]

    events = timeline(conversation).events

    expect(events.map(&:tool_id)).to eq(%w[t1 t2 t3 t4])
    expect(events.map(&:op)).to eq(%w[read read edit read])
    expect(events.map(&:step)).to eq([1, 2, 3, 4])
    expect(events.map { |e| e.lines&.to_h }).to eq([
      { first: 1, last: 40, whole: true, partial: false },
      { first: 10, last: 20, whole: false, partial: false },
      nil,
      { first: 30, last: 40, whole: false, partial: false }
    ])
    expect(events[3].text).not_to include("exceeds")
    expect(events[2].diff).to eq(diff)
    expect(events.map(&:sent)).to all(be(true))
  end

  it "reads a chat entry's bare diff Hash (ToolResponse.single), nil for a no-op edit" do
    conversation = [head, *edit_run("c1", "t1", diff), *edit_run("c2", "t2", nil)]

    expect(timeline(conversation).events.map(&:diff)).to eq([diff, nil])
  end

  it "marks a head/tail preview and a cut output partial, kept as is" do
    preview = "truncated=true\npath=#{cart}\n\n[TRUNCATED_PREVIEW_HEAD]\nline 1\n[... omitted 9 bytes ...]"
    conversation = [head, *read("c1", "t1", text: preview),
                    *read("c2", "t2", { "start_line" => 5 }, text: "line 5\n[cut: 9000 of 20000 chars; read it in parts]")]

    events = timeline(conversation).events

    expect(events.map { |e| e.lines.to_h }).to eq([{ first: nil, last: nil, whole: true, partial: true },
                                                   { first: 5, last: nil, whole: false, partial: true }])
    expect(events.first.text).to eq(preview)
  end

  it "says which reads are dropped and which forgotten, as the projection does" do
    conversation = [head, *read("c1", "t1", edits: { "t1" => llm_edit("drop") }),
                    *read("c2", "t2", edits: { "t2" => llm_edit("forget") }), *read("c3", "t3")]

    forget = timeline(conversation, strategy: %i[forget]).events
    none = timeline(conversation).events

    expect(forget.map { |e| [e.sent, e.dropped, e.forgotten] }).to eq([[false, true, false], [false, false, true], [true, false, false]])
    # The model's forget isn't applied under none; the user's drop always is.
    expect(none.map { |e| [e.sent, e.dropped, e.forgotten] }).to eq([[false, true, false], [true, false, false], [true, false, false]])
  end

  it "has no events for an unknown key and leaves out failed runs" do
    conversation = [head, *read("c1", "t1", text: "Error: file not found: #{cart}")]

    expect(timeline(conversation).events).to be_empty
    expect(timeline(conversation, key: "/elsewhere.rb").events).to be_empty
  end

  describe "memories" do
    let(:dir) { Dir.mktmpdir("ws-timeline") }
    let(:project) { File.join(dir, "memories", "projects", "shop_ab12").tap { |d| FileUtils.mkdir_p(d) } }
    let(:entry) { File.join(project, "style.md").tap { |p| File.write(p, "be brief\n") } }
    let(:overlay) { File.join(project, "style.qwen3.md").tap { |p| File.write(p, "no tables\n") } }
    let(:text) { "be brief\n\n\n---\n\nModel-specific guidance (qwen3):\nno tables\n" }
    let(:stamp) { { memories: { "style" => stamp_of(entry).merge(overlay: stamp_of(overlay)) } } }

    after { FileUtils.rm_rf(dir) }

    def memory_read(id, tool_id, names, text, stamp)
      [chat_model(chat_call(id, "memory_read", { "name" => names })),
       chat_result(id, "memory_read", text, tool_id, tool_stamps: stamp && [stamp])]
    end

    def stamp_of(path) = { path: path, mtime_ns: 1, size: File.size(path) }

    it "says the scope, path and overlay of a read from its stamp, the overlay apart from the text" do
      conversation = [head, *memory_read("c1", "t1", "style", text, stamp)]

      event = timeline(conversation, kind: "memory", key: "style").events.first

      expect(event.op).to eq("memory_read")
      expect(event.memory.to_h).to eq(scope: "project", path: entry, overlay_path: overlay, overlay: "no tables\n")
      expect(event.text).to eq("be brief\n")
      expect(event.to_h[:memory]).to be_a(Hash)
    end

    it "keeps a read of several names whole, naming the others it holds" do
      other = File.join(project, "tone.md").tap { |p| File.write(p, "warm\n") }
      stamps = { memories: { "style" => stamp_of(entry), "tone" => stamp_of(other) } }
      conversation = [head, *memory_read("c1", "t1", "style,tone", "be brief\n\n\n---\n\nwarm\n", stamps)]

      event = timeline(conversation, kind: "memory", key: "style").events.first

      expect(event.text).to eq("be brief\n\n\n---\n\nwarm\n")
      expect(event.shared_with).to eq(["tone"])
    end

    it "has no memory part for a session saved before memory stamps" do
      conversation = [head, *memory_read("c1", "t1", "style", "be brief\n", nil)]

      expect(timeline(conversation, kind: "memory", key: "style").events.first.memory).to be_nil
      expect(described_class.memory_now(conversation, key: "style", strategy: :none, cwd: root, root: File.join(dir, "memories"))).to be_nil
    end

    it "answers what the latest read would answer now, and its diff from what it sent" do
      conversation = [head, *memory_read("c1", "t1", "style", text, stamp)]
      File.write(entry, "be very brief\n")

      found = described_class.memory_now(conversation, key: "style", strategy: :none, cwd: root, root: File.join(dir, "memories"))

      expect(found.text).to eq("be very brief\n\n\n---\n\nModel-specific guidance (qwen3):\nno tables\n")
      expect(found.diff).to include(added: 1, removed: 1, new_file: false)
      expect(found.diff[:text]).to include("+be very brief")
      expect(found.gone).to be(false)
    end

    it "never reads a stamped path outside the memories folder" do
      outside = File.join(dir, "secret.md").tap { |p| File.write(p, "token\n") }
      escaping = { memories: { "style" => stamp_of(entry).merge(path: File.join(project, "..", "..", "..", "secret.md")) } }
      overlay_out = { memories: { "style" => stamp_of(entry).merge(overlay: stamp_of(outside)) } }

      [escaping, overlay_out, { memories: { "style" => stamp_of(outside) } }].each do |stamped|
        conversation = [head, *memory_read("c1", "t1", "style", text, stamped)]
        expect(described_class.memory_now(conversation, key: "style", strategy: :none, cwd: root, root: File.join(dir, "memories"))).to be_nil
      end
    end

    it "says an entry is gone" do
      conversation = [head, *memory_read("c1", "t1", "style", text, stamp)]
      File.delete(entry)

      expect(described_class.memory_now(conversation, key: "style", strategy: :none, cwd: root, root: File.join(dir, "memories")).gone).to be(true)
    end
  end
end
