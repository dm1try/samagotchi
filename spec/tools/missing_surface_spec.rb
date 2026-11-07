# frozen_string_literal: true

require "samagotchi/tool_runner"
require "samagotchi/hooks"
require "samagotchi/kernel_loop"
require "samagotchi/guardrails"
require "samagotchi/tool_activity"
require "samagotchi/tools/builtins"
require "samagotchi/tools/tool_index"
require "samagotchi/tools/tool_surface"
require "support/test_kernel"

# The turn's tools (Tools::ToolSurface) are mandatory on the tool index's
# path: call_tool's targets and row read the turn's, and none raises
# Tools::MissingSurface. The rescues around a plugin tool's targets: and
# preview: (Guardrails::Targets.plugin_targets, ToolActivity.registry_params)
# re-raise it: taken as a failing targets:, call_tool's acts_as would go
# missing and an mcp_* rule would not see the call (fail-open).
RSpec.describe Samagotchi::Tools::MissingSurface do
  let(:hooks) { Samagotchi::Hooks::Registry.new }
  let(:registry) { Samagotchi::Tools::Builtins.registry }
  let(:index) { Samagotchi::Tools::ToolIndex.new }
  let(:checks) do
    rows = [{ "id" => "fs-deny", "tool" => "mcp_fs_*", "verdict" => "deny", "reason" => "no fs" }]
    [Samagotchi::Guardrails::Rules.new(Samagotchi::Guardrails::Rules.parse(rows, source: "config"))]
  end
  let(:gate) { Samagotchi::Guardrails::Gate.new(hooks: hooks, tools: registry, checks_for: ->(_turn) { checks }) }
  let(:kernel) { test_kernel(hooks: hooks, tools: registry, gate: gate) }
  let(:call) { { name: "call_tool", args: { "tool" => "fs/read_file", "args" => { "path" => "a.txt" } } } }

  before do
    source = index.source(label: "mcp", prefix: "mcp_", call: ->(tool, _args, _ctx) { "fs ran #{tool.name}" },
                          acts_as: ->(group, tool) { "mcp_#{group}_#{tool}" })
    tool = Samagotchi::Tools::ToolIndex::Tool.new(group: "fs", name: "read_file", acts_as: "mcp_fs_read_file",
                                                  schema: { "type" => "object", "properties" => { "path" => { "type" => "string" } } })
    source.publish([Samagotchi::Tools::ToolIndex::Group.new(name: "fs", tools: [tool])])
    index.add(source)
    index.declare(registry)
  end

  def evaluate(context) = gate.evaluate(call, context: context, iteration: 1, params: "")

  it "denies call_tool by the mcp_* rule with the turn's surface, and the gate raises without one (never an allow)" do
    expect(evaluate(run_context(tools: registry))).to be_deny.and(have_attributes(rule: "fs-deny"))

    expect { evaluate(run_context) }.to raise_error(described_class)
  end

  it "fails the row loudly too: call_tool's preview without a surface raises instead of falling back to key=value" do
    expect(Samagotchi::ToolActivity.tool_activity_params("call_tool", call, registry: registry,
                                                                            surface: Samagotchi::Tools::ToolSurface.for(registry)))
      .to eq("fs/read_file path=a.txt")

    expect { Samagotchi::ToolActivity.tool_activity_params("call_tool", call, registry: registry) }
      .to raise_error(described_class)
  end

  it "stops a runner given a context without one before the gate: the call never runs" do
    ran = []
    allow(kernel).to receive(:dispatch_tool_call) { |c, *| ran << c }
    expect do
      Samagotchi::ToolRunner.new(kernel).run(call, context: run_context, iteration: 1, call_index: 1, call_count: 1,
                                                   on_stream_event: nil, max_tool_output_chars: nil)
    end.to raise_error(described_class)
    expect(ran).to eq([])
  end

  it "looks the call's entry up in the turn's surface, not the Registry now (one source per call)" do
    surface = Samagotchi::Tools::ToolSurface.for(registry)
    registry.register("late", schema: { name: "late" }, handler: ->(*) { "" }, source: "x",
                              preview: ->(_c) { "late row" }, targets: ->(_c) { { command: "late cmd" } })
    late = { name: "late", args: { "q" => "1" } }
    context = Samagotchi::Guardrails::Context.new(cwd: Dir.pwd)

    expect(Samagotchi::Guardrails::Targets.for(late, context, registry: registry, surface: surface).command).to be_nil
    expect(Samagotchi::ToolActivity.tool_activity_params("late", late, registry: registry, surface: surface)).to eq('q="1"')
    # Without a turn's surface (the bundle test kit's gate) the Registry's entry counts.
    expect(Samagotchi::Guardrails::Targets.for(late, context, registry: registry).command).to eq("late cmd")
  end
end
