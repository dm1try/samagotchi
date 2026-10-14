# frozen_string_literal: true

require "tmpdir"
require "samagotchi/tool_runner"
require "samagotchi/hooks"
require "samagotchi/kernel_loop"
require "samagotchi/guardrails"
require "samagotchi/tools/builtins"
require "samagotchi/tools/builtin_calls"
require "samagotchi/tools/tool_index"
require "samagotchi/toolkit"
require "support/test_kernel"

# A call_tool of one of chi's own tools runs as that tool (lean tools P2b):
# ToolIndex#unwrap is ToolRunner#run's first step, so the gate, the hooks,
# the approvals and the row see the real call, with via: "call_tool".
RSpec.describe "call_tool on a built-in" do
  let(:hooks) { Samagotchi::Hooks::Registry.new }
  let(:registry) { Samagotchi::Tools::Builtins.registry }
  let(:index) { Samagotchi::Tools::ToolIndex.new.tap { |i| i.declare(registry) } }
  let(:events) { [] }
  let(:asked) { [] }
  let(:seen) { [] }
  let(:ran) { [] }
  let(:checks) { [] }
  # A kit whose list leaves execute and write out (none chi ships does):
  # the same-verdict cases.
  let(:kits) { Samagotchi::Toolkit.kits.merge("tiny" => Samagotchi::Toolkit::Kit.new(name: "tiny", tools: %w[read])) }
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
    %w[delegate execute write send_note].each do |name|
      registry[name].handler = lambda { |call, _kctx|
        ran << [name, call[:via]]
        "ran #{name}"
      }
    end
    hooks.register(:before_tool_call) { |e| seen << [e[:call][:name], e[:call][:via]] }
  end

  def toolkit!(name = "lean", **)
    registry.toolkit = Samagotchi::Toolkit.new(name: name, **).resolve(kits)
    index.refresh!
  end

  def run(call)
    Samagotchi::ToolRunner.new(kernel).run(call, iteration: 1, call_index: 1, call_count: 1,
                                                 on_stream_event: ->(e) { events << e }, max_tool_output_chars: nil)
  end

  def via(tool, args = {}) = { name: "call_tool", args: { "tool" => tool, "args" => args } }

  it "runs chi/delegate as delegate: the hooks, the row and the result see delegate, with via and no ran-as line" do
    toolkit!
    result = run(via("chi/delegate", { "task" => "look", "wait" => false }))

    expect(result[:output]).to eq("[delegate]\nran delegate")
    expect(seen).to eq([%w[delegate call_tool]])
    expect(ran).to eq([%w[delegate call_tool]])
    started = events.find { |e| e[:type] == :tool_call_started }
    expect([started[:tool], started[:via], started[:call][:content]]).to eq(%w[delegate call_tool look])
    expect(events.find { |e| e[:type] == :tool_call_completed }.dig(:activity, :via)).to eq("call_tool")
  end

  it "resolves a bare name of a reachable tool as well" do
    toolkit!
    expect(run(via("send_note", { "session" => "s", "text" => "t" }))[:output]).to eq("[send_note]\nran send_note")
  end

  it "meets the rules a direct call meets: the same verdict and the same approval key" do
    toolkit!("tiny")
    hooks.register(:before_tool_call) do |e|
      e[:guardrail].deny!("no rm", rule: "no-rm") if e[:call][:name] == "execute" && e[:call][:content].include?("rm ")
      e[:guardrail].ask!("sure?", rule: "ask-ls") if e[:call][:name] == "execute" && e[:call][:content] == "ls"
    end
    toolkit!("tiny", add: %w[execute])
    denied_direct = run({ name: "execute", content: "rm -rf x", command: "rm -rf x" })[:output]
    run({ name: "execute", content: "ls", command: "ls" })
    toolkit!("tiny")
    denied_via = run(via("chi/execute", { "command" => "rm -rf x" }))[:output]
    run(via("chi/execute", { "command" => "ls" }))

    expect(denied_via).to eq(denied_direct)
    expect(denied_via).to start_with("[execute] Error: denied by guardrail")
    expect(asked).to eq([%w[execute execute:ls ask-ls]] * 2)
    expect(ran).to eq([["execute", nil], %w[execute call_tool]])
  end

  it "meets config rules (Guardrails::Rules) as a direct call does: command: deny, rm: ask, skip_read_only" do
    checks << Samagotchi::Guardrails::Rules.new(Samagotchi::Guardrails::Rules.parse([
      { "id" => "no-push", "tool" => "execute", "command" => "git push*", "verdict" => "deny", "reason" => "no push" },
      { "id" => "rm-ask", "tool" => "execute", "rm" => "outside_tmp", "verdict" => "ask", "reason" => "rm" },
      { "id" => "shell-ask", "tool" => "execute", "skip_read_only" => true, "verdict" => "ask", "reason" => "shell" },
      { "id" => "via-ask", "tool" => "call_tool", "verdict" => "ask", "reason" => "call_tool" }
    ], source: "config"))
    commands = ["git push origin main", "rm -rf ~/x", "ls -la", "touch y"]
    outcome = lambda do |direct|
      asked.clear
      outputs = commands.map do |command|
        call = direct ? { name: "execute", content: command, command: command } : via("chi/execute", { "command" => command })
        run(call)[:output]
      end
      [outputs, asked.dup]
    end

    toolkit!("tiny", add: %w[execute])
    direct = outcome.call(true)
    toolkit!("tiny")
    unwrapped = outcome.call(false)

    expect(unwrapped).to eq(direct)
    outputs, approvals = unwrapped
    expect(outputs.first).to start_with("[execute] Error: denied by guardrail (rule no-push, config): no push.")
    # rm and touch ask (by their rule, keyed as execute), ls is read-only; call_tool's rule never fires.
    expect(approvals).to eq([["execute", "execute:rm -rf ~/x", "rm-ask"], ["execute", "execute:touch y", "shell-ask"]])
  end

  it "asks a delegate child's boundary about a write outside its folder, as for a direct write" do
    Dir.mktmpdir do |root|
      checks << Samagotchi::Guardrails::ChildBoundary.new(root: -> { root }, worktrees: -> { [] }, common_dir: -> {},
                                                          branch: -> {})
      toolkit!("tiny")
      outside = File.join(File.dirname(root), "beside-#{File.basename(root)}.txt")
      run(via("chi/write", { "path" => outside, "content" => "x" }))
      toolkit!("tiny", add: %w[write])
      run({ name: "write", path: outside, content: "x" })
      expect(asked.map(&:first)).to eq(%w[write write])
      expect(asked.map(&:last).uniq).to eq([Samagotchi::Guardrails::ChildBoundary::RULE])
      expect(asked.map { |a| a[1] }.uniq.size).to eq(1)
    end
  end

  describe "refused by its name before the gate: no hook, no card, never dispatched" do
    it "a tool the toolkit removes (child's memory_write, a /toolkit remove)" do
      toolkit!("child")
      result = run(via("chi/memory_write", { "name" => "x", "scope" => "project", "content" => "y" }))
      expect(result[:output]).to start_with("Error: memory_write isn't loaded in this session (toolkit child) and " \
                                            "can't be loaded from here; only the user can (/toolkit add memory_write).")
      toolkit!("child")
      expect(run(via("chi/delegate", { "task" => "x" }))[:output]).to start_with("Error: delegate isn't loaded")
      toolkit!(remove: %w[delegate])
      expect(run(via("chi/delegate", { "task" => "x" }))[:output]).to start_with("Error: delegate isn't loaded")
      # A remove after an add is hard (D12).
      toolkit!(add: %w[delegate], remove: %w[delegate])
      expect(run(via("chi/delegate", { "task" => "x" }))[:output]).to start_with("Error: delegate isn't loaded")
      expect([seen, asked, ran]).to eq([[], [], []])
    end

    it "every built-in when the toolkit removes call_tool itself (B1)" do
      toolkit!(remove: %w[call_tool])
      result = run(via("chi/delegate", { "task" => "x" }))
      expect(result[:output]).to start_with("Error: call_tool isn't loaded in this session (toolkit lean)")
      expect([seen, asked, ran]).to eq([[], [], []])
    end

    it "a direct call of a reachable tool, told the call_tool route (D7)" do
      toolkit!
      result = run({ name: "delegate", content: "x", task: "x" })
      expect(result[:output]).to start_with("Error: delegate isn't declared in this session (toolkit lean); call it with " \
                                            "call_tool(tool: \"chi/delegate\", args: {…}) (find_tools gives its " \
                                            "inputSchema). Available: execute, read")
      expect([seen, asked, ran]).to eq([[], [], []])
    end

    it "a chi/ call of a tool the toolkit declares, told to call it directly" do
      toolkit!("tiny")
      registry["read"].handler = ->(*) { raise "never" }
      expect(run(via("chi/read", { "path" => "x" }))[:output]).to start_with("Error: read is declared in this session " \
                                                                             "(toolkit tiny); call it directly.")
      expect(seen).to eq([])
    end
  end

  it "keeps call_tool working with find_tools removed alone" do
    toolkit!(remove: %w[find_tools])
    expect(registry.names).to include("call_tool")
    expect(run(via("chi/delegate", { "task" => "x" }))[:output]).to eq("[delegate]\nran delegate")
  end

  it "refuses a hook's rewrite to a removed tool, or one that drops via:, by its name (N4)" do
    toolkit!(remove: %w[send_note])
    hooks.register(:before_tool_call) { |e| e[:call] = e[:call].merge(name: "send_note") }
    expect(run(via("chi/delegate", { "task" => "x" }))[:output])
      .to start_with("ran as: send_note").and include("\nError: send_note isn't loaded")

    hooks2 = Samagotchi::Hooks::Registry.new
    hooks2.register(:before_tool_call) { |e| e[:call] = e[:call].except(:via) }
    allow(kernel).to receive(:hooks).and_return(hooks2)
    gate = Samagotchi::Guardrails::Gate.new(-> { hooks2 })
    kernel.define_singleton_method(:guardrail_gate) { gate }
    toolkit!
    expect(run(via("chi/delegate", { "task" => "x" }))[:output]).to include("\nError: delegate isn't declared")
    expect(ran).to eq([])
  end

  it "can't be faked by a model: a parsed call never carries via:" do
    expect(Samagotchi::Tools::BuiltinCalls.build("delegate", { "task" => "x", "via" => "call_tool" })).not_to have_key(:via)
  end

  it "runs an MCP tool or a miss as call_tool, as before" do
    toolkit!
    expect(run(via("zebra/nope"))[:output]).to start_with("[call_tool]\nError: no tool zebra/nope.")
    expect(seen).to eq([["call_tool", nil]])
  end
end
