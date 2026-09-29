# frozen_string_literal: true

require "samagotchi/tools/write"
require "tmpdir"

RSpec.describe Samagotchi::Tools::Write do
  describe ".name" do
    it "is 'write'" do
      expect(described_class.name).to eq("write")
    end
  end

  describe ".call" do
    it "writes content to a file and reports bytes written" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "out.txt")
        result = described_class.call("hello", path: path)
        expect(result).to include("5 bytes")
        expect(File.read(path)).to eq("hello")
      end
    end

    it "creates parent directories as needed" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "nested", "dir", "file.txt")
        described_class.call("data", path: path)
        expect(File.exist?(path)).to be true
      end
    end

    it "strips whitespace from the path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "spaced.txt")
        described_class.call("x", path: "  #{path}  ")
        expect(File.exist?(path)).to be true
      end
    end

    it "overwrites existing files" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "old")
        described_class.call("new content", path: path)
        expect(File.read(path)).to eq("new content")
      end
    end

    it "rejects missing content without touching the file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "file.txt")
        File.write(path, "keep me")
        expect(described_class.call(nil, path: path)).to eq("Error: missing content")
        expect(File.read(path)).to eq("keep me")
      end
    end
  end
end
