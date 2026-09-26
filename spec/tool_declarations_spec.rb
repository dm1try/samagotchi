# frozen_string_literal: true

require "samagotchi/tool_declarations"
require "samagotchi/kernel_loop"

# The rendered texts are pinned byte-for-byte by prompt_snapshot_spec; this
# checks the schema table itself: the built-ins' (plugin tools' schemas are
# flattened for the native prompts, below).
RSpec.describe Samagotchi::ToolDeclarations do
  it "is the built-in registry's schemas, in order, and declares every built-in tool class" do
    expect(Samagotchi::Tools::Builtins.default.schemas).to eq(described_class::TOOL_SCHEMAS)
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

# A plugin tool's schema on the native paths: flat, in the built-ins' shape.
RSpec.describe Samagotchi::ToolDeclarations, ".flat_schema" do
  let(:schema) do
    { name: "save_note", description: "Save a note.",
      parameters: { type: "object",
                    properties: { path: { type: "string", description: "Where" },
                                  format: { type: "string", enum: %w[plain markdown], description: "How" },
                                  meta: { type: "object", description: "Extra",
                                          properties: { tags: { type: "array", items: { type: "string" } },
                                                        level: { type: "string", enum: %w[lo hi] } },
                                          additionalProperties: false },
                                  ids: { type: "array", items: { type: "integer" } },
                                  maybe: { type: %w[null integer] } },
                    required: ["path"], additionalProperties: false } }
  end

  it "keeps a type and a description per parameter, the rest in words" do
    expect(described_class.flat_schema(schema)).to eq(
      name: "save_note", description: "Save a note.",
      parameters: { type: "object", required: ["path"], properties: {
        path: { type: "string", description: "Where" },
        format: { type: "string", description: 'How. One of: "plain", "markdown".' },
        meta: { type: "object", description: 'Extra. A JSON object with tags (array), level (string: "lo"|"hi").' },
        ids: { type: "array", description: "A list of integer values." },
        maybe: { type: "integer", description: "" }
      } }
    )
  end

  it "declares no enum, additionalProperties or nesting in either native format" do
    flat = [described_class.flat_schema(schema)]
    expect(described_class.qwen_declarations(flat)).not_to include('"enum"', "additionalProperties", '"items"', '"properties": {\n          "tags"')
    expect(described_class.gemma_declarations(flat)).to include("meta:{type:<|\"|>object<|\"|>")
  end

  it "leaves the built-ins as they are, and the chat path gets a plugin's schema whole" do
    registry = Samagotchi::Tools::Builtins.registry
    registry.register("save_note", schema: schema, handler: ->(*) { "" }, source: "sample-plugin")
    native = described_class.native_schemas(registry)
    expect(native.first(described_class::TOOL_SCHEMAS.size)).to eq(described_class::TOOL_SCHEMAS)
    expect(native.last).to eq(described_class.flat_schema(schema))
    expect(described_class.chat_schemas(registry.schemas).last).to eq(schema)
  end
end
