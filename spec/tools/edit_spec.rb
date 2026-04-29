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
  end
end
