# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/working_set"
require "samagotchi/memory_paths"

# A `read` or `edit` of a file inside a memories dir is a touch of that memory,
# not of the file: the row is the memory's, keyed by its name
# (docs/internals/working-set.md, "Items"). The mapping is MemoryUsage's, so
# an overlay's file counts as its base entry.
RSpec.describe "a run on a memory's file" do
  let(:memories) { Dir.mktmpdir("ws-memory-paths") }

  before do
    allow(Samagotchi::MemoryPaths).to receive(:system_dir).and_return(memories)
    allow(Samagotchi::MemoryPaths).to receive(:project_dir).and_return(File.join(memories, "project"))
    File.write(File.join(memories, "notes.md"), "a\n")
    File.write(File.join(memories, "notes.test-model.md"), "overlay\n")
  end

  after { FileUtils.rm_rf(memories) }

  def stamp(path)
    stat = File.stat(path)
    { path: path, mtime_ns: (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec, size: stat.size }
  end

  def edit_turn(path, id, tool_id, stamp: nil)
    [
      { role: "model", content: "", tool_calls: [{ id: id, name: "edit", arguments: { "path" => path, "old_text" => "a", "new_text" => "b" } }] },
      { role: "tool_response", content: "[edit]\nEdited", tool_call_id: id, tool_ids: [tool_id], tool_stamps: [stamp] }.compact
    ]
  end

  def build(conversation)
    Samagotchi::WorkingSet.build([{ role: "system", content: "You are chi." }, *conversation], cwd: memories, strategy: :none)
  end

  it "is the memory's row, not a file row" do
    items = build(edit_turn(File.join(memories, "notes.md"), "c1", "t1", stamp: stamp(File.join(memories, "notes.md")))).items

    expect(items.map { |item| [item.kind, item.key, item.ops] }).to eq([["memory", "notes", ["write"]]])
  end

  it "counts a model overlay's file as the memory it overlays" do
    items = build(edit_turn(File.join(memories, "notes.test-model.md"), "c1", "t1",
                            stamp: stamp(File.join(memories, "notes.test-model.md")))).items

    expect(items.map { |item| [item.kind, item.key] }).to eq([%w[memory notes]])
  end

  it "is stale when that file moved after the run" do
    path = File.join(memories, "notes.md")
    conversation = edit_turn(path, "c1", "t1", stamp: stamp(path))
    File.write(path, "changed by someone else")

    expect(build(conversation).items.map(&:state)).to eq(["stale"])
  end

  it "is a plain file when the path is not in a memories dir" do
    other = File.join(memories, "sub", "notes.md")
    FileUtils.mkdir_p(File.dirname(other))
    File.write(other, "a file in a subfolder, not a memory")

    items = build(edit_turn(other, "c1", "t1", stamp: stamp(other))).items

    expect(items.map { |item| [item.kind, item.key, item.state] }).to eq([["file", other, "live"]])
  end

  it "counts a `read` of the memory's file as a read of the memory" do
    path = File.join(memories, "notes.md")
    conversation = [
      { role: "model", content: "", tool_calls: [{ id: "c1", name: "read", arguments: { "path" => path } }] },
      { role: "tool_response", content: "[read]\na\n", tool_call_id: "c1", tool_ids: ["t1"], tool_stamps: [stamp(path)] }
    ]

    items = build(conversation).items
    expect(items.map { |item| [item.kind, item.key, item.ops] }).to eq([["memory", "notes", ["read"]]])
    expect(items.first.tokens).to eq(("[read]\na\n".length / Samagotchi::TokenUsage::CHARS_PER_TOKEN).ceil)
  end

  it "is not the memory when the name is the index" do
    index = File.join(memories, "index.md")
    File.write(index, "- **notes** · system\n")

    items = build(edit_turn(index, "c1", "t1", stamp: stamp(index))).items

    expect(items.map { |item| [item.kind, item.key] }).to eq([["file", index]])
  end
end
