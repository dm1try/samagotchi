# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

require "samagotchi/memory_bundle/placeholder"

RSpec.describe Samagotchi::MemoryBundle::Placeholder do
  describe "#initialize" do
    it "extracts placeholders from content" do
      p = described_class.new(content: "Hello {{name}}, your test is {{test_command}}")
      expect(p.placeholders).to contain_exactly("name", "test_command")
    end

    it "handles no placeholders" do
      p = described_class.new(content: "No placeholders here.")
      expect(p.placeholders).to be_empty
    end

    it "handles multiple occurrences of same placeholder" do
      p = described_class.new(content: "{{name}} and {{name}} again")
      expect(p.placeholders).to eq(["name", "name"])
    end

    it "extracts unique sorted names" do
      p = described_class.new(content: "{{zebra}}, {{alpha}}, {{middle}}")
      expect(p.unique_names).to eq(%w[alpha middle zebra])
    end

    it "detects any?" do
      expect(described_class.new(content: "has {{placeholder}}").any?).to be true
      expect(described_class.new(content: "clean file").any?).to be false
    end
  end

  describe ".detect_in_file" do
    it "reads and extracts from a file" do
      Dir.mktmpdir do |tmpdir|
        path = File.join(tmpdir, "test.md")
        File.write(path, "# Header\n- {{command}}\n- {{language}}")
        expect(described_class.detect_in_file(path)).to contain_exactly("command", "language")
      end
    end
  end
end
