# frozen_string_literal: true

require "samagotchi/tools/memory"
require "tmpdir"
require "fileutils"
require "date"

RSpec.describe Samagotchi::Tools::MemoryRead do
  let(:project_memories_dir) { Dir.mktmpdir }
  let(:system_memories_dir) { Dir.mktmpdir }

  before do
    allow(Samagotchi::MemoryPaths).to receive(:project_dir).and_return(project_memories_dir)
    allow(Samagotchi::MemoryPaths).to receive(:system_dir).and_return(system_memories_dir)
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

  describe "names with a path in them" do
    it "refuses them instead of reading outside the memories" do
      outside = File.join(File.dirname(project_memories_dir), "secret.md")
      File.write(outside, "outside")
      name = "../#{File.basename(outside, ".md")}"
      expect(described_class.call(name, scope: "project")).to eq("Error: invalid memory name '#{name}': use a plain name (no /, \\ or ..)")
      expect(described_class.call("notes, a/b")).to start_with("Error: invalid memory name 'a/b'")
      expect(described_class.call("a\\b")).to start_with("Error: invalid memory name")
    ensure
      FileUtils.rm_f(outside)
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

    context "comma-separated multi-value support" do
      it "reads multiple entries and concatenates with separator" do
        File.write(File.join(project_memories_dir, "one.md"), "content-one")
        File.write(File.join(project_memories_dir, "two.md"), "content-two")
        result = described_class.call("one, two")
        expected = "content-one" + "\n\n---\n\n" + "content-two"
        expect(result).to eq(expected)
      end

      it "handles mixed found and missing entries" do
        File.write(File.join(project_memories_dir, "found.md"), "found-content")
        result = described_class.call("found, missing-entry")
        expect(result).to include("found-content")
        expect(result).to include("Error: memory not found: missing-entry")
      end

      it "returns combined error when all entries are missing" do
        result = described_class.call("missing-a, missing-b")
        expect(result).to eq("Error: memory not found: missing-a, missing-b")
      end

      it "skips blank entries in the list" do
        File.write(File.join(project_memories_dir, "one.md"), "content-one")
        File.write(File.join(project_memories_dir, "two.md"), "content-two")
        result = described_class.call("one,, ,two")
        expected = "content-one" + "\n\n---\n\n" + "content-two"
        expect(result).to eq(expected)
      end

      it "reads the same entry twice when listed twice (no dedup)" do
        File.write(File.join(project_memories_dir, "dup.md"), "dup-content")
        result = described_class.call("dup, dup")
        expected = "dup-content" + "\n\n---\n\n" + "dup-content"
        expect(result).to eq(expected)
      end

      it "respects scope: all names are searched only in the given scope" do
        File.write(File.join(project_memories_dir, "only-proj.md"), "project-only")
        File.write(File.join(system_memories_dir, "only-sys.md"), "system-only")
        result = described_class.call("only-proj, only-sys", scope: "project")
        expect(result).to include("project-only")
        expect(result).to include("Error: memory not found: only-sys")
      end

      it "falls back per-entry when scope is omitted" do
        File.write(File.join(project_memories_dir, "a.md"), "project-a")
        File.write(File.join(system_memories_dir, "b.md"), "system-b")
        result = described_class.call("a, b")
        expected = "project-a" + "\n\n---\n\n" + "system-b"
        expect(result).to eq(expected)
      end

      it "returns error for only-blank list" do
        result = described_class.call("  ,  ,  ")
        expect(result).to eq("Error: no memory names provided")
      end

      it "single name behaves identically to pre-change behavior" do
        File.write(File.join(project_memories_dir, "single.md"), "single-content")
        expect(described_class.call("single")).to eq("single-content")
      end
    end
  end
end

RSpec.describe Samagotchi::Tools::MemoryWrite do
  let(:project_memories_dir) { Dir.mktmpdir }
  let(:system_memories_dir) { Dir.mktmpdir }

  before do
    allow(Samagotchi::MemoryPaths).to receive(:project_dir).and_return(project_memories_dir)
    allow(Samagotchi::MemoryPaths).to receive(:system_dir).and_return(system_memories_dir)
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

  describe "names with a path in them" do
    it "refuses them and writes nothing (../../x wrote x.md outside the memories)" do
      parent = File.dirname(project_memories_dir)
      escaped = "escaped-#{File.basename(project_memories_dir)}"
      ["../#{escaped}", "a/b", "a\\b", ".."].each do |name|
        expect(described_class.call("x", path: name, scope: "project")).to start_with("Error: invalid memory name")
      end
      expect(File.exist?(File.join(parent, "#{escaped}.md"))).to be(false)
      expect(Dir.children(project_memories_dir)).to eq([])
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

    it "includes the entry file path in the success message" do
      result = described_class.call("hello", path: "greet", scope: "project")
      expect(result).to include("File written:")
      expect(result).to include(File.join(project_memories_dir, "greet.md"))
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
      # verbatim index write must not trigger upsert / header injection
      expect(result).not_to include("Index line refreshed")
      expect(File.read(File.join(project_memories_dir, "index.md"))).not_to include("auto-maintained")
    end

    describe "auto-maintained index" do
      def managed_line_for(index_contents, name)
        index_contents.lines.find { |l| l.start_with?("- **#{name}**") }
      end

      it "creates index.md with a header and exactly one managed line on first write" do
        described_class.call("Note", path: "notes", scope: "project")
        index_path = File.join(project_memories_dir, "index.md")
        expect(File.exist?(index_path)).to be true
        contents = File.read(index_path)
        expect(contents).to include("auto-maintained")
        expect(contents.lines.count { |l| l.start_with?("- **notes**") }).to eq(1)
        line = managed_line_for(contents, "notes")
        expect(line).to eq("- **notes** · project · #{Date.today.iso8601} · #{'Note'.bytesize}\n")
      end

      it "omits the description segment when none is supplied" do
        described_class.call("Note", path: "notes", scope: "project")
        line = managed_line_for(File.read(File.join(project_memories_dir, "index.md")), "notes")
        expect(line).not_to include("—")
      end

      it "appends the description when supplied" do
        described_class.call("content", path: "todo", scope: "project", description: "quick todos")
        line = managed_line_for(File.read(File.join(project_memories_dir, "index.md")), "todo")
        expect(line).to end_with("quick todos\n")
      end

      it "upserts an existing managed line in place (no duplicate) and refreshes size" do
        described_class.call("old", path: "note", scope: "project")
        described_class.call("a much longer content", path: "note", scope: "project")
        contents = File.read(File.join(project_memories_dir, "index.md"))
        lines = contents.lines.select { |l| l.start_with?("- **note**") }
        expect(lines.size).to eq(1)
        expect(lines.first).to eq("- **note** · project · #{Date.today.iso8601} · #{'a much longer content'.bytesize}\n")
      end

      it "appends a new managed line without disturbing existing ones" do
        described_class.call("one", path: "alpha", scope: "project")
        before = File.read(File.join(project_memories_dir, "index.md"))
        described_class.call("two", path: "beta", scope: "project")
        after = File.read(File.join(project_memories_dir, "index.md"))
        expect(after.lines.count { |l| l.start_with?("- **alpha**") }).to eq(1)
        expect(after).to include(before.lines.find { |l| l.start_with?("- **alpha**") })
        expect(after).to include("- **beta**")
      end

      it "preserves hand-written free-form sections when adding a managed line" do
        File.write(File.join(project_memories_dir, "index.md"), "## Custom Notes\nSome hand-written text.\n")
        described_class.call("x", path: "xentry", scope: "project")
        contents = File.read(File.join(project_memories_dir, "index.md"))
        expect(contents).to include("## Custom Notes\nSome hand-written text.\n")
        expect(contents).to include("- **xentry**")
      end

      it "preserves existing managed lines byte-for-byte when adding another entry" do
        File.write(File.join(project_memories_dir, "index.md"), "- **notes** · project · 2020-01-02 · 9\n## Notes\n")
        described_class.call("x", path: "xentry", scope: "project")
        contents = File.read(File.join(project_memories_dir, "index.md"))
        expect(contents).to include("- **notes** · project · 2020-01-02 · 9\n")
        expect(contents.lines.count { |l| l.start_with?("- **notes**") }).to eq(1)
      end

      it "upgrades a legacy '- **name**: desc' line in place, preserving the description" do
        File.write(File.join(project_memories_dir, "index.md"), "- **notes**: old desc\n")
        described_class.call("new content", path: "notes", scope: "project")
        contents = File.read(File.join(project_memories_dir, "index.md"))
        lines = contents.lines.select { |l| l.start_with?("- **notes**") }
        expect(lines.size).to eq(1)
        expect(lines.first).to match(%r{^- \*\*notes\*\* · project · \d{4}-\d{2}-\d{2} · \d+})
        expect(lines.first).to end_with("old desc\n")
      end

      it "keeps an existing description when updating without a new one" do
        described_class.call("v1", path: "k", scope: "project", description: "first desc")
        described_class.call("v2 longer", path: "k", scope: "project")
        line = managed_line_for(File.read(File.join(project_memories_dir, "index.md")), "k")
        expect(line).to end_with("first desc\n")
      end

      it "overrides the description when a new one is supplied" do
        described_class.call("v1", path: "k", scope: "project", description: "first desc")
        described_class.call("v2 longer", path: "k", scope: "project", description: "second desc")
        line = managed_line_for(File.read(File.join(project_memories_dir, "index.md")), "k")
        expect(line).to end_with("second desc\n")
      end

      it "ignores free-form prose that merely starts with '**name**' on a new line" do
        File.write(File.join(project_memories_dir, "index.md"), "- **notes are the best**: keep me\n")
        described_class.call("content", path: "notes", scope: "project")
        contents = File.read(File.join(project_memories_dir, "index.md"))
        # free-form prose untouched, plus a real managed line for notes added
        expect(contents).to include("- **notes are the best**: keep me\n")
        expect(contents.lines.count { |l| l.start_with?("- **notes**") }).to eq(1)
      end
    end

    it "says the index line was refreshed, without the index path, on a normal write" do
      result = described_class.call("hello", path: "greet", scope: "project")
      expect(result).to include("greet")
      expect(result).to include("project")
      expect(result).to include("5 bytes")
      expect(result).not_to include(File.join(project_memories_dir, "index.md"))
      expect(result).to include("Index line refreshed automatically.")
    end

    # ── Overlay tests ────────────────────────────────────────────────────

    describe "model overlays (current_model_only + read)" do
      def mr
        Samagotchi::Tools::MemoryRead
      end

      it "read with model_key appends overlay when key matches and same scope" do
        File.write(File.join(project_memories_dir, "my_memory.md"), "base content")
        File.write(File.join(project_memories_dir, "my_memory.gemma4o.md"), "overlay content")
        result = mr.call("my_memory", scope: "project", model_key: "gemma4o")
        expect(result).to include("base content")
        expect(result).to include("Model-specific guidance (gemma4o):")
        expect(result).to include("overlay content")
      end

      it "reads the fallback key's overlay only when the key has none (a model once keyed by its alias)" do
        File.write(File.join(project_memories_dir, "my_memory.md"), "base content")
        File.write(File.join(project_memories_dir, "my_memory.small.md"), "alias overlay")
        result = mr.call("my_memory", scope: "project", model_key: "gemma-small", fallback_model_key: "small")
        expect(result).to include("Model-specific guidance (small):\nalias overlay")

        File.write(File.join(project_memories_dir, "my_memory.gemma-small.md"), "target overlay")
        result = mr.call("my_memory", scope: "project", model_key: "gemma-small", fallback_model_key: "small")
        expect(result).to include("Model-specific guidance (gemma-small):\ntarget overlay")
        expect(result).not_to include("alias overlay")
      end

      it "read with no key (legacy callers) returns unchanged output" do
        File.write(File.join(project_memories_dir, "my_memory.md"), "base content")
        File.write(File.join(project_memories_dir, "my_memory.gemma4o.md"), "overlay content")
        result = mr.call("my_memory", scope: "project", model_key: nil)
        expect(result).to eq("base content")
        expect(result).not_to include("overlay")
      end

      it "index reads (blank name) never carry overlays" do
        File.write(File.join(project_memories_dir, "index.md"), "## Index\n")
        File.write(File.join(project_memories_dir, "index.gemma4o.md"), "overlay")
        result = mr.call("", scope: "project", model_key: "gemma4o")
        expect(result).to include("## Index")
        expect(result).not_to include("overlay")
      end

      it "overlay is only appended when overlay file exists" do
        File.write(File.join(project_memories_dir, "my_memory.md"), "base content")
        result = mr.call("my_memory", scope: "project", model_key: "gemma4o")
        expect(result).to eq("base content")
      end

      it "overlay is dormant under a different key" do
        File.write(File.join(project_memories_dir, "my_memory.md"), "base content")
        File.write(File.join(project_memories_dir, "my_memory.gemma4o.md"), "overlay content")
        result = mr.call("my_memory", scope: "project", model_key: "qwen3-6-35b-a3b")
        expect(result).to eq("base content")
      end

      it "comma-separated multi-name read applies overlay per matched name" do
        File.write(File.join(project_memories_dir, "a.md"), "base-a")
        File.write(File.join(project_memories_dir, "b.md"), "base-b")
        File.write(File.join(project_memories_dir, "a.gemma4o.md"), "overlay-a")
        result = mr.call("a, b", scope: "project", model_key: "gemma4o")
        expect(result).to include("base-a")
        expect(result).to include("overlay-a")
        expect(result).to include("base-b")
        expect(result).not_to include("overlay-b")
      end

      it "overlay is scoped to the same scope as the base" do
        File.write(File.join(project_memories_dir, "my_memory.md"), "base")
        # overlay in system, base in project — should not find overlay
        File.write(File.join(system_memories_dir, "my_memory.gemma4o.md"), "sys-overlay")
        result = mr.call("my_memory", scope: "project", model_key: "gemma4o")
        expect(result).to eq("base")
        expect(result).not_to include("overlay")
      end

      describe "write with current_model_only" do
        def write_base(name = "my_memory", dir = project_memories_dir)
          File.write(File.join(dir, "#{name}.md"), "base content")
        end

        it "writes suffixed file" do
          write_base
          result = described_class.call(
            "overlay body",
            path: "my_memory",
            scope: "project",
            current_model_only: true,
            model_key: "gemma4o"
          )
          expect(result).to include("Model overlay 'my_memory'")
          expect(result).to include("gemma4o")
          expect(File.exist?(File.join(project_memories_dir, "my_memory.gemma4o.md"))).to be true
          expect(File.read(File.join(project_memories_dir, "my_memory.gemma4o.md"))).to eq("overlay body")
        end

        it "includes the overlay file path in the success message" do
          write_base
          result = described_class.call(
            "overlay body",
            path: "my_memory",
            scope: "project",
            current_model_only: true,
            model_key: "gemma4o"
          )
          expect(result).to include("File written:")
          expect(result).to include(File.join(project_memories_dir, "my_memory.gemma4o.md"))
        end

        it "leaves the base entry untouched" do
          write_base
          described_class.call(
            "overlay body",
            path: "my_memory",
            scope: "project",
            current_model_only: true,
            model_key: "gemma4o"
          )
          expect(File.read(File.join(project_memories_dir, "my_memory.md"))).to eq("base content")
        end

        it "refuses when no base entry exists, writing nothing" do
          result = described_class.call(
            "overlay body",
            path: "my_memory",
            scope: "project",
            current_model_only: true,
            model_key: "gemma4o"
          )
          expect(result).to start_with("Error: no base entry 'my_memory' in project scope")
          expect(result).to include("Write the base entry first")
          expect(Dir.children(project_memories_dir).grep(/my_memory/)).to be_empty
        end

        it "refuses when the base exists only in the other scope" do
          write_base("my_memory", system_memories_dir)
          result = described_class.call(
            "overlay body",
            path: "my_memory",
            scope: "project",
            current_model_only: true,
            model_key: "gemma4o"
          )
          expect(result).to start_with("Error: no base entry 'my_memory' in project scope")
          expect(File.exist?(File.join(project_memories_dir, "my_memory.gemma4o.md"))).to be false
        end

        it "the written overlay is appended on the next read under that model" do
          write_base
          described_class.call(
            "overlay body",
            path: "my_memory",
            scope: "project",
            current_model_only: true,
            model_key: "gemma4o"
          )
          result = mr.call("my_memory", scope: "project", model_key: "gemma4o")
          expect(result).to include("base content")
          expect(result).to include("overlay body")
        end

        it "skips index upsert — index.md byte-identical" do
          write_base
          File.write(File.join(project_memories_dir, "index.md"), "- **existing**: entry\n")
          before = File.read(File.join(project_memories_dir, "index.md"))
          described_class.call(
            "overlay body",
            path: "my_memory",
            scope: "project",
            current_model_only: true,
            model_key: "gemma4o"
          )
          after = File.read(File.join(project_memories_dir, "index.md"))
          expect(after).to eq(before)
        end

        it "errors when model_key is nil" do
          result = described_class.call(
            "body",
            path: "entry",
            scope: "project",
            current_model_only: true,
            model_key: nil
          )
          expect(result).to include("model key is required")
        end

        it "errors when name is 'index'" do
          result = described_class.call(
            "body",
            path: "index",
            scope: "project",
            current_model_only: true,
            model_key: "gemma4o"
          )
          expect(result).to include("incompatible with the index entry")
        end

        it "errors when the model key has an invalid shape" do
          result = described_class.call(
            "body",
            path: "my_memory",
            scope: "project",
            current_model_only: true,
            model_key: "../escape"
          )
          expect(result).to include("invalid model key")
        end
      end
    end
  end

  describe "concurrent writers sharing one project folder" do
    it "keeps every entry's index line when several processes write at once" do
      names = (1..8).map { |i| "entry_#{i}" }
      pids = names.map do |name|
        fork do
          result = described_class.call("body of #{name}\n" * 50, path: name, scope: "project", description: name)
          exit!(result.start_with?("Memory ") ? 0 : 1)
        end
      end
      statuses = pids.map { |pid| Process.wait2(pid).last }
      expect(statuses).to all(be_success)

      index = File.read(File.join(project_memories_dir, "index.md"))
      expect(index).to start_with("# Memory Index")
      names.each { |name| expect(index).to match(/^- \*\*#{name}\*\* · project · .* — #{name}$/) }
      expect(Dir.children(project_memories_dir).grep(/\.tmp\z/)).to be_empty
      expect(Dir.glob(File.join(project_memories_dir, "*.md")).map { |f| File.basename(f, ".md") })
        .to match_array(names + ["index"])
    end
  end
end

