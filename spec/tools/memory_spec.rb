# frozen_string_literal: true

require "samagotchi/tools/memory"
require "tmpdir"

RSpec.describe Samagotchi::Tools::MemoryRead do
  around do |example|
    Dir.mktmpdir do |dir|
      original = Samagotchi::Tools::MEMORIES_DIR
      stub_const("Samagotchi::Tools::MEMORIES_DIR", dir)
      example.run
      stub_const("Samagotchi::Tools::MEMORIES_DIR", original)
    end
  end

  describe ".name" do
    it "is 'memory_read'" do
      expect(described_class.name).to eq("memory_read")
    end
  end

  describe ".call" do
    it "reads an existing memory entry" do
      dir = Samagotchi::Tools::MEMORIES_DIR
      File.write(File.join(dir, "notes.md"), "# Notes\nRemember this.")
      expect(described_class.call("notes")).to eq("# Notes\nRemember this.")
    end

    it "returns an error for a missing entry" do
      expect(described_class.call("nonexistent")).to include("Error")
    end

    it "lists all memories when called with a blank name" do
      dir = Samagotchi::Tools::MEMORIES_DIR
      File.write(File.join(dir, "alpha.md"), "a")
      File.write(File.join(dir, "beta.md"), "b")
      result = described_class.call("")
      expect(result).to include("alpha")
      expect(result).to include("beta")
    end

    it "reports no memories when directory is empty" do
      expect(described_class.call("")).to include("No memories")
    end

    it "strips whitespace from entry name" do
      dir = Samagotchi::Tools::MEMORIES_DIR
      File.write(File.join(dir, "padded.md"), "content")
      expect(described_class.call("  padded  ")).to eq("content")
    end
  end
end

RSpec.describe Samagotchi::Tools::MemoryWrite do
  around do |example|
    Dir.mktmpdir do |dir|
      stub_const("Samagotchi::Tools::MEMORIES_DIR", dir)
      example.run
    end
  end

  describe ".name" do
    it "is 'memory_write'" do
      expect(described_class.name).to eq("memory_write")
    end
  end

  describe ".call" do
    it "writes a memory entry and reports success" do
      result = described_class.call("# My Memory\nSome content.", path: "my_memory")
      expect(result).to include("my_memory")
      path = File.join(Samagotchi::Tools::MEMORIES_DIR, "my_memory.md")
      expect(File.read(path)).to eq("# My Memory\nSome content.")
    end

    it "overwrites an existing memory entry" do
      dir = Samagotchi::Tools::MEMORIES_DIR
      File.write(File.join(dir, "old.md"), "original")
      described_class.call("updated", path: "old")
      expect(File.read(File.join(dir, "old.md"))).to eq("updated")
    end

    it "returns an error when path is blank" do
      result = described_class.call("content", path: "")
      expect(result).to include("Error")
    end

    it "reports the number of bytes written" do
      result = described_class.call("hello", path: "greet")
      expect(result).to include("5 bytes")
    end
  end
end
