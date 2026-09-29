# frozen_string_literal: true

require "samagotchi/tools/edit"
require "tmpdir"

RSpec.describe Samagotchi::Tools::Edit do
  describe ".name" do
    it "is 'edit'" do
      expect(described_class.name).to eq("edit")
    end
  end

  describe ".call" do
    def content(old_text, new_text)
      "<old>#{old_text}</old><new>#{new_text}</new>"
    end

    it "replaces a unique line in a file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "line one\nline two\nline three\n")
        result = described_class.call(content("line two", "line 2"), path: path)
        expect(result).to include("Edited")
        expect(File.read(path)).to eq("line one\nline 2\nline three\n")
      end
    end

    it "replaces a multi-line block" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.rb")
        File.write(path, "def foo\n  42\nend\n")
        result = described_class.call(content("def foo\n  42\nend", "def foo\n  43\nend"), path: path)
        expect(result).to include("Edited")
        expect(File.read(path)).to eq("def foo\n  43\nend\n")
      end
    end

    it "returns an error when old text is not found" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "hello world")
        result = described_class.call(content("missing text", "anything"), path: path)
        expect(result).to include("Error")
        expect(result).to include("not found")
      end
    end

    it "returns an error when old text matches more than once" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "foo foo foo")
        result = described_class.call(content("foo", "bar"), path: path)
        expect(result).to include("Error")
        expect(result).to include("matches")
      end
    end

    it "returns an error for a missing file" do
      result = described_class.call(content("x", "y"), path: "/nonexistent/file.txt")
      expect(result).to include("Error")
      expect(result).to include("not found")
    end

    it "returns an error when the <old> block is missing" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "original content")
        result = described_class.call("<new>replacement</new>", path: path)
        expect(result).to include("Error")
        expect(result).to include("<old>")
        expect(File.read(path)).to eq("original content")
      end
    end

    it "returns an error when the <new> block is missing" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "original content")
        result = described_class.call("<old>original</old>", path: path)
        expect(result).to include("Error")
        expect(result).to include("<new>")
        expect(File.read(path)).to eq("original content")
      end
    end

    it "returns an error when <old> is empty" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "content")
        result = described_class.call(content("", "replacement"), path: path)
        expect(result).to include("Error")
        expect(result).to include("empty")
      end
    end

    it "strips whitespace from the path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "hello world")
        result = described_class.call(content("hello", "hi"), path: "  #{path}  ")
        expect(result).to include("Edited")
        expect(File.read(path)).to eq("hi world")
      end
    end

    it "replaces only the first (unique) occurrence exactly" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "start middle end")
        result = described_class.call(content("middle", "center"), path: path)
        expect(result).to include("Edited")
        expect(File.read(path)).to eq("start center end")
      end
    end

    it "replaces a specific line range with new text" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "line 1\nline 2\nline 3\nline 4\n")

        result = described_class.call(content("", "line 2 updated\nline 3 updated\n"), path: path, start_line: 2, end_line: 3)
        expect(result).to include("replaced lines 2-3")
        expect(File.read(path)).to eq("line 1\nline 2 updated\nline 3 updated\nline 4\n")
      end
    end

    it "allows deleting a line range by using empty new text" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "line 1\nline 2\nline 3\n")

        result = described_class.call(content("unused", ""), path: path, start_line: 2, end_line: 2)
        expect(result).to include("replaced lines 2-2")
        expect(File.read(path)).to eq("line 1\nline 3\n")
      end
    end

    it "returns an error when start_line is missing" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "line 1\nline 2\n")

        result = described_class.call(content("", "updated\n"), path: path, end_line: 2)
        expect(result).to include("Error")
        expect(result).to include("start_line must be provided")
      end
    end

    it "returns an error when range boundaries are invalid" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "line 1\nline 2\n")

        result = described_class.call(content("", "updated\n"), path: path, start_line: 0, end_line: 1)
        expect(result).to include("Error")
        expect(result).to include("start_line must be a positive integer")
      end
    end

    it "returns an error when start_line is past EOF" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "line 1\nline 2\n")

        result = described_class.call(content("", "updated\n"), path: path, start_line: 5, end_line: 6)
        expect(result).to include("Error")
        expect(result).to include("out of bounds")
      end
    end

    it "clamps an overshooting end_line to EOF and applies the edit" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "line 1\nline 2\n")

        result = described_class.call(content("", "updated\n"), path: path, start_line: 1, end_line: 5)
        expect(result).to include("Edited")
        expect(result).to include("clamped to line 2")

        # The replacement actually covered the whole (clamped) range.
        expect(File.read(path)).to eq("updated\n")
      end
    end

    it "replaces from start_line to EOF when end_line is omitted" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "line 1\nline 2\nline 3\n")

        described_class.call(content("", "X\n"), path: path, start_line: 2)

        expect(File.read(path)).to eq("line 1\nX\n")
      end
    end

    it "keeps the hard error when SAMAGOTCHI_EDIT_ALLOW_OOR_END is disabled" do
      Dir.mktmpdir do |dir|
        ENV["SAMAGOTCHI_EDIT_ALLOW_OOR_END"] = "false"
        path = File.join(dir, "file.txt")
        File.write(path, "line 1\nline 2\n")

        result = described_class.call(content("", "updated\n"), path: path, start_line: 1, end_line: 5)
        expect(result).to include("Error")
        expect(result).to include("out of bounds")
      ensure
        ENV.delete("SAMAGOTCHI_EDIT_ALLOW_OOR_END")
      end
    end
  end

  describe ".apply" do
    def content(old_text, new_text)
      "<old>#{old_text}</old><new>#{new_text}</new>"
    end

    def with_file(text)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, text)
        yield path
      end
    end

    it "returns the updated text and the call message without writing (exact mode)" do
      with_file("one\ntwo\n") do |path|
        updated, message = described_class.apply(content("two", "2"), path: path)
        expect(updated).to eq("one\n2\n")
        expect(message).to eq("Edited #{path}: replaced 3 bytes with 1 bytes")
        expect(File.read(path)).to eq("one\ntwo\n")
      end
    end

    it "returns the updated text without writing (range mode, clamp note kept)" do
      with_file("a\nb\nc\n") do |path|
        updated, message = described_class.apply(content("", "B\n"), path: path, start_line: 2, end_line: 9)
        expect(updated).to eq("a\nB\n")
        expect(message).to end_with("(end_line 9 exceeds 3 lines; clamped to line 3)")
        expect(File.read(path)).to eq("a\nb\nc\n")
      end
    end

    it "reads through the given reader" do
      with_file("on disk\n") do |path|
        updated, = described_class.apply(content("copy", "COPY"), path: path, read: ->(_) { "a copy\n" })
        expect(updated).to eq("a COPY\n")
      end
    end

    it "returns every error string call returns" do
      with_file("x\nx\n") do |path|
        expect(described_class.apply("<new>n</new>", path: path)).to eq("Error: missing <old>...</old> block")
        expect(described_class.apply("<old>x</old>", path: path)).to eq("Error: missing <new>...</new> block")
        expect(described_class.apply(content("", "n"), path: path)).to eq("Error: <old> block is empty")
        expect(described_class.apply(content("zz", "n"), path: path)).to eq("Error: old text not found in #{path}")
        expect(described_class.apply(content("x", "n"), path: path))
          .to eq("Error: old text matches 2 times in #{path}; make it unique")
        expect(described_class.apply("<old>x</old>", path: path, start_line: 1)).to eq("Error: missing <new>...</new> block")
        expect(described_class.apply(content("", "n"), path: path, start_line: 0)).to eq("Error: start_line must be a positive integer")
        expect(described_class.apply(content("", "n"), path: path, end_line: 1))
          .to eq("Error: start_line must be provided for range edits")
        expect(described_class.apply(content("", "n"), path: path, start_line: 5))
          .to eq("Error: start_line 5 out of bounds for #{path}: file has 2 lines")
        expect(described_class.apply(content("", "n"), path: path, start_line: 2, end_line: 1))
          .to eq("Error: start_line must be <= end_line")
        expect(described_class.apply(content("x", "n"), path: path, read: ->(_) { raise "boom" })).to eq("Error: boom")
      end
    end

    it "checks the tags before the file in exact mode, and the file first in range mode" do
      missing = "/nonexistent/file.txt"
      expect(described_class.apply("<new>n</new>", path: missing)).to eq("Error: missing <old>...</old> block")
      expect(described_class.call("<new>n</new>", path: missing)).to eq("Error: missing <old>...</old> block")
      expect(described_class.apply("<old>x</old>", path: missing, start_line: 1)).to eq("Error: file not found: #{missing}")
      expect(described_class.call("<old>x</old>", path: missing, start_line: 1)).to eq("Error: file not found: #{missing}")
    end
  end
end
