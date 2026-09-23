# frozen_string_literal: true

require "samagotchi/tool_declarations"
require "samagotchi/kernel_loop"

# The rendered texts are pinned byte-for-byte by prompt_snapshot_spec; this
# checks the schema table itself.
RSpec.describe Samagotchi::ToolDeclarations do
  it "declares every tool KernelLoop dispatches, and only those" do
    expect(described_class::TOOL_SCHEMAS.map { |s| s[:name] })
      .to match_array(Samagotchi::KernelLoop::TOOLS.map { |t| t::NAME })
  end

  it "only overrides parameters that exist" do
    described_class::GEMMA_PARAM_OVERRIDES.each do |tool, params|
      schema = described_class::TOOL_SCHEMAS.find { |s| s[:name] == tool }
      expect(schema).not_to be_nil, "unknown tool #{tool}"
      expect(schema[:parameters][:properties].keys).to include(*params.keys)
    end
  end
end
