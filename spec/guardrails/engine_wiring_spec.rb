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
end
