# frozen_string_literal: true

require "samagotchi/project_id"

RSpec.describe Samagotchi::ProjectId do
  describe ".parse" do
    it "reads a valid id among other lines, and no id from a marker without one" do
      expect(described_class.parse("# chi project marker\nid: notes-0a1b2c3d\n"))
        .to eq(described_class::Read.new(id: "notes-0a1b2c3d", problem: nil))
      expect(described_class.parse("# chi project marker\n")).to eq(described_class::NONE)
      expect(described_class.parse("")).to eq(described_class::NONE)
      expect(described_class.parse("other: 1\n")).to eq(described_class::NONE)
    end

    it "says once why a present id is none" do
      expect(described_class.parse("id: ../x\n").problem).to start_with('its id "../x" is not a valid id')
      expect(described_class.parse("id: 5\n").problem).to start_with("its id 5 is not a valid id")
      expect(described_class.parse("id:\n").problem).to start_with("its id nil is not a valid id")
      expect(described_class.parse("id: [a\n").problem).to eq("the marker is not valid YAML")
      expect(described_class.parse("- a\n").problem).to eq("the marker is not a YAML mapping")
      expect(described_class.parse("id: \xFF\n".b).problem).to eq("the marker is not UTF-8 text")
      expect(described_class.parse("id: !ruby/object:Object {}\n").problem).to eq("the marker is not valid YAML")
    end
  end

  describe ".generate" do
    it "makes <basename>-<8 hex>, never key-shaped (<basename>_<8 hex>), from any folder name" do
      expect(described_class.generate("notes")).to match(/\Anotes-\h{8}\z/)
      expect(described_class.generate("my notes!")).to match(/\Amy-notes-\h{8}\z/)
      expect(described_class.generate("..")).to match(/\Aproject-\h{8}\z/)
      expect(described_class.generate("Документы")).to match(/\Aproject-\h{8}\z/)
      ids = ["notes", "a_b", "x" * 200].map { |name| described_class.generate(name) }
      expect(ids).to all(match(described_class::PATTERN))
      expect(ids.grep(/_\h{8}\z/)).to eq([])
    end
  end

  describe ".with_id" do
    it "appends the id line, or replaces it, keeping every other line" do
      expect(described_class.with_id("# marker\n", "a-1")).to eq("# marker\nid: a-1\n")
      expect(described_class.with_id("# marker", "a-1")).to eq("# marker\nid: a-1\n")
      expect(described_class.with_id("", "a-1")).to eq("id: a-1\n")
      expect(described_class.with_id("# m\nid: old\nx: 1\n", "a-2")).to eq("# m\nid: a-2\nx: 1\n")
    end
  end
end
