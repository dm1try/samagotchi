# frozen_string_literal: true

require "samagotchi/tools/memory"
require "tmpdir"
require "fileutils"

RSpec.describe Samagotchi::Tools::MemoryRead do
  let(:project_memories_dir) { Dir.mktmpdir }
  let(:system_memories_dir) { Dir.mktmpdir }

  before do
    stub_const("Samagotchi::Tools::PROJECT_MEMORIES_DIR", project_memories_dir)
    stub_const("Samagotchi::Tools::SYSTEM_MEMORIES_DIR", system_memories_dir)
  end

  after do
    FileUtils.rm_rf(project_memories_dir)
    FileUtils.rm_rf(system_memories_dir)
  end

  describe ".name" do
    it "is 'memory_read'" do
      expect(described_class.name).to eq("memory_read")
    end
  end

  describe ".call" do
    it "reads an existing memory entry" do
      File.write(File.join(project_memories_dir, "notes.md"), "# Notes\nRemember this.")
      expect(described_class.call("notes")).to eq("# Notes\nRemember this.")
    end

    it "returns an error for a missing entry" do
      expect(described_class.call("nonexistent")).to include("Error")
    end

    it "strips whitespace from entry name" do
      File.write(File.join(project_memories_dir, "padded.md"), "content")
      expect(described_class.call("  padded  ")).to eq("content")
    end

    it "reads from system scope when explicitly requested" do
      File.write(File.join(system_memories_dir, "notes.md"), "system-notes")
      expect(described_class.call("notes", scope: "system")).to eq("system-notes")
    end

    it "falls back to system when scope is omitted" do
      File.write(File.join(system_memories_dir, "fallback.md"), "from-system")
      expect(described_class.call("fallback")).to eq("from-system")
    end

    it "prefers project over system when both scopes have the same entry" do
      File.write(File.join(project_memories_dir, "same.md"), "project-version")
      File.write(File.join(system_memories_dir, "same.md"), "system-version")
      expect(described_class.call("same")).to eq("project-version")
    end

    it "returns an error for invalid scope" do
      result = described_class.call("notes", scope: "global")
      expect(result).to include("Error")
      expect(result).to include("invalid scope")
    end

    context "when called with a blank name" do
      it "returns a combined scoped index when scope is omitted" do
        File.write(File.join(project_memories_dir, "index.md"), "- **project**: project notes")
        File.write(File.join(system_memories_dir, "index.md"), "- **system**: system notes")

        result = described_class.call("")
        expect(result).to include("Project memories:")
        expect(result).to include("System memories:")
        expect(result).to include("project notes")
        expect(result).to include("system notes")
      end

      it "returns the scope-specific listing when scope is provided" do
        File.write(File.join(system_memories_dir, "alpha.md"), "a")
        File.write(File.join(system_memories_dir, "beta.md"), "b")
        result = described_class.call("", scope: "system")
        expect(result).to include("alpha")
        expect(result).to include("beta")
        expect(result).to include("no index")
      end

      it "reports no memories when directory is empty" do
        expect(described_class.call("", scope: "project")).to include("No memories")
      end
    end
  end
end

RSpec.describe Samagotchi::Tools::MemoryWrite do
  let(:project_memories_dir) { Dir.mktmpdir }
  let(:system_memories_dir) { Dir.mktmpdir }

  before do
    stub_const("Samagotchi::Tools::PROJECT_MEMORIES_DIR", project_memories_dir)
    stub_const("Samagotchi::Tools::SYSTEM_MEMORIES_DIR", system_memories_dir)
  end

  after do
    FileUtils.rm_rf(project_memories_dir)
    FileUtils.rm_rf(system_memories_dir)
  end

  describe ".name" do
    it "is 'memory_write'" do
      expect(described_class.name).to eq("memory_write")
    end
  end

  describe ".call" do
    it "writes a memory entry to the requested scope and reports success" do
      result = described_class.call("# My Memory\nSome content.", path: "my_memory", scope: "project")
      expect(result).to include("my_memory")
      expect(result).to include("project")
      expect(File.read(File.join(project_memories_dir, "my_memory.md"))).to eq("# My Memory\nSome content.")
    end

    it "overwrites an existing memory entry" do
      File.write(File.join(system_memories_dir, "old.md"), "original")
      described_class.call("updated", path: "old", scope: "system")
      expect(File.read(File.join(system_memories_dir, "old.md"))).to eq("updated")
    end

    it "returns an error when path is blank" do
      result = described_class.call("content", path: "", scope: "project")
      expect(result).to include("Error")
    end

    it "returns an error when scope is missing" do
      result = described_class.call("content", path: "entry", scope: nil)
      expect(result).to include("Error")
      expect(result).to include("scope is required")
    end

    it "reports the number of bytes written" do
      result = described_class.call("hello", path: "greet", scope: "project")
      expect(result).to include("5 bytes")
    end

    it "returns an error when content is empty" do
      result = described_class.call("", path: "entry", scope: "project")
      expect(result).to include("Error")
      expect(result).to include("content is required")
    end

    it "writes the index file when path is 'index'" do
      result = described_class.call("- **notes**: project notes", path: "index", scope: "project")
      expect(result).to include("index")
      expect(File.read(File.join(project_memories_dir, "index.md"))).to eq("- **notes**: project notes")
    end
  end
end
