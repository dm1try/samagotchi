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

# The chat loop's tools: the shared schemas plus what only a JSON Schema
# consumer uses (F3); the native prompts render the shared table unchanged.
RSpec.describe Samagotchi::ToolDeclarations, ".chat_schemas" do
  let(:schemas) { described_class.chat_schemas }

  it "limits the memory scopes to project and system" do
    %w[memory_read memory_write].each do |name|
      scope = schemas.find { |schema| schema[:name] == name }[:parameters][:properties][:scope]
      expect(scope[:enum]).to eq(%w[project system])
    end
  end

  it "closes every tool's parameters with additionalProperties: false" do
    expect(schemas.map { |schema| schema[:parameters][:additionalProperties] }.uniq).to eq([false])
  end

  it "leaves the shared schemas and the Qwen declarations without them" do
    schemas
    expect(JSON.generate(described_class::TOOL_SCHEMAS)).not_to include("enum", "additionalProperties")
    expect(described_class.qwen_declarations).not_to include("enum", "additionalProperties")
  end
end
