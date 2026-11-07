# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/terminal_ui"
require "samagotchi/plugin/context"

# ctx.frontend: what runs the session, read now (the host sets it after
# the plugins load): :one_shot (-p --non-interactive, a bare Engine) or
# :worker (a session
# worker: the web, an attached TUI). A host without it reads :worker.
RSpec.describe "ctx.frontend" do
  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "box" => { host: "box.test", port: 8080 } }) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
  end

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "box:gemma-small") { example.run } }

  def ctx_of(engine)
    Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: engine.send(:plugin_host))
  end

  it "follows the Engine's interface set after the context was built" do
    engine = Samagotchi::Engine.new(host_registry: registry, model_name: "box:gemma-small")
    ctx = ctx_of(engine)
    expect(ctx.frontend).to eq(:one_shot)

    engine.interface = :worker
    expect(ctx.frontend).to eq(:worker)
  end

  it "is :one_shot for -p --non-interactive" do
    ui = Samagotchi::TerminalUI.new(host_registry: registry, prompt: "hi")
    expect(ctx_of(ui.engine).frontend).to eq(:one_shot)
  end

  it "is :worker on a host without it" do
    bare = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: Samagotchi::Plugin::Host.new)
    expect(bare.frontend).to eq(:worker)
  end
end
