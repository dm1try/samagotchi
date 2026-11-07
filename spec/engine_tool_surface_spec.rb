# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/plugin/tool_spec"
require "samagotchi/llm/chat_loop"
require "samagotchi/tools/builtins"
require "support/fake_chat_adapter"
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
    # The prompt, the toolkit's apply and the tool index read the Registry
    # as a surface of their own; the turn's is generate's (the only one
    # built with the host's loads_tools).
    allow(Samagotchi::Tools::ToolSurface).to receive(:for).and_call_original
    expect(Samagotchi::Tools::ToolSurface).to receive(:for).with(engine.tools, hash_including(:loads_tools))
                                                           .once.and_call_original

    engine.run_turn(session, "hi")

    surface = contexts.first.surface
    expect(surface).to be_a(Samagotchi::Tools::ToolSurface).and be_frozen
    expect(published).to equal(surface)
    expect(surface.declared_names).to eq(engine.tools.names)
    expect(outputs.first.last).to start_with("Error: no such tool. Available: ")
  end

  it "keeps the running turn's tools through a /toolkit change, a plugin's new tool set and a direct register; " \
     "the next turn has them" do
    sess = session(Samagotchi::Toolkit.new(name: "lean"))
    calls.replace(%w[delegate late direct])
    mid_turn << lambda do
      sess.toolkit = sess.toolkit.adding("delegate")
      late = Samagotchi::Plugin::ToolSpec.build("late", "a late tool") { "late ran" }
      engine.send(:stage_tools, "spec-bundle", [late], nil)
      # The Registry itself changes now (the two above wait for the next
      # turn anyway): the running turn still dispatches on its surface.
      engine.tools.register("direct", schema: { name: "direct", description: "a direct tool",
                                                parameters: { type: "object", properties: {} } },
                                      handler: ->(*) { "direct ran" }, source: "spec")
    end

    engine.run_turn(sess, "hi")
    engine.run_turn(sess, "again")

    first, second = contexts.map(&:surface)
    expect(first.declared_names).not_to include("delegate", "late")
    # Before and after the change, the running turn answers the same.
    expect(outputs.first.first(3)).to eq(outputs.first.last(3))
    expect(outputs.first.first).to start_with("Error: delegate isn't declared in this session (toolkit lean)")
    expect(outputs.first[1..2]).to all(start_with("Error: no such tool."))
    expect(second.declared_names).to include("delegate")
    expect(second.registered?("late")).to be(true)
    expect(second.registered?("direct")).to be(true)
    expect(outputs.last.first).to start_with("[delegate]")
  end

  it "declares in the system prompt the surface generate builds (layers, toolkit), loads_tools apart" do
    sess = session(Samagotchi::Toolkit.new(name: "lean", remove: %w[delegate]))
    sess.llm_context = Samagotchi::LLMContextOverride.new(strategy: %i[stale forget])
    prompt_surfaces = []
    builder = engine.instance_variable_get(:@prompt_builder)
    allow(builder).to receive(:build).and_wrap_original do |original, **kwargs|
      original.call(**kwargs).tap { prompt_surfaces << builder.instance_variable_get(:@last).surface }
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

# The chat path reads the same surface: a Registry change between two
# requests of one turn changes neither the second request's tools: nor
# what its calls dispatch to (ChatLoop#surface, ToolRunner#surface).
RSpec.describe Samagotchi::LLM::ChatLoop, "tool surface" do
  # A Registry of its own (the default test kernel's is shared, frozen).
  let(:kernel) { test_kernel(tools: Samagotchi::Tools::Builtins.registry) }

  it "declares and dispatches the turn's surface through a Registry change between its requests" do
    registry = kernel.tools
    register_then_call = lambda do |**|
      registry.register("late", schema: { name: "late", description: "a late tool",
                                          parameters: { type: "object", properties: {} } },
                                handler: ->(*) { "late ran" }, source: "spec")
      FakeChatAdapter.tools(["c1", "late", {}])
    end
    adapter = FakeChatAdapter.new(register_then_call, FakeChatAdapter.text("done"))
    context = run_context(settings: kernel.turn_settings)
    context = context.with(surface: Samagotchi::Tools::ToolSurface.for(registry, layers: context.llm_context_layers))

    described_class.new(kernel: kernel, adapter: adapter, sleeper: ->(_s) {})
                   .complete(messages: [{ role: "user", content: "go" }], model_name: "m",
                             on_stream_event: ->(_e) {}, context: context)

    first, second = adapter.requests
    expect(first[:tools].map { |tool| tool.dig(:function, :name) }).not_to include("late")
    expect(second[:tools]).to eq(first[:tools])
    result = second[:messages].find { |message| message[:role] == "tool" }
    expect(result[:content].to_s).to start_with("Error: no such tool.")
  end
end
