# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/side_usage"
require "samagotchi/plugin/context"

# ctx.cost: the session's spend so far, read from the Engine's
# SessionMetrics (reported + estimated, side requests included).
RSpec.describe "ctx.cost" do
  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "box" => { host: "box.test", port: 8080 } }) }
  let(:engine) { Samagotchi::Engine.new(host_registry: registry, model_name: "box:m") }
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: engine.send(:plugin_host)) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
  end

  it "reads the Engine's metrics now, through the real plugin_host" do
    expect(ctx.cost).to have_attributes(total: 0.0, known?: true)

    engine.metrics.add_side(Samagotchi::SideUsage.new(kind: "btw", model: "m", prompt_tokens: 10, completion_tokens: 2,
                                                      cached_tokens: 0, cache_write_tokens: 0, reasoning_tokens: 0,
                                                      cost: 0.5, price: nil))
    expect(ctx.cost).to have_attributes(total: 0.5, reported: 0.5, side: 0.5, known?: true)
  end

  it "is zero and known for a Host without a cost member" do
    bare = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: Samagotchi::Plugin::Host.new)
    expect(bare.cost).to have_attributes(total: 0.0, reported: 0.0, estimated: 0.0, side: 0.0, known?: true)
  end
end
