# frozen_string_literal: true

require "json"
require "samagotchi/tools/memory"

RSpec.describe Samagotchi::Tools::MemoryRead, ".prompt_memory?" do
  let(:cases) { JSON.parse(File.read(File.expand_path("../shared/prompt_memory_match.json", __dir__))) }

  it "follows the shared scope-and-name cases" do
    cases.each do |entry|
      expect(described_class.prompt_memory?(entry.dig("target", "key"), [[entry.dig("part", "ref"), entry.dig("part", "scope")]]))
        .to eq(entry.fetch("expected")), entry.inspect
    end
  end
end
