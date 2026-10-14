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
    it "declares nothing: the session's tools are the ones it had" do
      before = registry.names
      expect(index.declare(registry)).to eq([])
      expect(registry.names).to eq(before)
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
      expect(find_entry.schema[:description]).to end_with("\nServers:\n- fs: files (1 tool)\n- slow")
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
      index.sources.first.instance_variable_set(:@call, ->(*) { result })
      expect(call_entry.handler.call({ name: call_name, args: { "tool" => "fs/echo" } }, nil)).to be(result)
    end

    it "refuses a published refusal before the source sees the call" do
      fs.publish([described_class::Group.new(name: "fs", tools: [echo.with(refusal: "bad schema", mark: "(bad schema)")])])
      expect(index.call("fs/echo", {})).to eq("Error: fs/echo can't be called: bad schema")
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
        Samagotchi::Toolkit.kits(config: { "review" => { "base" => "lean", "add" => ["delegate"] },
                                           "bare" => { "base" => "lean", "remove" => [call_name] } },
                                 plugins: [Samagotchi::Toolkit::Kit.new(name: "coordinator", base: "lean",
                                                                        add: %w[delegate delegate_result list_sessions],
                                                                        source: "coordinator")])
      end

      def declared(name) = registry.names(toolkit: Samagotchi::Toolkit.new(name: name).resolve(kits))

      it "in full, lean, child, coordinator and a config kit, unless its remove: names one" do
        %w[full lean child coordinator review].each do |name|
          expect(declared(name)).to include(find_name, call_name), name
        end
        expect(declared("bare")).to include(find_name)
        expect(declared("bare")).not_to include(call_name)
        expect(registry.names(toolkit: Samagotchi::Toolkit.new(name: "lean", remove: [find_name]).resolve(kits)))
          .not_to include(find_name)
      end
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
      expect(index.sources).to be_empty
      expect { chi.tool_source(call: ->(*) { "" }, acts_as: ->(*) { "" }) }.to raise_error(ArgumentError, /twice/)
      chi.commit!
      expect(index.sources.size).to eq(1)
      expect(chi.counts[:tool_sources]).to eq(1)
    end

    it "keeps an older mcp bundle's own tools: it publishes nothing, so the index declares none" do
      chi = api # mcp 0.6.x: its own tools, by their old names, and no chi.tool_source
      chi.tool("find_mcp_tools", "its own search", params: { query: { type: "string" } }) { "found" }
      chi.tool("mcp_call", "its own call", params: { tool: { type: "string" } }) { "called" }
      chi.commit!
      expect(index.declare(registry)).to eq([])
      expect([registry["find_mcp_tools"].source, registry["mcp_call"].source]).to eq(%w[mcp mcp])
      expect(registry.key?(find_name)).to be(false)
      expect(registry.key?(call_name)).to be(false)
      expect(registry.by_source("index")).to be_empty
    end
  end
end
