# frozen_string_literal: true

require "samagotchi/tools/read"
require "tmpdir"

RSpec.describe Samagotchi::Tools::Read do
  describe ".name" do
    it "is 'read'" do
      expect(described_class.name).to eq("read")
    end
  end

  describe ".call" do
    it "reads an existing file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test.txt")
        File.write(path, "hello samagotchi")
        expect(described_class.call(path)).to eq("hello samagotchi")
      end
    end

    it "returns an error string for a missing file" do
      expect(described_class.call("/nonexistent/file.rb")).to include("Error")
    end

    it "strips surrounding whitespace from the path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test.txt")
        File.write(path, "content")
        expect(described_class.call("  #{path}  ")).to eq("content")
      end
    end
  end
end
