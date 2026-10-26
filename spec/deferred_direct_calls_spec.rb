# frozen_string_literal: true

require "samagotchi/tool_runner"
require "samagotchi/hooks"
require "samagotchi/kernel_loop"
require "samagotchi/guardrails"
require "samagotchi/tools/builtins"
require "samagotchi/tools/builtin_calls"
require "samagotchi/tools/tool_index"
require "samagotchi/toolkit"
require "support/test_kernel"

# A direct call of a tool the session reaches but doesn't declare, on a host
# that loads tools (TurnSettings#loads_tools; lean tools P2c, U-A): a
# built-in runs as itself through the gate, an MCP tool by its acts_as is
# wrapped into the call_tool call it stands for (D3). Without the flag the
# P2b refusal (D7) stands.
RSpec.describe "direct calls of deferred tools" do
  let(:hooks) { Samagotchi::Hooks::Registry.new }
  let(:registry) { Samagotchi::Tools::Builtins.registry }
  let(:index) { Samagotchi::Tools::ToolIndex.new }
  let(:events) { [] }
  let(:asked) { [] }
  let(:seen) { [] }
  let(:ran) { [] }
  let(:checks) { [] }
  let(:kernel) do
    test_kernel(hooks: hooks).tap do |k|
      k.tools = registry
      approver = lambda do |verdict|
        asked << [verdict.call[:name], Samagotchi::Guardrails::Approvals.key_for(verdict), verdict.rule]
        verdict.settle!(:allow)
      end
      gate = Samagotchi::Guardrails::Gate.new(-> { hooks }, approver: approver, checks_lookup: -> { checks },
                                                            tools_lookup: -> { registry })
      k.define_singleton_method(:guardrail_gate) { gate }
    end
  end

  before do
    source = index.source(label: "mcp", prefix: "mcp_", call: ->(tool, args, _ctx) { "fs ran #{tool.name} #{args.to_json}" },
                          acts_as: ->(group, tool) { "mcp_#{group}_#{tool}" })
    tool = Samagotchi::Tools::ToolIndex::Tool.new(group: "fs", name: "read_file", acts_as: "mcp_fs_read_file",
                                                  description: "Read a file.",
                                                  schema: { "type" => "object", "properties" => { "path" => { "type" => "string" } } })
    source.publish([Samagotchi::Tools::ToolIndex::Group.new(name: "fs", tools: [tool])])
    index.add(source)
    index.declare(registry)
    registry.toolkit = Samagotchi::Toolkit.new(name: "lean").resolve(Samagotchi::Toolkit.kits)
    index.refresh!
    %w[list_sessions delegate].each do |name|
      registry[name].handler = lambda { |call, _kctx|
        ran << [name, call[:via]]
        "ran #{name}"
      }
    end
    hooks.register(:before_tool_call) { |e| seen << e[:call].slice(:name, :via, :args) }
  end

  def loads_tools!(value = true)
    kernel.turn_settings = kernel.turn_settings.with(loads_tools: value)
  end

  def run(call)
    Samagotchi::ToolRunner.new(kernel).run(call, iteration: 1, call_index: 1, call_count: 1,
                                                 on_stream_event: ->(e) { events << e }, max_tool_output_chars: nil)
  end

  def rules(*rows) = checks << Samagotchi::Guardrails::Rules.new(Samagotchi::Guardrails::Rules.parse(rows, source: "config"))

  describe "a reachable built-in" do
    it "runs by its own name through the gate: the rule fires, the approval keys as a declared call's" do
      loads_tools!
      rules({ "id" => "ask-ls", "tool" => "list_sessions", "verdict" => "ask", "reason" => "sessions" })

      result = run(Samagotchi::Tools::BuiltinCalls.build("list_sessions", {}))

      expect(result.output).to eq("[list_sessions]\nran list_sessions")
      expect(seen).to eq([{ name: "list_sessions" }])
      expect(asked).to eq([["list_sessions", "list_sessions:", "ask-ls"]])
      expect(ran).to eq([["list_sessions", nil]])
      expect(events.first).to include(type: :tool_call_started, tool: "list_sessions")
    end

    it "keeps the call_tool route's approval key, so one approval covers both routes" do
      loads_tools!
      rules({ "id" => "ask-d", "tool" => "delegate", "verdict" => "ask", "reason" => "d" })

      run(Samagotchi::Tools::BuiltinCalls.build("delegate", { "task" => "x" }))
      run(Samagotchi::Tools::BuiltinCalls.build("call_tool", { "tool" => "chi/delegate", "args" => { "task" => "x" } }))

      expect(asked.map { |a| a[1] }.uniq.size).to eq(1)
      expect(ran).to eq([["delegate", nil], %w[delegate call_tool]])
    end

    it "is refused with the call_tool route (D7) when the host doesn't load tools: no hook, no card" do
      loads_tools!(false)

      result = run(Samagotchi::Tools::BuiltinCalls.build("list_sessions", {}))

      expect(result.output).to start_with("Error: list_sessions isn't declared in this session (toolkit lean); call it with")
      expect([seen, asked, ran]).to eq([[], [], []])
    end

    it "stays refused when the toolkit removes it" do
      loads_tools!
      registry.toolkit = Samagotchi::Toolkit.new(name: "lean", remove: %w[delegate]).resolve(Samagotchi::Toolkit.kits)

      result = run(Samagotchi::Tools::BuiltinCalls.build("delegate", { "task" => "x" }))

      expect(result.output).to start_with("Error: delegate isn't loaded in this session")
      expect([seen, ran]).to eq([[], []])
    end
  end

  describe "an MCP tool by its acts_as" do
    it "refuses an unreached group before hooks for either call route" do
      loads_tools!
      registry.toolkit = registry.toolkit.with(groups: [])

      direct = run(Samagotchi::Tools::BuiltinCalls.build("mcp_fs_read_file", { "path" => "a.txt" }))
      routed = run(Samagotchi::Tools::BuiltinCalls.build("call_tool", {
        "tool" => "fs/read_file", "args" => { "path" => "a.txt" }
      }))

      expect(direct.output).to eq("[mcp_fs_read_file] Error: fs/read_file isn't in this session's toolkit (lean); " \
                                  "only the user can switch (/toolkit NAME, or a kit that reaches fs).")
      expect(routed.output).to eq("[call_tool] Error: fs/read_file isn't in this session's toolkit (lean); " \
                                  "only the user can switch (/toolkit NAME, or a kit that reaches fs).")
      expect([seen, ran]).to eq([[], []])
    end

    it "lets a participant's review boundary deny before the toolkit-group refusal" do
      loads_tools!
      registry.toolkit = registry.toolkit.with(groups: [])
      kernel.participant_turn = -> { true }
      boundary = Samagotchi::Guardrails::ReviewBoundary.new(author: -> { "p:review" }, root: -> { Dir.pwd },
                                                            denied_dirs: -> { [] })
      checks << boundary

      result = run(Samagotchi::Tools::BuiltinCalls.build("call_tool", { "tool" => "fs/read_file" }))

      expect(result.output).to include("a participant's review turn may only read")
      expect(result.output).not_to include("isn't in this session's toolkit")
      expect(ran).to be_empty
    end

    it "runs as the call_tool call it stands for: its row, an mcp_* rule, call_tool's approval key" do
      loads_tools!
      rules({ "id" => "mcp-ask", "tool" => "mcp_*", "verdict" => "ask", "reason" => "mcp" })

      direct = run(Samagotchi::Tools::BuiltinCalls.build("mcp_fs_read_file", { "path" => "a.txt" }))
      routed = run(Samagotchi::Tools::BuiltinCalls.build("call_tool", { "tool" => "fs/read_file", "args" => { "path" => "a.txt" } }))

      expect(direct.output).to eq(routed.output)
      expect(direct.output).to eq("[call_tool]\nfs ran read_file {\"path\":\"a.txt\"}")
      expect(seen.first).to eq(name: "call_tool", args: { "tool" => "fs/read_file", "args" => { "path" => "a.txt" } })
      expect(asked).to eq([["call_tool", "call_tool>mcp_fs_read_file:path=a.txt", "mcp-ask"]] * 2)
      expect(events.first).to include(tool: "call_tool", label: "mcp")
      expect(direct.shown_params).to eq("fs/read_file path=a.txt")
    end

    it "is an unknown tool when the host doesn't load tools" do
      loads_tools!(false)

      result = run(Samagotchi::Tools::BuiltinCalls.build("mcp_fs_read_file", { "path" => "a.txt" }))

      expect(result.output).to start_with("Error: no such tool.")
    end
  end
end
