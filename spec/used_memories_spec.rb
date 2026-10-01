# frozen_string_literal: true

require "samagotchi/used_memories"
require "samagotchi/session"

RSpec.describe Samagotchi::UsedMemories do
  subject(:used) { described_class.new }

  def started(name, content) = { type: :tool_call_started, call: { name: name, content: content } }

  describe ".names_from_call" do
    it "splits a memory_read comma list into names" do
      expect(described_class.names_from_call({ name: "memory_read", content: "a, b.md, ,x" })).to eq(%w[a b x])
    end

    it "takes a read of memories/*.md as that memory" do
      expect(described_class.names_from_call({ name: "read", content: "memories/foo.md" })).to eq("foo")
      expect(described_class.names_from_call({ name: "read", content: "C:\\x\\memories\\bar.md" })).to eq("bar")
    end

    it "is nil for another read, another tool, empty content or a non-Hash" do
      expect(described_class.names_from_call({ name: "read", content: "lib/foo.rb" })).to be_nil
      expect(described_class.names_from_call({ name: "write", content: "memories/foo.md" })).to be_nil
      expect(described_class.names_from_call({ name: "memory_read", content: "  " })).to be_nil
      expect(described_class.names_from_call(nil)).to be_nil
    end
  end

  it "starts from the names given, deduped, without blanks" do
    expect(described_class.new(["a", " b ", "", "a"]).names).to eq(%w[a b])
  end

  it "#names is a copy" do
    used.add(%w[a])
    used.names << "z"
    expect(used.names).to eq(%w[a])
  end

  it "#absorb adds a session's names and ignores nil" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    session.used_memory_names = %w[notes]
    used.add(%w[plan]).absorb(session).absorb(nil)
    expect(used.names).to eq(%w[plan notes])
  end

  describe "#capture" do
    it "adds a read's names and returns them, a repeat read too" do
      expect(used.capture(started("memory_read", "a, b"), muted: [])).to eq(%w[a b])
      expect(used.capture(started("memory_read", "a"), muted: [])).to eq(%w[a])
      expect(used.names).to eq(%w[a b])
    end

    it "leaves out muted names; nil when only muted ones were read" do
      expect(used.capture(started("memory_read", "secret, open"), muted: %w[secret])).to eq(%w[open])
      expect(used.capture(started("memory_read", "secret"), muted: %w[secret])).to be_nil
      expect(used.names).to eq(%w[open])
    end

    it "is nil for other events and other calls" do
      expect(used.capture({ type: :tool_call_finished, call: { name: "memory_read", content: "a" } }, muted: [])).to be_nil
      expect(used.capture(started("read", "lib/a.rb"), muted: [])).to be_nil
      expect(used.capture("text", muted: [])).to be_nil
      expect(used.names).to eq([])
    end
  end

  it "keeps every name added from several threads, once" do
    threads = Array.new(4) { |t| Thread.new { 50.times { |i| used.add(["n#{i % 25}", "t#{t}"]) } } }
    threads.each(&:join)
    expect(used.names.size).to eq(29)
    expect(used.names.uniq).to eq(used.names)
  end
end
