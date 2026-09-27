# frozen_string_literal: true

require "samagotchi/engine"

RSpec.describe "Engine guardrail wiring" do
  let(:engine) { Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client)) }

  it "defaults the interface to non_interactive and validates it" do
    expect(engine.interface).to eq(:non_interactive)
    engine.interface = :worker
    expect(engine.interface).to eq(:worker)
    expect { engine.interface = :nope }.to raise_error(ArgumentError)
  end

  it "gives its kernel a gate whose context names the session, the interface and the cwd" do
    engine.interface = :repl
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    engine.session = session
    gate = engine.instance_variable_get(:@kernel).guardrail_gate
    expect(gate).to be_a(Samagotchi::Guardrails::Gate)
    ctx = engine.guardrail_context
    expect([ctx.session_id, ctx.interface, ctx.cwd]).to eq([session.id, :repl, Dir.pwd])
  end

  it "runs the Engine's hooks through the kernel's gate" do
    engine.register_hook(:before_tool_call) { |e| e[:guardrail].deny!("no") }
    gate = engine.instance_variable_get(:@kernel).guardrail_gate
    expect(gate.evaluate({ name: "execute", content: "ls" }, iteration: 1, params: "")).to be_deny
  end

  describe "#request_approval" do
    def asking(engine)
      v = Samagotchi::Guardrails::Verdict.new(call: { name: "execute", content: "git push" })
      v.ask!("pushes", rule: "git-push", source: "config", scopes: %w[once repo])
      v.context = engine.guardrail_context
      v.targets = Samagotchi::Guardrails::Targets.for(v.call, v.context)
      v
    end

    def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    it "denies at once in a non-interactive run" do
      v = engine.request_approval(asking(engine))
      expect(v).to be_deny
      expect(v.deny_text).to include("No one to approve it (non-interactive run).")
      expect(engine.pending_question).to be_nil
    end

    it "asks through the question flow in a worker and allows the picked scope" do
      engine.interface = :worker
      result = nil
      thread = Thread.new { result = engine.request_approval(asking(engine)) }
      deadline = mono + 2
      sleep(0.005) while engine.pending_question.nil? && mono < deadline
      pending = engine.pending_question
      expect(pending).to include(kind: "approval", header: "Approve tool call?")
      expect(pending[:approval]).to include(command: "git push", rule: "git-push", scopes: %w[once repo])
      engine.answer_question(id: pending[:id], selected: [pending[:options][1]])
      thread.join(2)
      expect([result.decision, result.scope]).to eq([:allow, "repo"])
    end

    it "asks about a plugin tool by its label, as its row shows it" do
      engine.interface = :worker
      engine.instance_variable_get(:@tools).register("mcp_x_echo", schema: { name: "mcp_x_echo" }, handler: ->(*) { "" },
                                                                   label: "x: echo", source: "mcp")
      v = Samagotchi::Guardrails::Verdict.new(call: { name: "mcp_x_echo", args: { "message" => "hi" } })
      v.ask!("an MCP tool", rule: "mcp-ask", source: "config", scopes: %w[once])
      v.context = engine.guardrail_context
      v.targets = Samagotchi::Guardrails::Targets.for(v.call, v.context)
      thread = Thread.new { engine.request_approval(v) }
      deadline = mono + 2
      sleep(0.005) while engine.pending_question.nil? && mono < deadline
      pending = engine.pending_question
      expect(pending[:approval]).to include(tool: "mcp_x_echo", label: "x: echo")
      expect(pending[:question].lines.first).to start_with("x: echo: ")
      engine.cancel_question("dismissed", id: pending[:id])
      thread.join(2)
    end

    it "denies when the worker's question is dismissed" do
      engine.interface = :worker
      result = nil
      thread = Thread.new { result = engine.request_approval(asking(engine)) }
      deadline = mono + 2
      sleep(0.005) while engine.pending_question.nil? && mono < deadline
      engine.cancel_question("dismissed", id: engine.pending_question[:id])
      thread.join(2)
      expect(result.deny_text).to include("The approval was cancelled.")
    end
  end
end
