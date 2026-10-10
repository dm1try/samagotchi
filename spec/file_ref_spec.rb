# frozen_string_literal: true

require "samagotchi/file_ref"

RSpec.describe Samagotchi::FileRef do
  def ref(tool, call, cwd: "/proj")
    described_class.for(tool, call, cwd: cwd)&.to_h
  end

  it "resolves a relative path against the session's cwd, as a file ref" do
    expect(ref("read", { content: "lib/a.rb" })).to eq(kind: "file", path: "/proj/lib/a.rb")
    expect(ref("edit", { path: "./b.rb", old_text: "x" })).to eq(kind: "file", path: "/proj/b.rb")
    expect(ref("write", { path: " c.txt ", content: "hi" })).to eq(kind: "file", path: "/proj/c.txt")
  end

  it "keeps an absolute path, and expands a ~ one" do
    expect(ref("read", { content: "/etc/hosts" })).to eq(kind: "file", path: "/etc/hosts")
    expect(ref("read", { content: "~/notes.md" })).to eq(kind: "file", path: File.expand_path("~/notes.md"))
  end

  it "gives a relative path no ref without a cwd (an attached TUI's join), an absolute or ~ one still" do
    expect(ref("read", { content: "lib/a.rb" }, cwd: nil)).to be_nil
    expect(ref("read", { content: "lib/a.rb" }, cwd: "")).to be_nil
    expect(ref("read", { content: "/x/a.rb" }, cwd: nil)).to eq(kind: "file", path: "/x/a.rb")
    expect(ref("read", { content: "~/a.rb" }, cwd: nil)).to eq(kind: "file", path: File.expand_path("~/a.rb"))
  end

  it "carries a read's or a range edit's lines" do
    expect(ref("read", { content: "a.rb", start_line: 10, end_line: 20 }))
      .to eq(kind: "file", path: "/proj/a.rb", line: 10, end_line: 20)
    expect(ref("edit", { path: "a.rb", start_line: "7", end_line: "7", new_text: "x" }))
      .to eq(kind: "file", path: "/proj/a.rb", line: 7)
    expect(ref("read", { content: "a.rb", start_line: 5 })).to eq(kind: "file", path: "/proj/a.rb", line: 5)
  end

  it "drops a bad or zero range" do
    expect(ref("read", { content: "a.rb", start_line: 0, end_line: 4 })).to eq(kind: "file", path: "/proj/a.rb")
    expect(ref("read", { content: "a.rb", start_line: "x" })).to eq(kind: "file", path: "/proj/a.rb")
    expect(ref("read", { content: "a.rb", start_line: 9, end_line: 3 })).to eq(kind: "file", path: "/proj/a.rb", line: 9)
    expect(ref("read", { content: "a.rb", start_line: -2 })).to eq(kind: "file", path: "/proj/a.rb")
  end

  it "has no ref for a tool that isn't a file tool, an empty path or a bad call" do
    expect(ref("execute", { content: "cat a.rb" })).to be_nil
    expect(ref("memory_read", { content: "x" })).to be_nil
    expect(ref("read", { content: "  " })).to be_nil
    expect(ref("read", nil)).to be_nil
    expect(ref("read", { content: "~nosuchuser_chi/a" })).to be_nil
  end
end
