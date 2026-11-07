# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/plugin/tool_spec"
require "support/thinking_off"
require "support/test_kernel"

# The turn's tools (Tools::ToolSurface) are built once, in Engine#generate,
# into TurnContext#surface: every call of the turn dispatches on it, a
# change made while the turn runs shapes the next turn's surface only, and
# it is the surface the turn's system prompt declared (arch P3.4, r2 item
# 9: the prompt is built in turn_messages, before generate knows
# loads_tools).
RSpec.describe Samagotchi::Engine, "tool surface" do
  include_context "thinking off"

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:contexts) { [] }
  let(:sent) { [] }
  # Per turn, the calls the stubbed kernel dispatches (name → output).
  let(:calls) { [] }
  let(:outputs) { [] }
  let(:mid_turn) { [] }

  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run) do |messages, context:, **|
      contexts << context
      sent << messages
      turn_outputs = calls.map { |name| kernel.dispatch_tool_call({ name: name, args: {} }, context)[:output] }
      mid_turn.shift&.call
      turn_outputs += calls.map { |name| kernel.dispatch_tool_call({ name: name, args: {} }, context)[:output] }
      outputs << turn_outputs
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [])
    end
  end

  def session(toolkit = nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd).tap do |s|
      s.toolkit = toolkit
    end
  end

  it "builds one frozen surface per turn in generate, published with the turn's context" do
    published = nil
    calls.replace(%w[read nope])
    mid_turn << -> { published = engine.send(:turn_context).surface }
    expect(Samagotchi::Tools::ToolSurface).to receive(:for).once.and_call_original

    engine.run_turn(session, "hi")

    surface = contexts.first.surface
    expect(surface).to be_a(Samagotchi::Tools::ToolSurface).and be_frozen
    expect(published).to equal(surface)
    expect(surface.declared_names).to eq(engine.tools.names)
    expect(outputs.first.last).to start_with("Error: no such tool. Available: ")
  end

  it "keeps the running turn's tools through a /toolkit change and a plugin's new tool set; the next turn has them" do
    sess = session(Samagotchi::Toolkit.new(name: "lean"))
    calls.replace(%w[delegate late])
    mid_turn << lambda do
      sess.toolkit = sess.toolkit.adding("delegate")
      late = Samagotchi::Plugin::ToolSpec.build("late", "a late tool") { "late ran" }
      engine.send(:stage_tools, "spec-bundle", [late], nil)
    end

    engine.run_turn(sess, "hi")
    engine.run_turn(sess, "again")

    first, second = contexts.map(&:surface)
    expect(first.declared_names).not_to include("delegate", "late")
    # Before and after the change, the running turn answers the same.
    expect(outputs.first.first(2)).to eq(outputs.first.last(2))
    expect(outputs.first.first).to start_with("Error: delegate isn't declared in this session (toolkit lean)")
    expect(outputs.first[1]).to start_with("Error: no such tool.")
    expect(second.declared_names).to include("delegate")
    expect(second.registered?("late")).to be(true)
    expect(outputs.last.first).to start_with("[delegate]")
  end

  it "declares in the system prompt the surface generate builds (layers, toolkit), loads_tools apart" do
    sess = session(Samagotchi::Toolkit.new(name: "lean", remove: %w[delegate]))
    sess.llm_context = Samagotchi::LLMContextOverride.new(strategy: %i[stale forget])
    prompt_surfaces = []
    builder = engine.instance_variable_get(:@prompt_builder)
    allow(builder).to receive(:build).and_wrap_original do |original, **kwargs|
      prompt_surfaces << Samagotchi::Tools::ToolSurface.for(engine.tools, layers: kwargs[:layers])
      original.call(**kwargs)
    end

    engine.run_turn(sess, "hi")

    surface = contexts.first.surface
    expect(prompt_surfaces).not_to be_empty
    expect(prompt_surfaces.map { |s| s.to_h.except(:loads_tools) }.uniq).to eq([surface.to_h.except(:loads_tools)])
    expect(surface.layers).to include(:forget)
    expect(surface.declared_names).to include("forget_outputs")
    expect(surface.left_out).to include("delegate" => :user_only)
    native = Samagotchi::ToolDeclarations.gemma_declarations(
      surface.declared.map { |e| e.core? ? e.schema : Samagotchi::ToolDeclarations.flat_schema(e.schema) }
    )
    expect(sent.first.first[:content]).to include(native)
  end
end
