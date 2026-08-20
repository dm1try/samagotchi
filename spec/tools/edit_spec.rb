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
end
