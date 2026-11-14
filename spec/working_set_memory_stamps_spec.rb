# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "samagotchi/tool_runner"
require "samagotchi/tools/builtins"
require "samagotchi/tool_response"
require "samagotchi/working_set"
require "samagotchi/memory_paths"
require "support/test_kernel"

# A memory the model read, and its file changed on disk since: the working set
# says stale, as a file does (docs/internals/working-set.md, "Stamps"). The
# read is the real one - the kernel dispatch reaches Tools::MemoryRead - so the
# stamp records the file that actually answered, and the overlay read with it.
RSpec.describe "a memory's stamp in the working set" do
  let(:registry) { Samagotchi::Tools::Builtins.registry }
  let(:memories) { Dir.mktmpdir("ws-memory-stamps") }
  let(:memory_file) { File.join(memories, "notes.md") }
  let(:events) { [] }

  before do
    allow(Samagotchi::MemoryPaths).to receive(:system_dir).and_return(memories)
    allow(Samagotchi::MemoryPaths).to receive(:project_dir).and_return(File.join(memories, "project"))
    File.write(memory_file, "the text chi read")
  end

  after { FileUtils.rm_rf(memories) }

  def read(names, model_key: nil)
    kernel = test_kernel(tools: registry)
    Samagotchi::ToolRunner.new(kernel).run({ name: "memory_read", content: names, scope: "system" },
                                           context: run_context(tools: registry, cwd: memories, model_key: model_key),
                                           iteration: 1, call_index: 1, call_count: 1,
                                           on_stream_event: ->(event) { events << event },
                                           max_tool_output_chars: nil)
  end

  # The chat loop's conversation for one memory_read call.
  def conversation(run)
    [
      { role: "system", content: "You are chi." },
      { role: "model", content: "", tool_calls: [{ id: "c1", name: "memory_read", arguments: { "name" => "notes" } }] },
      Samagotchi::ToolResponse.single(run, tool_call_id: "c1", ids: ["t1"])
    ]
  end

  def state(conversation)
    Samagotchi::WorkingSet.build(conversation, cwd: memories, strategy: :none).items.to_h { |item| [item.key, item.state] }
  end

  def stat(file)
    File.stat(file)
  end

  it "is stale when the memory's file changed after the read that answered it" do
    run = read("notes")
    expect(run.output).to eq("[memory_read]\nthe text chi read")

    File.write(memory_file, "the text changed on disk")

    expect(state(conversation(run))).to eq("notes" => "stale")
  end

  it "is live while the file is what the read returned" do
    expect(state(conversation(read("notes")))).to eq("notes" => "live")
  end

  it "is stale when the model overlay read with it changed" do
    overlay = File.join(memories, "notes.test-model.md")
    File.write(overlay, "overlay guidance")
    run = read("notes", model_key: "test-model")
    expect(run.output).to include("Model-specific guidance (test-model):")

    File.write(overlay, "overlay guidance changed")

    expect(state(conversation(run))).to eq("notes" => "stale")
  end

  it "is stale when the memory is gone" do
    run = read("notes")
    File.delete(memory_file)

    expect(state(conversation(run))).to eq("notes" => "stale")
  end

  it "is never stale for a session saved without memory stamps (compat N-1)" do
    conversation = [
      { role: "system", content: "You are chi." },
      { role: "model", content: "", tool_calls: [{ id: "c1", name: "memory_read", arguments: { "name" => "notes" } }] },
      { role: "tool_response", content: "[memory_read]\nthe text chi read", tool_call_id: "c1", tool_ids: ["t1"] }
    ]
    File.write(memory_file, "changed since")

    expect(state(conversation)).to eq("notes" => "live")
  end

  describe "the stamp" do
    it "is one entry per name, with the file that answered and its mtime" do
      File.write(File.join(memories, "other.md"), "second")
      stamp = read("notes,other").stamp[:memories]

      expect(stamp.keys).to eq(%w[notes other])
      expect(stamp["notes"]).to eq({ path: memory_file,
                                     mtime_ns: (stat(memory_file).mtime.to_i * 1_000_000_000) + stat(memory_file).mtime.nsec,
                                     size: File.size(memory_file) })
      expect(stamp["other"]).not_to have_key(:overlay)
    end

    it "carries the overlay's stamp when one was read with the entry" do
      overlay = File.join(memories, "notes.test-model.md")
      File.write(overlay, "overlay guidance")
      entry = read("notes", model_key: "test-model").stamp[:memories]["notes"]

      expect(entry[:overlay]).to eq({ path: overlay,
                                      mtime_ns: (stat(overlay).mtime.to_i * 1_000_000_000) + stat(overlay).mtime.nsec,
                                      size: File.size(overlay) })
    end

    it "has no mtime at its top, so a reader that knows only file stamps sees none" do
      stamp = read("notes").stamp

      expect(stamp.key?(:mtime_ns)).to be(false)
      expect(Samagotchi::WorkingSet.send(:stamp_of, { tool_stamps: [stamp] }, 0)).to be_nil
    end

    it "is nil for the index listing and for a read that found nothing" do
      expect(read("").stamp).to be_nil
      expect(read("nope").stamp).to be_nil
    end

    it "is saved with the result, never sent to the model" do
      entry = Samagotchi::ToolResponse.single(read("notes"), tool_call_id: "c1", ids: ["t1"])

      expect(entry[:tool_stamps]).to be_a(Array)
      expect(entry.except(*Samagotchi::ToolResponse::SAVED_KEYS).keys).to eq([:role, :content, :tool_call_id])
    end

    it "still works read back from a session file (string keys)" do
      run = read("notes")
      entry = JSON.parse(JSON.generate(Samagotchi::ToolResponse.single(run, tool_call_id: "c1", ids: ["t1"]))).transform_keys(&:to_sym)
      File.write(memory_file, "changed")

      expect(state(conversation_with(entry))).to eq("notes" => "stale")
    end
  end

  def conversation_with(entry)
    [
      { role: "system", content: "You are chi." },
      { role: "model", content: "", tool_calls: [{ id: "c1", name: "memory_read", arguments: { "name" => "notes" } }] },
      entry
    ]
  end
end
