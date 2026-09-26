# frozen_string_literal: true

require "spec_helper"
require "samagotchi/tool_activity"
require "samagotchi/tools/builtins"
require "samagotchi/kernel_loop"
require "samagotchi/tool_runner"

RSpec.describe Samagotchi::ToolActivity do
  let(:schema) { { name: "jira_search", description: "d", parameters: { type: "object", properties: {}, required: [] } } }

  def registry(**entry)
    Samagotchi::Tools::Builtins.registry.tap do |registry|
      registry.register("jira_search", schema: schema, handler: ->(_call, _kctx) { "3 issues" }, source: "spec", **entry)
    end
  end

  it "keeps the built-ins' own words, with or without a registry" do
    call = { name: "read", content: "lib/a.rb" }
    [nil, registry].each do |tools|
      expect(described_class.tool_activity_event("read", call, "ok", registry: tools))
        .to eq(action: "reading file", tool: "read", params: 'path="lib/a.rb"', status: "ok")
      expect(described_class.tool_activity_event("register_reminder", { name: "register_reminder", content: "x" }, "ok",
                                                  registry: tools))
        .to include(action: "calling tool", params: nil)
    end
  end

  it "says calling tool with no params for a tool the registry doesn't know" do
    expect(described_class.tool_activity_event("nope", { name: "nope", content: "x" }, "Error: …", registry: registry))
      .to eq(action: "calling tool", tool: "nope", params: nil, status: "error")
  end

  it "uses a registry tool's label and preview" do
    tools = registry(label: "searching Jira", preview: ->(call) { "q=#{call[:query]}" })
    expect(described_class.tool_activity_event("jira_search", { name: "jira_search", query: "bug" }, "3", registry: tools))
      .to include(action: "searching Jira", params: "q=bug")
  end

  it "falls back to calling tool and the given arguments as key=value" do
    call = { name: "jira_search", query: "open bugs", limit: 5, project: "" }
    expect(described_class.tool_activity_event("jira_search", call, "3", registry: registry))
      .to include(action: "calling tool", params: 'query="open bugs" limit="5"')
  end

  it "reaches the tool_call_started params (the spinner) and the completed activity through ToolRunner" do
    kernel = Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client), profile: :gemma4)
    kernel.tools = registry
    events = []
    Samagotchi::ToolRunner.new(kernel).run({ name: "jira_search", query: "bug" }, iteration: 1, call_index: 1, call_count: 1,
                                           on_stream_event: ->(event) { events << event }, max_tool_output_chars: nil)
    expect(events.find { |e| e[:type] == :tool_call_started }[:params]).to eq('query="bug"')
    expect(events.find { |e| e[:type] == :tool_call_completed }[:activity]).to include(params: 'query="bug"', status: "ok")
  end
end
