# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/memory_bundle/index_updater"
require "samagotchi/muted_memories"
require "samagotchi/tools/memory"

# The managed index.md line, with the bundle a memory came from:
# "- **name** · scope · date · bytes · from <bundle> — description".
RSpec.describe Samagotchi::MemoryBundle::IndexUpdater do
  let(:tmpdir) { Dir.mktmpdir("index-updater-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:today) { Date.today.iso8601 }
  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  before { FileUtils.mkdir_p(system_dir) }
  after { FileUtils.rm_rf(tmpdir) }

  def line(name) = File.read(File.join(system_dir, "index.md")).lines.find { |l| l.start_with?("- **#{name}**") }

  it "tags the line with the bundle, before the description" do
    described_class.update_index("system", "guide", 12, "How to", source: "samagotchi-system")
    expect(line("guide")).to eq("- **guide** · system · #{today} · 12 · from samagotchi-system — How to\n")
  end

  it "keeps the tag (and description) when a write passes none, as memory_write and write/edit do" do
    described_class.update_index("system", "guide", 12, "How to", source: "samagotchi-system")
    described_class.update_index("system", "guide", 40)
    expect(line("guide")).to eq("- **guide** · system · #{today} · 40 · from samagotchi-system — How to\n")

    Samagotchi::Tools::MemoryWrite.call("new text", path: "guide", scope: "system", description: "New")
    expect(line("guide")).to eq("- **guide** · system · #{today} · 8 · from samagotchi-system — New\n")
  end

  it "replaces it with another bundle, or drops it with source: false" do
    described_class.update_index("system", "guide", 12, nil, source: "a")
    described_class.update_index("system", "guide", 12, nil, source: "b")
    expect(line("guide")).to eq("- **guide** · system · #{today} · 12 · from b\n")
    described_class.update_index("system", "guide", 12, nil, source: false)
    expect(line("guide")).to eq("- **guide** · system · #{today} · 12\n")
  end

  it "reads the tag only before the description" do
    expect(described_class.extract_source("- **n** · system · 2026-10-03 · 3 · from x — moved · from y")).to eq("x")
    expect(described_class.extract_source("- **n** · system · 2026-10-03 · 3 — taken · from y")).to be_nil
    expect(described_class.extract_source("- **n**: legacy")).to be_nil
  end

  it "is still a managed line to the other readers: the name, the description, the remove pattern" do
    described_class.update_index("system", "guide", 12, "How to", source: "samagotchi-system")
    tagged = line("guide")
    expect(Samagotchi::MutedMemories.index_line_name(tagged)).to eq("guide")
    expect(described_class.extract_description(tagged.chomp)).to eq("How to")
    described_class.remove_index("system", "guide")
    expect(line("guide")).to be_nil
  end
end
