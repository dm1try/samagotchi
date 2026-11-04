# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "samagotchi/memory_bundle/installer"

RSpec.describe Samagotchi::MemoryBundle::Merger do
  let(:tmp) { Dir.mktmpdir("samagotchi-merger-") }

  around { |example| with_config_home(File.join(tmp, "config")) { example.run } }

  after { FileUtils.rm_rf(tmp) }

  # The outcome for a base, current and incoming text (nil: no such file).
  def classify(base, current, incoming)
    paths = { base: base, current: current, incoming: incoming }.to_h do |side, text|
      path = File.join(tmp, side.to_s)
      File.write(path, text) if text
      [:"#{side}_path", path]
    end
    described_class.classify(**paths)
  end

  describe ".classify" do
    {
      "a file not on disk" => [["b", nil, "i"], :install, :on_disk],
      "a file not edited" => [%w[b b i], :fast_forward, :on_disk],
      "a file that has the bundle's bytes" => [%w[b i i], :noop, :on_disk],
      "an edit the bundle didn't change" => [%w[b c b], :keep, :recorded],
      "an edit the bundle changed too" => [%w[b c i], :conflict, :recorded],
      "an edit with no base" => [[nil, "c", "i"], :conflict, :recorded],
      "no base, the bundle's bytes" => [[nil, "i", "i"], :noop, :on_disk],
      "a file the bundle doesn't have" => [["b", "c", nil], :noop, :recorded]
    }.each do |what, (texts, status, base)|
      it "reads #{what} as #{status}, its next base #{base}" do
        expect(classify(*texts)).to have_attributes(status: status, base: base)
      end
    end
  end

  describe Samagotchi::MemoryBundle::Merger::Upgrade do
    let(:upgrade) do
      provenance = Samagotchi::MemoryBundle::Provenance.new(name: "demo")
      FileUtils.mkdir_p([File.join(provenance.bundle_dir, "bases"), File.join(tmp, "target"), File.join(tmp, "source")])
      described_class.new(provenance: provenance, target_dir: File.join(tmp, "target"), source_dir: File.join(tmp, "source"))
    end

    def sides(key, base:, current:, incoming:)
      { base: base, current: current, incoming: incoming }.each do |side, text|
        File.write(upgrade.paths(key)[side], text)
      end
    end

    it "names a file's three sides" do
      expect(upgrade.paths("a.md")).to eq(base: upgrade.provenance.base_path("a.md"), current: File.join(tmp, "target/a.md"),
                                          incoming: File.join(tmp, "source/a.md"))
    end

    it "answers for one file and picks the conflicts of the files asked about, writing nothing" do
      sides("edited.md", base: "b\n", current: "c\n", incoming: "i\n")
      sides("plain.md", base: "b\n", current: "b\n", incoming: "i\n")
      sides("kept.md", base: "b\n", current: "c\n", incoming: "b\n")
      sides("unasked.md", base: "b\n", current: "c\n", incoming: "i\n")

      expect(upgrade.outcome("plain.md")).to eq(Samagotchi::MemoryBundle::Merger::FAST_FORWARD)
      expect(upgrade.conflicts(%w[edited.md kept.md plain.md])).to eq(%w[edited.md])
      expect(File.read(upgrade.paths("plain.md")[:current])).to eq("b\n")
    end
  end

  # What each outcome's base means for the record, end to end.
  describe "the next base" do
    let(:source) { File.join(tmp, "src") }
    let(:memories) { Samagotchi::MemoryPaths.system_dir }
    let(:provenance) { Samagotchi::MemoryBundle::Provenance.new(name: "demo") }

    def install(version, text, **opts)
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "a.md"), text)
      File.write(File.join(source, "manifest.yml"),
                 YAML.dump({ "name" => "demo", "version" => version, "scope" => "system", "files" => { "a.md" => "sha256:fake" } }))
      Samagotchi::MemoryBundle::Installer.new(source: source, name: "demo", strict: false, **opts).tap(&:run)
    end

    def base_text = File.read(provenance.base_path("a.md"))

    before do
      install("1.0.0", "v1\n")
    end

    it "moves to the bundle's text on a fast-forward" do
      install("2.0.0", "v2\n", upgrade: true)
      expect(base_text).to eq("v2\n")
    end

    it "moves to the bundle's text when an edit already matches it" do
      File.write(File.join(memories, "a.md"), "v2\n")
      install("2.0.0", "v2\n", upgrade: true)
      expect(base_text).to eq("v2\n")
    end

    it "moves to the bundle's text when it puts back a deleted file" do
      FileUtils.rm(File.join(memories, "a.md"))
      install("2.0.0", "v2\n", upgrade: true)
      expect(base_text).to eq("v2\n")
    end

    it "moves to the bundle's text under --force" do
      File.write(File.join(memories, "a.md"), "edit\n")
      install("2.0.0", "v2\n", upgrade: true, force: true)
      expect(base_text).to eq("v2\n")
    end

    it "stays on a kept edit" do
      File.write(File.join(memories, "a.md"), "edit\n")
      install("2.0.0", "v1\n", upgrade: true)
      expect(base_text).to eq("v1\n")
    end

    it "stays on a conflict" do
      File.write(File.join(memories, "a.md"), "edit\n")
      install("2.0.0", "v2\n", upgrade: true)
      expect(base_text).to eq("v1\n")
    end

    # An outcome the Installer has no code for fails loudly: quietly, the base
    # would move on with nothing written, and the miss would be buried.
    def classify_as(status, base)
      allow(described_class).to receive(:classify).and_return(described_class::Outcome.new(status: status, base: base))
    end

    it "refuses a status merge_memory has no branch for, with nothing moved" do
      File.write(File.join(memories, "a.md"), "edit\n")
      classify_as(:unheard_of, :on_disk)

      expect { install("2.0.0", "v2\n", upgrade: true) }.to raise_error(ArgumentError, "unknown outcome status :unheard_of for a.md")
      expect(base_text).to eq("v1\n")
      expect(provenance.record.version).to eq("1.0.0")
      expect(File.read(File.join(memories, "a.md"))).to eq("edit\n")
    end

    it "refuses a base next_base doesn't know, with the record unmoved" do
      File.write(File.join(memories, "a.md"), "edit\n")
      classify_as(:keep, :unheard_of)

      expect { install("2.0.0", "v1\n", upgrade: true) }.to raise_error(ArgumentError, "unknown base :unheard_of for a.md")
      expect(base_text).to eq("v1\n")
      expect(provenance.record.version).to eq("1.0.0")
    end
  end
end
