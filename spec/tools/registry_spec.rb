# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/llm/chat_loop"
require "samagotchi/tools/builtins"
require "samagotchi/plugin/api"
require "samagotchi/toolkit"

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

  # The tool list is part of the prompt's cached prefix: it must not
  # depend on which plugin's init finished first.
  describe "bundle tools' order" do
    def spec_for(name, description = "does #{name}") = Samagotchi::Plugin::ToolSpec.build(name, description) { "ok" }

    def apply(registry, bundle, *names, description: nil)
      specs = names.map { |name| description ? spec_for(name, description) : spec_for(name) }
      Samagotchi::Plugin::ToolSpec.apply(registry, bundle, specs, nil)
    end

    it "is by bundle and name after the built-ins, whichever plugin applied its tools first" do
      first = Samagotchi::Tools::Builtins.registry
      apply(first, "mcp", "mcp_zeta", "mcp_alpha")
      apply(first, "check-in", "checkin_wait")
      second = Samagotchi::Tools::Builtins.registry
      apply(second, "check-in", "checkin_wait")
      apply(second, "mcp", "mcp_alpha", "mcp_zeta")

      builtins = Samagotchi::Tools::Builtins.default.names
      expect(first.names).to eq(builtins + %w[checkin_wait mcp_alpha mcp_zeta])
      expect(second.schemas).to eq(first.schemas)
      expect(Samagotchi::ToolDeclarations.native_schemas(second)).to eq(Samagotchi::ToolDeclarations.native_schemas(first))
    end

    it "keeps a changed tool in its place" do
      registry = Samagotchi::Tools::Builtins.registry
      apply(registry, "mcp", "mcp_alpha", "mcp_zeta")
      expect(apply(registry, "mcp", "mcp_alpha", "mcp_zeta", description: "changed")[:changed]).to be(true)
      expect(registry.names.last(2)).to eq(%w[mcp_alpha mcp_zeta])
      expect(registry["mcp_alpha"].schema[:description]).to eq("changed")
    end
  end

  describe "a tool gated by an LLM context layer" do
    def gated_registry
      extended_registry.tap do |registry|
        registry.register("tidy", schema: schema.merge(name: "tidy"), handler: ->(*) { "tidied" }, layer: :forget)
      end
    end

    it "is offered only to a turn under its layer, after the other built-ins, before the bundles' tools" do
      registry = gated_registry
      builtins = Samagotchi::Tools::Builtins.default.names
      expect(registry.names).to eq(builtins + %w[echo])
      expect(registry.schemas).not_to include(include(name: "tidy"))
      expect(registry.names(layers: [:stale])).to eq(builtins + %w[echo])
      expect(registry.names(layers: %i[stale forget])).to eq(builtins + %w[forget_outputs tidy echo])
      expect(Samagotchi::ToolDeclarations.native_schemas(registry, layers: [:forget]).map { |s| s[:name] }).to include("tidy")
      expect(registry.offered("tidy")).to be_nil
      expect(registry.offered("tidy", layers: [:forget]).name).to eq("tidy")
      expect(registry.offered("echo").name).to eq("echo")
    end

    it "is an unknown tool to the kernel and missing from the chat tools unless the turn runs under its layer" do
      kernel = Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client), profile: :gemma4)
      kernel.tools = gated_registry
      chat = Samagotchi::LLM::ChatLoop.new(kernel: kernel)
      names = -> { chat.tool_definitions.map { |tool| tool[:function][:name] } }

      expect(kernel.dispatch_tool_call(name: "tidy", content: "")[:output]).to start_with("Error: no such tool. Available:")
      expect(kernel.dispatch_tool_call(name: "tidy", content: "")[:output]).not_to include("tidy")
      expect(names.call).not_to include("tidy")

      resolved = Samagotchi::LLMContextStrategy::Resolved.new(layers: %i[stale forget], strategy: %i[stale forget],
                                                              source: :config)
      kernel.turn_settings = kernel.turn_settings.with(llm_context: resolved)
      expect(kernel.dispatch_tool_call(name: "tidy", content: "")[:output]).to eq("[tidy]\ntidied")
      expect(names.call).to include("tidy")
    end
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
      expect(result[:output]).to eq("Error: no such tool. Available: #{Samagotchi::ToolDeclarations::TOOL_SCHEMAS.map { |s| s[:name] }.join(", ")}")
      expect(result[:output]).not_to include("echo")
    end

    it "points a shell-like name at execute (case-insensitively), and lists the tools when execute is not offered" do
      %w[run Run].each do |name|
        expect(kernel.dispatch_tool_call(name: name, content: "ls")[:output])
          .to eq("Error: no such tool. Shell commands run with `execute` (same arguments).")
      end

      no_execute = kernel.tools.entries.reject { |entry| entry.name == "execute" }
      registry = described_class.new
      no_execute.each do |entry|
        registry.register(entry.name, schema: entry.schema, handler: entry.handler, label: entry.label,
                                    preview: entry.preview, targets: entry.targets, source: entry.source, layer: entry.layer)
      end
      kernel.tools = registry
      expect(kernel.dispatch_tool_call(name: "run", content: "ls")[:output]).to start_with("Error: no such tool. Available:")
      expect(kernel.dispatch_tool_call(name: "run", content: "ls")[:output]).not_to include("run")
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

  it "the chat loop declares its kernel's tools" do
    kernel = Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client), profile: :gemma4)
    kernel.tools = extended_registry
    names = ->(loop) { loop.tool_definitions.map { |tool| tool[:function][:name] } }

    expect(names.call(Samagotchi::LLM::ChatLoop.new(kernel: kernel)).last).to eq("echo")
    kernel.tools.toolkit = Samagotchi::Toolkit.new(name: "lean").resolve(Samagotchi::Toolkit.kits)
    expect(names.call(Samagotchi::LLM::ChatLoop.new(kernel: kernel))).to eq(kernel.tools.names)
    expect(names.call(Samagotchi::LLM::ChatLoop.new(kernel: kernel))).not_to include("delegate")
  end

  it "an Engine gives a kernel it is given its own registry" do
    kernel = Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client), profile: :gemma4)
    engine = Samagotchi::Engine.new(client: instance_double(Samagotchi::Client), kernel: kernel,
                                    profile: :gemma4)
    expect(kernel.tools).not_to be(Samagotchi::Tools::Builtins.default)
    expect(kernel.tools.schemas).to eq(Samagotchi::ToolDeclarations::TOOL_SCHEMAS)
    expect(engine.assist_system_prompt).to include("declaration:execute{")
  end

  describe "the session's toolkit" do
    let(:lean) { Samagotchi::Toolkit.new(name: "lean").resolve(Samagotchi::Toolkit.kits) }

    it "filters the declared tools by the toolkit and the turn's layers" do
      registry = extended_registry
      registry.toolkit = lean
      expect(registry.names).not_to include("delegate", "forget_outputs")
      expect(registry.names).to include("execute", "echo")
      expect(registry.names(layers: [:forget])).to include("forget_outputs")
      expect(registry.schemas.map { |schema| schema[:name] }).to eq(registry.names)
      expect(Samagotchi::ToolDeclarations.native_schemas(registry).map { |schema| schema[:name] }).to eq(registry.names)
    end

    it "doesn't offer a left-out tool, and says it is one" do
      registry = extended_registry
      registry.toolkit = lean
      expect(registry.offered("delegate")).to be_nil
      expect(registry.left_out("delegate")&.name).to eq("delegate")
      expect(registry.left_out("execute")).to be_nil
      expect(registry.left_out("nope")).to be_nil
      expect(registry.left_out_names).to eq(%w[register_reminder cancel_reminder list_reminders list_sessions send_note
                                               delegate delegate_result])
      expect(registry["delegate"]).not_to be_nil
    end

    describe "what the tool index reaches" do
      let(:registry) do
        extended_registry.tap do |registry|
          registry.register("call_tool", schema: schema.merge(name: "call_tool"), handler: ->(*) { "" }, source: "index")
          registry.index = described_class::Index.new(source: "index", call_name: "call_tool", sourced: true)
        end
      end

      def kit(name = "lean", **) = Samagotchi::Toolkit.new(name: name, **).resolve(Samagotchi::Toolkit.kits)

      it "is a built-in the kit's list leaves out; a removed one is the user's to bring back" do
        registry.toolkit = kit(remove: %w[delegate echo])
        expect(registry.reachable_names).to eq(%w[register_reminder cancel_reminder list_reminders list_sessions send_note
                                                  delegate_result])
        expect(registry.removed_names).to eq(%w[delegate echo])
        expect(registry.indexed("send_note")&.name).to eq("send_note")
        expect(registry.indexed("delegate")).to be_nil
        expect(registry.indexed("execute")).to be_nil
        expect(registry.indexed("forget_outputs", layers: [:forget])).to be_nil
      end

      it "declares the index's tools when they reach something, on full (nil) and a resolved toolkit alike" do
        registry.register("find_tools", schema: schema.merge(name: "find_tools"), handler: ->(*) { "" }, source: "index")
        registry.index = described_class::Index.new(source: "index", call_name: "call_tool", sourced: false)
        expect(registry.names).not_to include("find_tools", "call_tool")
        expect(registry.names(toolkit: kit("full"))).not_to include("find_tools", "call_tool")
        expect(registry.left_out_names).to eq([])
        expect(registry.names(toolkit: kit)).to include("find_tools", "call_tool")
        expect(registry.left_out_names(toolkit: kit)).not_to include("find_tools", "call_tool")
        expect(registry.left_out_names(toolkit: kit(remove: %w[call_tool]))).to include("call_tool")

        # call_tool removed: nothing is reachable, so no find_tools either.
        expect(registry.names(toolkit: kit(remove: %w[call_tool]))).not_to include("find_tools", "call_tool")
        expect(registry.left_out_names(toolkit: kit(remove: %w[call_tool]))).to include("call_tool")
        expect(registry.left_out_names(toolkit: kit(remove: %w[call_tool]))).not_to include("find_tools")

        registry.index = registry.index.with(sourced: true) # an MCP server at load: every toolkit
        expect(registry.names).to include("find_tools", "call_tool")
        expect(registry.names(toolkit: kit(remove: %w[find_tools]))).to eq(registry.names(toolkit: kit) - ["find_tools"])
        expect(registry.names(toolkit: kit(remove: %w[call_tool]))).to include("find_tools") # MCP's, as on main
      end

      it "is nothing when the toolkit removes call_tool, or on full" do
        registry.toolkit = kit(remove: %w[call_tool])
        expect(registry.reachable_names).to eq([])
        expect(registry.indexed("send_note")).to be_nil
        registry.toolkit = nil
        expect(registry.reachable_names).to eq([])
        expect(registry.removed_names).to eq([])
      end
    end

    it "declares everything with none (full), as before" do
      registry = extended_registry
      expect(registry.schemas).to eq(Samagotchi::ToolDeclarations::TOOL_SCHEMAS + [schema])
      expect(registry.left_out_names).to eq([])
    end

    it "lets a plugin change a tool the toolkit leaves out" do
      registry = Samagotchi::Tools::Builtins.registry
      spec = ->(description) { Samagotchi::Plugin::ToolSpec.build("mcp_alpha", description) { "ok" } }
      Samagotchi::Plugin::ToolSpec.apply(registry, "mcp", [spec.call("one")], nil)
      registry.toolkit = Samagotchi::Toolkit.new(name: "lean", remove: ["mcp_alpha"]).resolve(Samagotchi::Toolkit.kits)
      expect(Samagotchi::Plugin::ToolSpec.apply(registry, "mcp", [spec.call("two")], nil)[:changed]).to be(true)
      expect(registry["mcp_alpha"].schema[:description]).to eq("two")
      expect(Samagotchi::Plugin::ToolSpec.apply(registry, "mcp", [], nil)[:changed]).to be(true)
      expect(registry["mcp_alpha"]).to be_nil
    end
  end
end
