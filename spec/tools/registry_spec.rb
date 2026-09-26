# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/llm/chat_loop"
require "samagotchi/tools/builtins"

RSpec.describe Samagotchi::Tools::Registry do
  let(:schema) { { name: "echo", description: "echo it", parameters: { type: "object", properties: {}, required: [] } } }

  # A registry with the built-ins and one more tool, whose handler says
  # what it got.
  def extended_registry(&handler)
    Samagotchi::Tools::Builtins.registry.tap do |registry|
      registry.register("echo", schema: schema, handler: handler || ->(call, _kctx) { "echo #{call[:content]}" },
                                source: "spec")
    end
  end

  it "keeps entries in declaration order and refuses a second one with the same name" do
    registry = extended_registry
    expect(registry.names.last).to eq("echo")
    expect(registry.schemas.last).to eq(schema)
    expect(registry["echo"].core?).to be(false)
    expect { registry.register("echo", schema: schema, handler: ->(*) {}) }.to raise_error(ArgumentError)
  end

  it "unregisters a tool, and registers the name again after that" do
    registry = extended_registry
    expect(registry.unregister("echo").name).to eq("echo")
    expect(registry.key?("echo")).to be(false)
    expect(registry.unregister("echo")).to be_nil
    registry.register("echo", schema: schema, handler: ->(*) {})
    expect(registry.names.last).to eq("echo")
  end

  it "has a frozen default with the built-ins alone, and a fresh one per call" do
    default = Samagotchi::Tools::Builtins.default
    expect(default).to be_frozen
    expect(default.entries).to all(have_attributes(source: "core"))
    expect(Samagotchi::Tools::Builtins.registry).not_to be(Samagotchi::Tools::Builtins.registry)
    expect { default.register("x", schema: schema, handler: ->(*) {}) }.to raise_error(FrozenError)
  end

  describe "KernelLoop dispatch" do
    let(:kernel) { Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client), profile: :gemma4) }

    it "uses the built-ins with no registry given, and lists them for an unknown tool" do
      expect(kernel.tools).to be(Samagotchi::Tools::Builtins.default)
      result = kernel.dispatch_tool_call(name: "echo", content: "hi")
      expect(result[:output]).to eq("Error: unknown tool 'echo'. Available: #{Samagotchi::ToolDeclarations::TOOL_SCHEMAS.map { |s| s[:name] }.join(", ")}")
    end

    it "runs a set registry's handler with the call and the kernel's context" do
      seen = nil
      kernel.tools = extended_registry do |call, kctx|
        seen = [call[:content], kctx.reminder_store, kctx.peers, kctx.model_key]
        "done"
      end
      kernel.model_key = "gemma4"
      kernel.peers = :peers

      result = kernel.dispatch_tool_call(name: "echo", content: "hi")

      expect(result[:output]).to eq("[echo]\ndone")
      expect(result[:activity]).to include(tool: "echo", status: "ok")
      expect(seen).to eq(["hi", kernel.reminder_store, :peers, "gemma4"])
      expect(kernel.dispatch_tool_call(name: "echo", content: "")[:output]).to eq("[echo]\ndone")
    end

    it "turns a raising handler into the tool's Error line" do
      kernel.tools = extended_registry { |_call, _kctx| raise "boom" }
      expect(kernel.dispatch_tool_call(name: "echo", content: "")[:output]).to eq("[echo] Error: boom")
    end
  end

  it "the chat loop declares its kernel's tools, and the built-ins for a kernel without a registry" do
    kernel = Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client), profile: :gemma4)
    kernel.tools = extended_registry
    names = ->(loop) { loop.tool_definitions.map { |tool| tool[:function][:name] } }

    expect(names.call(Samagotchi::LLM::ChatLoop.new(kernel: kernel)).last).to eq("echo")
    expect(names.call(Samagotchi::LLM::ChatLoop.new(kernel: instance_double(Samagotchi::KernelLoop))))
      .to eq(Samagotchi::ToolDeclarations::TOOL_SCHEMAS.map { |s| s[:name] })
  end

  it "an Engine gives a kernel built before it (the REPL's) its own registry" do
    kernel = Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client), profile: :gemma4)
    engine = Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client), kernel: kernel,
                                    profile: :gemma4)
    expect(kernel.tools).not_to be(Samagotchi::Tools::Builtins.default)
    expect(kernel.tools.schemas).to eq(Samagotchi::ToolDeclarations::TOOL_SCHEMAS)
    expect(engine.assist_system_prompt).to include("declaration:execute{")
  end
end
