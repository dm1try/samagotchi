# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/memory_bundle/entry_size"

RSpec.describe Samagotchi::MemoryBundle::EntrySize do
  let(:tmpdir) { Dir.mktmpdir("entry-size-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  before { FileUtils.mkdir_p(system_dir) }

  after { FileUtils.rm_rf(tmpdir) }

  def size(tokens) = described_class.new(name: "notes", scope: "system", tokens: tokens)

  it "counts tokens as characters / chars_per_token, rounded up" do
    expect(described_class.of_text("n", "system", "x" * 9, chars_per_token: 4.0).tokens).to eq(3)
    with_env("SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN" => "2") { expect(described_class.of_text("n", "system", "x" * 9).tokens).to eq(5) }
  end

  it "has memory.entry_warn_tokens, 5000 by default, as its limit" do
    expect(described_class.warn_limit).to eq(5000)
    with_env("SAMAGOTCHI_MEMORY_ENTRY_WARN_TOKENS" => "0") { expect(described_class.warn_limit).to eq(0) }
  end

  describe ".crossing_note" do
    it "notes a write that takes a memory from at or under the limit to over it" do
      expect(described_class.crossing_note(size(5000), size(5001), 5000)).to eq(
        "Note: memory 'notes' is now ~5001 tokens (over memory.entry_warn_tokens 5000), paid on each read. When you " \
        "next have a moment, tighten it; split out only parts that are read separately, since each new memory adds " \
        "an index line to every prompt. Don't remove or merge memories unless the user asks."
      )
    end

    it "says nothing while already over, under the limit, on a shrink, with limit 0 or without a measure" do
      expect(described_class.crossing_note(size(6000), size(7000), 5000)).to be_nil
      expect(described_class.crossing_note(size(100), size(400), 5000)).to be_nil
      expect(described_class.crossing_note(size(7000), size(400), 5000)).to be_nil
      expect(described_class.crossing_note(size(0), size(7000), 0)).to be_nil
      expect(described_class.crossing_note(nil, size(7000), 5000)).to be_nil
      expect(described_class.crossing_note(size(0), nil, 5000)).to be_nil
    end
  end

  describe ".measure_file" do
    def memory(name, text = nil)
      File.join(system_dir, "#{name}.md").tap { |path| File.write(path, text) if text }
    end

    it "sizes a memory's file, 0 tokens when it isn't there yet" do
      expect(described_class.measure_file(memory("a", "x" * 40)).to_h).to eq(name: "a", scope: "system", tokens: 10)
      expect(described_class.measure_file(memory("new")).tokens).to eq(0)
    end

    it "is nil for the index, a model note, an overlay, a path outside the memories and the limit 0" do
      memory("a", "x")
      expect(described_class.measure_file(memory("index", "x"))).to be_nil
      expect(described_class.measure_file(memory("model_notes_x", "x"))).to be_nil
      expect(described_class.measure_file(memory("a.qwen", "x"))).to be_nil
      expect(described_class.measure_file(File.join(tmpdir, "a.md"))).to be_nil
      with_env("SAMAGOTCHI_MEMORY_ENTRY_WARN_TOKENS" => "0") { expect(described_class.measure_file(memory("a"))).to be_nil }
    end
  end
end
