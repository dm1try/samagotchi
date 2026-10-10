# frozen_string_literal: true

require "tmpdir"
require "samagotchi/analytics_file"

RSpec.describe Samagotchi::AnalyticsFile do
  around do |example|
    Dir.mktmpdir("analytics-file-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  it "keeps the file next to the session as analytics.json" do
    expect(described_class.path(@dir)).to eq(File.join(@dir, "analytics.json"))
  end

  describe ".read" do
    it "returns the saved object, string-keyed" do
      File.write(described_class.path(@dir), JSON.generate(turns: 2, turn_records: [{ id: "t1" }]))
      expect(described_class.read(@dir)).to eq("turns" => 2, "turn_records" => [{ "id" => "t1" }])
    end

    it "returns nil without a file" do
      expect(described_class.read(@dir)).to be_nil
      expect(described_class.read(File.join(@dir, "gone"))).to be_nil
    end

    it "returns nil for a corrupt file" do
      File.write(described_class.path(@dir), "{\"turns\": 2,")
      expect(described_class.read(@dir)).to be_nil
    end

    it "returns nil when the JSON is not an object" do
      File.write(described_class.path(@dir), "[1, 2]")
      expect(described_class.read(@dir)).to be_nil
    end

    it "returns nil when the path is a directory" do
      Dir.mkdir(described_class.path(@dir))
      expect(described_class.read(@dir)).to be_nil
    end
  end
end
