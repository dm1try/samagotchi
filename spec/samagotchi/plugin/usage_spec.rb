# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/plugin/context"

# ctx.usage: the session's work so far, read from the Engine's
# SessionMetrics (turns, tool calls, steps, active time).
RSpec.describe "ctx.usage" do
  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "box" => { host: "box.test", port: 8080 } }) }
  let(:engine) { Samagotchi::Engine.new(host_registry: registry, model_name: "box:m") }
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: engine.send(:plugin_host)) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
  end

  it "reads the Engine's metrics now, through the real plugin_host" do
    expect(ctx.usage).to have_attributes(turns: 0, tool_calls: 0, steps: 0, active_ms: 0)

    metrics = engine.metrics
    metrics.call(type: :turn_started, session_id: "s", prompt: "p", turn_id: "t1")
    metrics.call(type: :tool_dispatch_started, iteration: 1)
    metrics.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "read")
    expect(ctx.usage).to have_attributes(turns: 1, tool_calls: 1, steps: 1, tool_calls_by_tool: { "read" => 1 })
  end

  it "is zero for a Host without a usage member" do
    bare = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: Samagotchi::Plugin::Host.new)
    expect(bare.usage).to eq(Samagotchi::SessionMetrics::Usage.zero)
  end
end
