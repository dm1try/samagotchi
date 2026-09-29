# frozen_string_literal: true

require "samagotchi/edit_preview"
require "tmpdir"

RSpec.describe Samagotchi::EditPreview do
  around { |ex| Dir.mktmpdir { |dir| @dir = dir; ex.run } }

  def file(name, text)
    File.join(@dir, name).tap { |path| File.binwrite(path, text) }
  end

  describe ".for" do
    it "previews an exact edit without writing" do
      path = file("a.txt", "one\ntwo\nthree\n")
      preview = described_class.for(name: "edit", path: path, content: "<old>two</old><new>2</new>")
      expect(preview).to eq(text: "@@ -1,3 +1,3 @@\n one\n-two\n+2\n three", added: 1, removed: 1,
                            truncated: false, new_file: false)
      expect(File.read(path)).to eq("one\ntwo\nthree\n")
    end

    it "previews a range edit (string line numbers, as the markup loop sends them)" do
      path = file("a.txt", "a\nb\nc\n")
      preview = described_class.for(name: "edit", path: path, content: "<new>B\n</new>", start_line: "2", end_line: "2")
      expect(preview[:text]).to eq("@@ -1,3 +1,3 @@\n a\n-b\n+B\n c")
    end

    it "previews a write over a file and a write of a new file" do
      path = file("a.txt", "old\n")
      expect(described_class.for(name: "write", path: path, content: "new\n"))
        .to include(text: "@@ -1 +1 @@\n-old\n+new", new_file: false)
      expect(described_class.for(name: "write", path: File.join(@dir, "sub", "n.txt"), content: "x\ny\n"))
        .to eq(text: "@@ -0,0 +1,2 @@\n+x\n+y", added: 2, removed: 0, truncated: false, new_file: true)
      expect(File.exist?(File.join(@dir, "sub"))).to be false
    end

    it "gives a 0/0 diff for a call that changes nothing" do
      path = file("a.txt", "same\n")
      expect(described_class.for(name: "write", path: path, content: "same\n")).to include(text: "", added: 0, removed: 0)
    end

    it "passes the tool's error through, without the Error: prefix" do
      path = file("a.txt", "one\n")
      expect(described_class.for(name: "edit", path: path, content: "<old>nope</old><new>x</new>"))
        .to eq(error: "old text not found in #{path}")
      expect(described_class.for(name: "edit", path: File.join(@dir, "missing"), content: "<old>a</old><new>b</new>"))
        .to eq(error: "file not found: #{File.join(@dir, 'missing')}")
      expect(described_class.for(name: "write", path: path, content: nil)).to eq(error: "missing content")
    end

    it "skips binary files and files over 1 MB" do
      bin = file("b.bin", "abc\0def")
      big = file("big.txt", "x" * (described_class::MAX_FILE_BYTES + 1))
      expect(described_class.for(name: "edit", path: bin, content: "<old>abc</old><new>x</new>")).to eq(skipped: "binary file")
      expect(described_class.for(name: "edit", path: big, content: "<old>x</old><new>y</new>")).to eq(skipped: "file over 1 MB")
      expect(described_class.for(name: "write", path: File.join(@dir, "n.bin"), content: "a\0b")).to eq(skipped: "binary file")
    end

    it "expands ~ and resolves relative paths against the cwd, as the tools do" do
      Dir.chdir(@dir) do
        file("rel.txt", "r\n")
        expect(described_class.for(name: "write", path: " rel.txt ", content: "R\n")).to include(new_file: false, added: 1)
      end
      allow(File).to receive(:expand_path).and_call_original
      allow(File).to receive(:expand_path).with("~/t.txt").and_return(File.join(@dir, "t.txt"))
      file("t.txt", "t\n")
      expect(described_class.for(name: "write", path: "~/t.txt", content: "T\n")).to include(new_file: false)
    end

    it "scrubs invalid UTF-8" do
      path = file("a.txt", "ok\n")
      preview = described_class.for(name: "write", path: path, content: "bad \xFF\n".b)
      expect(preview[:text]).to be_valid_encoding
    end

    it "returns nil for other tools" do
      expect(described_class.for(name: "execute", content: "ls")).to be_nil
    end
  end

  describe ".change" do
    it "diffs the file before and after, nil when nothing changed" do
      expect(described_class.change("a\n", "b\n")).to include(added: 1, removed: 1, new_file: false)
      expect(described_class.change(nil, "b\n")).to include(new_file: true)
      expect(described_class.change("a\n", "a\n")).to be_nil
      expect(described_class.change({ skipped: "binary file" }, "b\n")).to be_nil
      expect(described_class.change("a\n", nil)).to be_nil
    end
  end
end
