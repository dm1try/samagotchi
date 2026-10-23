# frozen_string_literal: true

require "spec_helper"
require "samagotchi/guardrails"
require "samagotchi/tools/builtins"
require "samagotchi/tools/tool_index"
require "samagotchi/plugin/api"
require "samagotchi/plugin/loader"
require "samagotchi/tool_activity"
require "samagotchi/toolkit"

# chi's tool index (Tools::ToolIndex): what a source publishes, and the
# search and call tools it declares. The search and its texts run against
# the mcp bundle in mcp_bundle_spec and mcp_bundle_golden_spec.
RSpec.describe Samagotchi::Tools::ToolIndex do
  let(:index) { described_class.new }
  let(:registry) { Samagotchi::Tools::Builtins.registry }
  let(:calls) { [] }
  let(:context) { Object.new }
  let(:find_name) { described_class::FIND_NAME }
  let(:call_name) { described_class::CALL_NAME }
  let(:echo) do
    tool("fs", "echo", description: "Echo the text.",
                       schema: { "type" => "object", "properties" => { "n" => { "type" => "integer" } } })
  end

  def tool(group, name, **) = described_class::Tool.new(group: group, name: name, acts_as: "mcp_#{group}_#{name}", **)

  def source(**)
    index.source(label: "mcp", prefix: "mcp_", context: context, acts_as: ->(group, name) { "mcp_#{group}_#{name}" },
                 call: lambda { |tool, args, ctx|
                   calls << [tool.full_name, args, ctx]
                   "ran #{tool.name}"
                 }, **)
  end

  def added(**) = source(**).tap { |s| index.add(s) }

  context "without a source" do
    it "registers both, declared only when the toolkit leaves a built-in reachable: full's tools are the ones it had" do
      before = registry.names
      expect(index.declare(registry)).to eq([find_name, call_name])
      expect(registry.names).to eq(before)
      expect(registry.left_out_names).to eq([])

      registry.toolkit = Samagotchi::Toolkit.new(name: "lean").resolve(Samagotchi::Toolkit.kits)
      expect(registry.names).to include(find_name, call_name)
      expect(registry.left_out_names).not_to include(find_name, call_name)
      expect(registry[call_name].label).to be_nil
    end
  end

  context "with a source" do
    let!(:fs) do
      added.tap do |s|
        s.publish([described_class::Group.new(name: "fs", summary: "files", tools: [echo]),
                   described_class::Group.new(name: "slow", state: :starting)])
      end
    end
    let(:find_entry) { registry[find_name] }
    let(:call_entry) { registry[call_name] }

    before { index.declare(registry) }

    it "registers the search and the call tool as the index's, not core's, the call labelled by its source" do
      expect([find_entry.source, call_entry.source]).to eq(%w[index index])
      expect(find_entry.core?).to be(false)
      expect(call_entry.label).to eq("mcp")
      expect(fs.declared_names).to eq([find_name, call_name])
      expect(fs.declared_tokens).to be > 50
    end

    it "describes a starting group by its name only, never with a tool list frozen empty, and keeps the description" do
      expect(find_entry.schema[:description]).to end_with("\nGroups:\n- fs: files (1 tool)\n- slow")
      fs.publish([described_class::Group.new(name: "fs", summary: "files", tools: [echo]),
                  described_class::Group.new(name: "slow", tools: [tool("slow", "wait")])])
      expect(registry[find_name].schema[:description]).to end_with("\n- slow") # declared once
      expect(index.find("wait")).to include("slow/wait: ") # searches read what is published now
    end

    it "runs a call with its source's Context and the arguments typed by the tool's schema" do
      expect(call_entry.handler.call({ name: call_name, args: { "tool" => "fs/echo", "args" => { "n" => "2" } } }, nil))
        .to eq("ran echo")
      expect(calls).to eq([["fs/echo", { "n" => 2 }, context]])
    end

    it "passes a source's ToolResult on, images and all" do
      result = Samagotchi::Plugin::ToolResult.new("shot", images: [{ path: "/tmp/a.png", name: "a.png" }])
      index.instance_variable_get(:@sources).first.instance_variable_set(:@call, ->(*) { result })
      expect(call_entry.handler.call({ name: call_name, args: { "tool" => "fs/echo" } }, nil)).to be(result)
    end

    it "refuses a published refusal before the source sees the call" do
      fs.publish([described_class::Group.new(name: "fs", tools: [echo.with(refusal: "bad schema", mark: "(bad schema)")])])
      expect(index.call("fs/echo", {})).to eq("Error: fs/echo can't be called: bad schema")
      expect(calls).to be_empty
    end

    it "answers a call whose group a publish dropped meanwhile with an error, not a crash" do
      allow(index).to receive(:inner_args).and_wrap_original do |original, *args|
        fs.publish([])
        original.call(*args)
      end
      expect(index.call("mcp_fs_echo", {})).to eq("Error: the tool list changed and fs is gone; search with find_tools")
      expect(calls).to be_empty
    end

    describe "a plugin tool's paths, as call_tool always had them" do
      let(:call) { { name: call_name, args: { "tool" => "fs/echo", "args" => { "n" => 3 } } } }

      it "gives guardrails the tool it acts as, its arguments and the question's label" do
        targets = Samagotchi::Guardrails::Targets.for(call, Samagotchi::Guardrails::Context.new(cwd: Dir.pwd),
                                                      registry: registry)
        expect([targets.tool, targets.acts_as, targets.args, targets.label])
          .to eq([call_name, "mcp_fs_echo", { "n" => 3 }, "fs: echo"])
      end

      it "names the row by its label with the call's preview" do
        expect(Samagotchi::ToolActivity.plugin_label(call_name, registry: registry)).to eq("mcp")
        expect(Samagotchi::ToolActivity.tool_activity_params(call_name, call, registry: registry)).to eq("fs/echo n=3")
      end

      it "declares flat schemas to the native prompts" do
        schemas = Samagotchi::ToolDeclarations.native_schemas(registry).select { |s| [find_name, call_name].include?(s[:name]) }
        expect(schemas).to eq([call_entry, find_entry].map { |e| Samagotchi::ToolDeclarations.flat_schema(e.schema) })
      end
    end

    describe "every toolkit declares them" do
      let(:kits) do
        Samagotchi::Toolkit.kits(config: { "audit" => { "base" => "lean", "add" => ["delegate"] },
                                           "bare" => { "base" => "lean", "remove" => [call_name] } },
                                 plugins: [Samagotchi::Toolkit::Kit.new(name: "coordinator", base: "lean",
                                                                        add: %w[delegate delegate_result list_sessions],
                                                                        source: "coordinator")])
      end

      def declared(name) = registry.names(toolkit: Samagotchi::Toolkit.new(name: name).resolve(kits))

      it "in full, lean, child, coordinator and a config kit, unless its remove: names one" do
        %w[full lean child coordinator audit].each do |name|
          expect(declared(name)).to include(find_name, call_name), name
        end
        expect(declared("bare")).to include(find_name)
        expect(declared("bare")).not_to include(call_name)
        expect(registry.names(toolkit: Samagotchi::Toolkit.new(name: "lean", remove: [find_name]).resolve(kits)))
          .not_to include(find_name)
      end
    end
  end

  # What a hit loads on a host that loads tools (lean tools P2c): the wire
  # names of a keyword answer's callable, deferrable matches.
  describe "#find's loaded names" do
    before do
      added.publish([described_class::Group.new(name: "fs", tools: [
        echo, tool("fs", "echo_bad", description: "Echo badly.", refusal: "bad schema"),
        described_class::Tool.new(group: "fs", name: "echo_dot", acts_as: "mcp.fs.echo",
                                  description: "Echo dotted.")
      ])])
      index.declare(registry)
      registry.toolkit = Samagotchi::Toolkit.new(name: "lean").resolve(Samagotchi::Toolkit.kits)
      index.refresh!
    end

    it "are a keyword answer's matches: a built-in by name, a source tool by acts_as, never a refused or odd name" do
      expect(index.find("echo").loaded).to eq(%w[mcp_fs_echo])
      expect(index.find("sessions").loaded).to eq(%w[list_sessions send_note delegate delegate_result])
      expect(index.find("sessions", server: "fs")).to start_with("(searched every group)")
      expect(index.find("sessions", server: "fs").loaded).to eq(%w[list_sessions send_note delegate delegate_result])
    end

    it "are none for the names listing, a miss or an unknown group" do
      expect(index.find("").loaded).to eq([])
      expect(index.find("zebra").loaded).to eq([])
      expect(index.find("echo", "nope").loaded).to eq([])
    end
  end

  describe "the chi group: built-ins the toolkit leaves out" do
    def kit(name = "lean", kits: Samagotchi::Toolkit.kits, **) = Samagotchi::Toolkit.new(name: name, **).resolve(kits)

    def lean! = (registry.toolkit = kit).tap { index.refresh! }

    let(:find_entry) { registry[find_name] }

    before { index.declare(registry) }

    it "lists them per toolkit, never a removed or layer-gated one, first in the description" do
      lean!
      chi = index.groups.first
      expect(chi.name).to eq("chi")
      expect(chi.tools.map(&:name)).to eq(%w[register_reminder cancel_reminder list_reminders list_sessions send_note
                                             delegate delegate_result])
      expect(find_entry.schema[:description]).to end_with(
        "\nGroups:\n- chi: chi's own tools not declared in this session (7 tools)"
      )

      registry.toolkit = kit("child")
      expect(index.groups.first.tools.map(&:name)).to eq(%w[register_reminder cancel_reminder list_reminders
                                                            list_sessions])
      registry.toolkit = kit(remove: %w[delegate])
      expect(index.groups.first.tools.map(&:name)).not_to include("delegate", "forget_outputs")
      registry.toolkit = nil
      expect(index.groups).to eq([])
    end

    it "answers a search with the tool's name, its registered schema, and how to call it" do
      registry = Samagotchi::Tools::Builtins.registry(command_description: false)
      index = described_class.new
      index.declare(registry)
      registry.toolkit = kit("tiny", kits: Samagotchi::Toolkit.kits(config: { "tiny" => { "base" => "lean",
                                                                                          "remove" => [] } })
                                                .merge("tiny" => Samagotchi::Toolkit::Kit.new(name: "tiny",
                                                                                              tools: %w[read])))
      answer = index.find("run shell command")
      expect(answer).to start_with("Call one with call_tool(tool: \"<group>/<tool>\", args: {…}).\n\nchi/execute: ")
      schema = Samagotchi::ToolDeclarations.chat_schemas([registry["execute"].schema]).first[:parameters]
      expect(answer).to include("inputSchema: #{JSON.generate(schema)}")
      expect(schema[:properties]).to have_key(:command)
      expect(schema[:properties]).not_to have_key(:description) # execute.description: false
    end

    it "notes that a search given the old server: parameter searched every group" do
      lean!
      expect(find_entry.handler.call({ name: find_name, args: { "query" => "delegate", "server" => "x" } }, nil))
        .to start_with("(searched every group)\nCall one with call_tool")
      expect(index.find("delegate", "chi")).to include("chi/delegate: ")
    end

    it "never runs a chi tool as a source call (fail closed: only the unwrap runs it)" do
      lean!
      expect(index.call("chi/delegate", { "task" => "x" })).to eq("Error: chi/delegate can't be called through call_tool here")
      expect(index.call("delegate", "nope")).to start_with("Error: args must be an object.")
      expect(index.call_targets({ "tool" => "chi/delegate", "args" => { "task" => "x" } }))
        .to eq(acts_as: "delegate", args: { "task" => "x" }, label: "chi: delegate")
    end

    it "describes the source groups as they were at load: a publish before the first apply changes no bytes (B4)" do
      fs = added
      fs.publish([described_class::Group.new(name: "fs", tools: [echo])])
      index = described_class.new
      index.add(fs)
      registry = Samagotchi::Tools::Builtins.registry
      index.declare(registry)
      fs.publish([described_class::Group.new(name: "fs", summary: "now", tools: [echo, tool("fs", "more")])])
      registry.toolkit = kit
      index.refresh!
      first = registry[find_name].schema[:description]
      expect(first).to end_with("\n- chi: chi's own tools not declared in this session (7 tools)\n- fs (1 tool)")

      again = described_class.new.tap { |i| i.add(fs) }
      other = Samagotchi::Tools::Builtins.registry
      fs.publish([described_class::Group.new(name: "fs", tools: [echo])])
      again.declare(other)
      other.toolkit = kit
      again.refresh!
      expect(other[find_name].schema).to eq(registry[find_name].schema)
    end
  end

  it "leaves out a name another tool has, with a load failure, and declares the other" do
    added
    registry.register(find_name, schema: { name: find_name }, handler: ->(*) { "" }, source: "other")
    failures = Samagotchi::Guardrails::LoadFailures.new
    expect(index.declare(registry, failures: failures)).to eq([call_name])
    expect(registry[find_name].source).to eq("other")
    expect(failures.any?).to be(true)
  end

  it "leaves a source's group named chi, or one another group has, out of search and the description, said once" do
    allow(Samagotchi::Log).to receive(:warn)
    first = added
    second = added
    first.publish([described_class::Group.new(name: "fs", tools: [echo]),
                   described_class::Group.new(name: "chi", tools: [tool("chi", "echo")])])
    second.publish([described_class::Group.new(name: "fs", tools: [tool("fs", "other")])])
    index.declare(registry)

    expect(index.groups.map(&:name)).to eq(["fs"])
    expect(registry[find_name].schema[:description]).to end_with("\nGroups:\n- fs (1 tool)")
    expect(index.find("echo")).to include("fs/echo")
    expect(index.find("echo")).not_to include("chi/echo")
    expect(index.find("other")).to start_with("No tool matches")
    index.groups
    expect(Samagotchi::Log).to have_received(:warn).with(:plugins, "tool_group_dropped", hash_including(group: "chi")).once
    expect(Samagotchi::Log).to have_received(:warn).with(:plugins, "tool_group_dropped", hash_including(group: "fs")).once
  end

  # A source without a prefix: guardrails can't name a bare acts_as before
  # its tool is listed, so call_tool takes only <group>/<tool> from it, and
  # says so instead of blaming a change while the call waited.
  it "asks for <group>/<tool> on a bare acts_as of a source with no prefix" do
    added(prefix: nil).publish([described_class::Group.new(name: "fs", tools: [echo])])
    index.declare(registry)
    expect(index.call("mcp_fs_echo", {})).to eq("Error: call mcp_fs_echo as fs/echo")
    expect(index.call("fs/echo", {})).to eq("ran echo")
  end

  it "answers a declared built-in's bare name at once, without waiting for a starting server" do
    waited = []
    added(wait: ->(group) { waited << group }).publish([described_class::Group.new(name: "slow", state: :starting)])
    index.declare(registry)
    expect(index.call("read", {})).to eq("Error: read is declared; call it directly")
    expect(waited).to eq([])
    expect(index.call("nope", {})).to start_with("Error: no tool nope")
    expect(waited).to eq(["slow"])
  end

  it "takes only Group values in a publish" do
    expect { source.publish([{ name: "fs" }]) }.to raise_error(ArgumentError, /ToolIndex::Group/)
  end

  it "refuses a group in a state a lookup doesn't know, so a String \"starting\" can't go unwaited" do
    expect { described_class::Group.new(name: "fs", state: "starting") }.to raise_error(ArgumentError, /state must be one of/)
    expect { described_class::Group.new(name: "fs", state: :cached) }.to raise_error(ArgumentError, /state must be one of/)
  end

  it "refuses a tool of another group, whose call would find no source" do
    expect { described_class::Group.new(name: "fs", tools: [echo.with(group: "web")]) }
      .to raise_error(ArgumentError, "group fs: tool web/echo belongs to group web")
    expect { described_class::Group.new(name: "fs", tools: [{ name: "echo" }]) }.to raise_error(ArgumentError, /Tool values/)
  end

  it "refuses a tool with a blank acts_as, which no mcp_* rule would match" do
    expect { described_class::Tool.new(group: "fs", name: "echo", acts_as: " ") }
      .to raise_error(ArgumentError, "tool fs/echo: acts_as is blank")
  end

  describe "chi.tool_source" do
    let(:registries) { Samagotchi::Plugin::Registries.new(commands: nil, tools: registry, hooks: nil, tool_index: index) }

    def api = Samagotchi::Plugin::Api.new(bundle: "mcp", label: "plugin.rb (bundle mcp)", registries: registries)

    it "adds the source when the plugin's register returns, once per plugin" do
      chi = api
      chi.tool_source(call: ->(*) { "" }, acts_as: ->(*) { "" })
      expect(index.instance_variable_get(:@sources)).to be_empty
      expect { chi.tool_source(call: ->(*) { "" }, acts_as: ->(*) { "" }) }.to raise_error(ArgumentError, /twice/)
      chi.commit!
      expect(index.instance_variable_get(:@sources).size).to eq(1)
      expect(chi.counts[:tool_sources]).to eq(1)
    end

    it "keeps an older mcp bundle's own tools: it publishes nothing, so full declares none of the index's" do
      chi = api # mcp 0.6.x: its own tools, by their old names, and no chi.tool_source
      chi.tool("find_mcp_tools", "its own search", params: { query: { type: "string" } }) { "found" }
      chi.tool("mcp_call", "its own call", params: { tool: { type: "string" } }) { "called" }
      chi.commit!
      index.declare(registry)
      expect([registry["find_mcp_tools"].source, registry["mcp_call"].source]).to eq(%w[mcp mcp])
      expect(registry.names).to include("find_mcp_tools", "mcp_call")
      expect(registry.names).not_to include(find_name, call_name)
    end
  end
end
