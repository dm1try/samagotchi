# frozen_string_literal: true

require "samagotchi/tools/memory"
require "tmpdir"
require "fileutils"

RSpec.describe Samagotchi::Tools::MemoryRead do
  let(:memories_dir) { Dir.mktmpdir }

  before { stub_const("Samagotchi::Tools::MEMORIES_DIR", memories_dir) }
  after  { FileUtils.rm_rf(memories_dir) }

  describe ".name" do
    it "is 'memory_read'" do
      expect(described_class.name).to eq("memory_read")
    end
  end

  describe ".call" do
    it "reads an existing memory entry" do
      File.write(File.join(memories_dir, "notes.md"), "# Notes\nRemember this.")
      expect(described_class.call("notes")).to eq("# Notes\nRemember this.")
    end

    it "returns an error for a missing entry" do
      expect(described_class.call("nonexistent")).to include("Error")
    end

    it "strips whitespace from entry name" do
      File.write(File.join(memories_dir, "padded.md"), "content")
      expect(described_class.call("  padded  ")).to eq("content")
    end

    context "when called with a blank name" do
      it "returns the index file contents when index.md exists" do
        File.write(File.join(memories_dir, "index.md"), "- **notes**: project notes")
        expect(described_class.call("")).to eq("- **notes**: project notes")
      end

      it "falls back to a file listing when index.md does not exist" do
        File.write(File.join(memories_dir, "alpha.md"), "a")
        File.write(File.join(memories_dir, "beta.md"), "b")
        result = described_class.call("")
        expect(result).to include("alpha")
        expect(result).to include("beta")
        expect(result).to include("no index")
      end

      it "reports no memories when directory is empty" do
        expect(described_class.call("")).to include("No memories")
      end
    end
  end
end

RSpec.describe Samagotchi::Tools::MemoryWrite do
  let(:memories_dir) { Dir.mktmpdir }

  before { stub_const("Samagotchi::Tools::MEMORIES_DIR", memories_dir) }
  after  { FileUtils.rm_rf(memories_dir) }

  describe ".name" do
    it "is 'memory_write'" do
      expect(described_class.name).to eq("memory_write")
    end
  end

  describe ".call" do
    it "writes a memory entry and reports success" do
      result = described_class.call("# My Memory\nSome content.", path: "my_memory")
      expect(result).to include("my_memory")
      expect(File.read(File.join(memories_dir, "my_memory.md"))).to eq("# My Memory\nSome content.")
    end

    it "overwrites an existing memory entry" do
      File.write(File.join(memories_dir, "old.md"), "original")
      described_class.call("updated", path: "old")
      expect(File.read(File.join(memories_dir, "old.md"))).to eq("updated")
    end

    it "returns an error when path is blank" do
      result = described_class.call("content", path: "")
      expect(result).to include("Error")
    end

    it "reports the number of bytes written" do
      result = described_class.call("hello", path: "greet")
      expect(result).to include("5 bytes")
    end

    it "writes the index file when path is 'index'" do
      result = described_class.call("- **notes**: project notes", path: "index")
      expect(result).to include("index")
      expect(File.read(File.join(memories_dir, "index.md"))).to eq("- **notes**: project notes")
    end
  end
end
