# frozen_string_literal: true

require "samagotchi/tools/builtins"
require "samagotchi/tools/deferred_tools"
require "samagotchi/tools/tool_index"
require "samagotchi/toolkit"

RSpec.describe Samagotchi::Tools::DeferredTools do
  let(:registry) { Samagotchi::Tools::Builtins.registry }
  let(:index) { Samagotchi::Tools::ToolIndex.new }
  let(:schema) { { "type" => "object", "properties" => {} } }

  def tool(name, acts_as: "mcp_fs_#{name}", refusal: nil, group: "fs")
    Samagotchi::Tools::ToolIndex::Tool.new(group: group, name: name, acts_as: acts_as, description: "#{name} it",
                                           schema: schema, refusal: refusal)
  end

  def source!(*groups)
    source = index.source(label: "mcp", call: ->(*) { "ok" }, acts_as: ->(g, t) { "mcp_#{g}_#{t}" })
    source.publish(groups)
    index.add(source)
    source
  end

  def toolkit!(name = "lean", **)
    registry.toolkit = Samagotchi::Toolkit.new(name: name, **).resolve(Samagotchi::Toolkit.kits)
    index.refresh!
  end

  def names(conversation = [], layers: []) = described_class.list(registry, conversation, layers: layers).map(&:name)

  it "lists the reachable built-ins in registry order, then the source tools by name" do
    source!(Samagotchi::Tools::ToolIndex::Group.new(name: "fs", tools: [tool("write"), tool("read")]))
    index.declare(registry)
    toolkit!

    expect(names).to eq(%w[register_reminder cancel_reminder list_reminders list_sessions send_note delegate
                           delegate_result mcp_fs_read mcp_fs_write])
    first = described_class.list(registry, []).first
    expect(first.description).to start_with("Register a periodic reminder.")
    expect(first.schema).to include(type: "object")
  end

  it "leaves out a refused tool, an acts_as two tools share, a name Messages refuses, and a registered tool's name" do
    groups = [Samagotchi::Tools::ToolIndex::Group.new(name: "fs", tools: [
      tool("ok"), tool("bad", refusal: "bad schema"), tool("twin", acts_as: "mcp_twin"),
      tool("dotted", acts_as: "mcp.fs.dotted"), tool("shadow", acts_as: "read")
    ]),
              Samagotchi::Tools::ToolIndex::Group.new(name: "gh", tools: [tool("twin", acts_as: "mcp_twin", group: "gh")])]
    source!(*groups)
    index.declare(registry)
    toolkit!

    expect(names.grep(/mcp|read\z/)).to eq(%w[mcp_fs_ok])
  end

  it "lists no source tool while call_tool isn't declared, and nothing on full without one" do
    source!(Samagotchi::Tools::ToolIndex::Group.new(name: "fs", tools: [tool("read")]))
    index.declare(registry)
    toolkit!(remove: %w[call_tool])

    expect(names).to eq([])

    full = Samagotchi::Tools::Builtins.registry
    Samagotchi::Tools::ToolIndex.new.declare(full)
    full.toolkit = Samagotchi::Toolkit.new(name: "full").resolve(Samagotchi::Toolkit.kits)
    expect(described_class.list(full, [])).to eq([])
  end

  it "follows the turn's layers: a layer's tool is declared under it, never deferred" do
    index.declare(registry)
    kits = Samagotchi::Toolkit.kits.merge("tiny" => Samagotchi::Toolkit::Kit.new(name: "tiny", tools: %w[read]))
    registry.toolkit = Samagotchi::Toolkit.new(name: "tiny").resolve(kits)

    expect(names(layers: [:forget])).to eq(names)
    expect(names).to include("execute")
    expect(names).not_to include("forget_outputs", "read")
  end

  it "keeps a name the history loaded as a stub when nothing else lists it, first reference first" do
    index.declare(registry)
    toolkit!
    conversation = [{ role: "tool_response", content: "x", loaded: %w[mcp_gone_tool list_sessions] },
                    { role: "system", kind: "tool_change", content: "y", tool_change: { add: %w[mcp_later read] } },
                    { "role" => "tool_response", "content" => "z", "loaded" => %w[mcp_gone_tool] }]

    list = described_class.list(registry, conversation)

    expect(list.map(&:name).last(2)).to eq(%w[mcp_gone_tool mcp_later])
    expect(list.last).to have_attributes(description: described_class::STUB_DESCRIPTION, schema: described_class::STUB_SCHEMA)
    # read is declared: never deferred.
    expect(list.map(&:name)).not_to include("read")
  end

  it "explains that a previously loaded source tool's group is outside the current toolkit" do
    source!(Samagotchi::Tools::ToolIndex::Group.new(name: "fs", tools: [tool("read")]))
    index.declare(registry)
    toolkit!
    registry.toolkit = registry.toolkit.with(groups: [])
    conversation = [{ role: "tool_response", content: "x", loaded: ["mcp_fs_read"] }]

    stub = described_class.list(registry, conversation).last

    expect(stub.name).to eq("mcp_fs_read")
    expect(stub.description).to eq("Not available in this session's toolkit (lean); only the user can switch " \
                                    "(/toolkit NAME, or a kit that reaches fs).")
  end
end
