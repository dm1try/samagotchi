# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/prompt_history"

RSpec.describe Samagotchi::PromptHistory do
  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_HISTORY_FILE", "XDG_STATE_HOME")
    Dir.mktmpdir("prompt-history-spec") do |dir|
      @dir = dir
      ENV.delete("SAMAGOTCHI_HISTORY_FILE")
      ENV["XDG_STATE_HOME"] = File.join(dir, "state")
      example.run
    end
  ensure
    %w[SAMAGOTCHI_HISTORY_FILE XDG_STATE_HOME].each { |k| ENV.delete(k) }
    ENV.update(saved)
  end

  describe ".path" do
    it "defaults to $XDG_STATE_HOME/samagotchi/history.json" do
      expect(described_class.path).to eq(File.join(@dir, "state", "samagotchi", "history.json"))
    end

    it "follows history.file (SAMAGOTCHI_HISTORY_FILE)" do
      ENV["SAMAGOTCHI_HISTORY_FILE"] = File.join(@dir, "elsewhere.json")

      expect(described_class.path).to eq(File.join(@dir, "elsewhere.json"))
    end
  end

  describe ".entries" do
    it "is empty without a file" do
      expect(described_class.entries).to eq([])
    end

    it "reads a JSON array, normalizing line endings and dropping blanks" do
      FileUtils.mkdir_p(File.dirname(described_class.path))
      File.write(described_class.path, JSON.generate(["one", "two\r\nlines", "  ", " three "]))

      expect(described_class.entries).to eq(["one", "two\nlines", "three"])
    end

    it "falls back to one entry per line for a non-JSON file" do
      FileUtils.mkdir_p(File.dirname(described_class.path))
      File.write(described_class.path, "first\n\nsecond\n")

      expect(described_class.entries).to eq(%w[first second])
    end
  end

  describe ".append" do
    it "creates the file and keeps the order" do
      described_class.append("one")
      described_class.append("two")

      expect(JSON.parse(File.read(described_class.path))).to eq(%w[one two])
    end

    it "keeps 100 entries" do
      expect(described_class::LIMIT).to eq(100)
    end

    it "keeps only the last LIMIT entries" do
      (described_class::LIMIT + 3).times { |i| described_class.append("p#{i}") }

      entries = described_class.entries
      expect(entries.size).to eq(described_class::LIMIT)
      expect(entries.last).to eq("p#{described_class::LIMIT + 2}")
    end

    it "keeps every line when two processes append at once" do
      lines = 40
      pids = %w[a b].map do |tag|
        fork do
          lines.times { |i| described_class.append("#{tag}#{i}") }
          exit!(0)
        end
      end
      pids.each { |pid| Process.wait(pid) }

      entries = described_class.entries
      expect(entries.size).to eq(2 * lines)
      expect(entries.select { |e| e.start_with?("a") }).to eq(Array.new(lines) { |i| "a#{i}" })
      expect(entries.select { |e| e.start_with?("b") }).to eq(Array.new(lines) { |i| "b#{i}" })
    end

    it "writes the file 0600" do
      described_class.append("secret")

      expect(File.stat(described_class.path).mode & 0o777).to eq(0o600)
    end

    it "keeps a corrupt file's lines (line format) when appending" do
      FileUtils.mkdir_p(File.dirname(described_class.path))
      File.write(described_class.path, "[\"broken\n")
      described_class.append("next")

      expect(described_class.entries).to eq(["[\"broken", "next"])
    end

    it "normalizes the existing entries it rewrites" do
      FileUtils.mkdir_p(File.dirname(described_class.path))
      File.write(described_class.path, "old\r\n\n")
      described_class.append("new")

      expect(JSON.parse(File.read(described_class.path))).to eq(%w[old new])
    end
  end

  describe ".shell_line?" do
    it "is true for !commands" do
      expect(described_class.shell_line?("!ls -la")).to be(true)
    end

    it "is false for !rollback, /commands and prompts" do
      expect(described_class.shell_line?("!rollback")).to be(false)
      expect(described_class.shell_line?(" !rollback ".strip)).to be(false)
      expect(described_class.shell_line?("/model x")).to be(false)
      expect(described_class.shell_line?("hello")).to be(false)
      expect(described_class.shell_line?(nil)).to be(false)
    end
  end
end
