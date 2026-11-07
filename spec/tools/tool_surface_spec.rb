# frozen_string_literal: true

require "samagotchi/tools/builtins"
require "samagotchi/tools/tool_index"
require "samagotchi/tools/tool_surface"
require "samagotchi/toolkit"
require "samagotchi/turn_context"
require "samagotchi/llm/turn_settings"

# One turn's tools as a frozen value, computed from the Registry alone:
# each answer is the Registry's (the loops asked it before ToolSurface).
RSpec.describe Samagotchi::Tools::ToolSurface do
  let(:registry) { Samagotchi::Tools::Builtins.registry }
  let(:index) { Samagotchi::Tools::ToolIndex.new }

  def toolkit!(name = "lean", **)
    registry.toolkit = Samagotchi::Toolkit.new(name: name, **).resolve(Samagotchi::Toolkit.kits)
    index.refresh!
  end

  def surface(layers: [], loads_tools: false) = described_class.for(registry, layers: layers, loads_tools: loads_tools)

  # lean, with call_tool reaching the left-out built-ins and delegate removed.
  before do
    index.declare(registry)
    toolkit!(remove: %w[delegate])
  end

  it "holds what the Registry declares, reaches and leaves out, in declaration order" do
    s = surface
    expect(s.declared_names).to eq(registry.names)
    expect(s.schemas).to eq(registry.schemas)
    expect(s.index_only.map(&:name)).to eq(registry.reachable_names)
    expect(s.left_out.keys).to eq(registry.left_out_names)
    expect(s.left_out["delegate"]).to eq(:user_only)
    expect(s.left_out["register_reminder"]).to eq(:indexed)
    expect(s.toolkit).to equal(registry.toolkit)
    expect(s.index).to equal(registry.index)
    expect(s.registered?("delegate")).to be(true)
    expect(s.registered?("nope")).to be(false)
  end

  it "follows the turn's layers: a layer's tool is declared under it only" do
    expect(surface.declared_names).not_to include("forget_outputs")
    under = surface(layers: [:forget])
    expect(under.declared_names).to eq(registry.names(layers: [:forget]))
    expect(under.declared_names).to include("forget_outputs")
    expect(under.layers).to eq([:forget])
  end

  it "is frozen, down to its lists" do
    s = surface
    expect(s).to be_frozen
    expect([s.declared, s.index_only, s.left_out, s.registered, s.layers]).to all(be_frozen)
  end

  it "keeps what it saw: a later Registry change shapes only a surface built after it" do
    s = surface
    registry.toolkit = Samagotchi::Toolkit.new(name: "lean").adding("register_reminder").resolve(Samagotchi::Toolkit.kits)
    registry.register("late", schema: { name: "late", description: "late", parameters: { type: "object", properties: {} } },
                              handler: ->(*) { "late" }, source: "spec")

    expect(s.declared_names).not_to include("register_reminder", "late")
    expect(s.entry_for(name: "late")).to be_nil
    expect(surface.declared_names).to include("register_reminder")
    expect(surface.entry_for(name: "register_reminder")&.name).to eq("register_reminder")
  end

  describe "#entry_for" do
    it "runs a declared tool by its name, a reachable one only via call_tool, unless the host loads tools" do
      expect(surface.entry_for(name: "read")).to equal(registry["read"])
      expect(surface.entry_for(name: "register_reminder")).to be_nil
      expect(surface.entry_for(name: "register_reminder", via: "call_tool")).to equal(registry["register_reminder"])
      expect(surface(loads_tools: true).entry_for(name: "register_reminder")).to equal(registry["register_reminder"])
    end

    it "never runs a removed tool, nor a declared one reached via call_tool" do
      expect(surface(loads_tools: true).entry_for(name: "delegate")).to be_nil
      expect(surface.entry_for(name: "delegate", via: "call_tool")).to be_nil
      expect(surface.entry_for(name: "read", via: "call_tool")).to be_nil
    end
  end

  describe "#unknown_tool_error" do
    let(:available) { registry.names.join(", ") }

    it "words each case as KernelLoop did" do
      s = surface
      expect(s.unknown_tool_error("read", via: "call_tool"))
        .to eq("Error: read is declared in this session (toolkit lean); call it directly. Available: #{available}")
      expect(s.unknown_tool_error("register_reminder"))
        .to eq("Error: register_reminder isn't declared in this session (toolkit lean); call it with " \
               "call_tool(tool: \"chi/register_reminder\", args: {…}) (find_tools gives its inputSchema). " \
               "Available: #{available}")
      expect(s.unknown_tool_error("delegate"))
        .to eq("Error: delegate isn't loaded in this session (toolkit lean) and can't be loaded from here; only the " \
               "user can (/toolkit add delegate). Available: #{available}")
      expect(s.unknown_tool_error("bash")).to eq("Error: no such tool. Shell commands run with `execute` (same arguments).")
      expect(s.unknown_tool_error("nope")).to eq("Error: no such tool. Available: #{available}")
    end

    it "names no toolkit on full" do
      registry.toolkit = nil
      expect(surface.unknown_tool_error("read", via: "call_tool")).to start_with("Error: read is declared in this session; ")
    end
  end

  it "defers what call_tool reaches, then the history's loaded names as stubs" do
    conversation = [{ role: "tool_response", loaded: %w[read gone] }]
    deferred = surface.deferred_for(conversation)
    expect(deferred.map(&:name)).to eq(registry.reachable_names + %w[gone])
    expect(deferred.last.description).to eq(Samagotchi::Tools::DeferredTools::STUB_DESCRIPTION)
  end

  it "is empty without a registry" do
    s = described_class.for(nil)
    expect([s.declared, s.index_only, s.left_out.to_a]).to all(be_empty)
    expect(s.entry_for(name: "read")).to be_nil
    expect(s.unknown_tool_error("read")).to eq("Error: no such tool. Available: ")
  end

  describe ".of" do
    it "takes the context's surface, else computes one from the registry under its layers and loads_tools" do
      built = surface
      expect(described_class.of(Samagotchi::TurnContext.none(surface: built), registry)).to equal(built)

      settings = Samagotchi::LLM::TurnSettings.none.with(loads_tools: true)
      computed = described_class.of(Samagotchi::TurnContext.none(settings: settings), registry)
      expect(computed).not_to equal(built)
      expect(computed.loads_tools).to be(true)
      expect(computed.declared_names).to eq(built.declared_names)
    end
  end
end
