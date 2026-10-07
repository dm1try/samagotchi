# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/memory_bundle/index_size"

RSpec.describe Samagotchi::MemoryBundle::IndexSize do
  let(:tmpdir) { Dir.mktmpdir("index-size-") }
  let(:config_home) { File.join(tmpdir, "config") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }

  around { |example| with_config_home(config_home) { example.run } }

  before { FileUtils.mkdir_p(system_dir) }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".of_text" do
    it "counts bytes, non-blank lines and tokens as characters / chars_per_token, rounded up" do
      text = "# Index\n\n- **a** · 9 B · 2026-10-08 · one\n"
      size = described_class.of_text("system", text, chars_per_token: 4.0)
      expect(size.to_h).to eq(scope: "system", bytes: text.bytesize, lines: 2, tokens: (text.length / 4.0).ceil)
      expect(size.bytes).to be > text.length # the middle dots are 2 bytes each
    end

    it "takes context.chars_per_token by default" do
      with_env("SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN" => "2") do
        expect(described_class.of_text("project", "x" * 9).tokens).to eq(5)
      end
    end

    it "measures nil as empty" do
      expect(described_class.of_text("project", nil, chars_per_token: 4.0).to_h).to include(bytes: 0, lines: 0, tokens: 0)
    end
  end

  describe ".of_scope" do
    it "measures index.md as the prompt carries it, without the model notes' lines" do
      File.write(File.join(system_dir, "model_notes_x.md"), "models: *\nX.\n")
      kept = "- **tips** · 10 B · 2026-10-08 · tips\n"
      File.write(File.join(system_dir, "index.md"), "#{kept}- **model_notes_x** · 12 B · 2026-10-08 · x\n")
      expect(described_class.of_scope("system", chars_per_token: 4.0))
        .to eq(described_class.of_text("system", kept, chars_per_token: 4.0))
    end

    it "measures the file listing the prompt gets when the scope has no index.md" do
      File.write(File.join(system_dir, "alpha.md"), "a")
      expect(described_class.of_scope("system", chars_per_token: 4.0).lines).to eq(2)
    end

    it "resolves the memories dir from the env it is given" do
      other = File.join(tmpdir, "other")
      dir = Samagotchi::MemoryPaths.system_dir(env: { "XDG_CONFIG_HOME" => other })
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "index.md"), "- **only-here** · 1 B\n")
      File.write(File.join(system_dir, "index.md"), "")
      expect(described_class.of_scope("system", env: { "XDG_CONFIG_HOME" => other }).lines).to eq(1)
      expect(described_class.of_scope("system").lines).to eq(0)
    end
  end

  describe "#over?" do
    let(:size) { described_class.new(scope: "system", bytes: 0, lines: 0, tokens: 2500) }

    it "is over only past a positive limit" do
      expect(size.over?(2500)).to be(false)
      expect(size.over?(2499)).to be(true)
      expect(size.over?(0)).to be(false)
    end
  end

  describe ".warn_limit" do
    it "is memory.index_warn_tokens, 2500 by default" do
      expect(described_class.warn_limit).to eq(2500)
      with_env("SAMAGOTCHI_MEMORY_INDEX_WARN_TOKENS" => "0") { expect(described_class.warn_limit).to eq(0) }
    end
  end

  describe ".crossing_note" do
    def size(tokens) = described_class.new(scope: "project", bytes: 0, lines: 0, tokens: tokens)

    it "notes a write that takes the index from at or under the limit to over it" do
      note = described_class.crossing_note(size(500), size(501), 500)
      expect(note).to eq(
        "Note: the project memory index is now ~501 tokens (over memory.index_warn_tokens 500) and is sent with " \
        "every prompt. When you next have a moment, tighten long index descriptions (memory_write with name, scope " \
        "and description only). Don't remove or merge memories unless the user asks."
      )
    end

    it "says nothing while already over, under the limit, on a shrink, with limit 0 or without a measure" do
      expect(described_class.crossing_note(size(600), size(700), 500)).to be_nil
      expect(described_class.crossing_note(size(100), size(400), 500)).to be_nil
      expect(described_class.crossing_note(size(700), size(400), 500)).to be_nil
      expect(described_class.crossing_note(size(100), size(9000), 0)).to be_nil
      expect(described_class.crossing_note(nil, size(9000), 500)).to be_nil
    end
  end

  describe ".count_text and #summary" do
    it "words a count as the readouts show it" do
      expect([0, 450, 999, 1000, 1949, 1950, 13_600].map { |n| described_class.count_text(n) })
        .to eq(%w[0 450 999 1.0k 1.9k 2.0k 13.6k])
    end

    it "words chi self's scope, marking one over the limit" do
      size = described_class.new(scope: "system", bytes: 0, lines: 54, tokens: 1997)
      expect(size.summary(2500)).to eq("system ~2.0k tokens (54 lines)")
      expect(size.summary(1500)).to eq("system ~2.0k tokens (54 lines, over 1500)")
      expect(described_class.new(scope: "project", bytes: 0, lines: 1, tokens: 6).summary).to eq("project ~6 tokens (1 line)")
    end
  end
end
