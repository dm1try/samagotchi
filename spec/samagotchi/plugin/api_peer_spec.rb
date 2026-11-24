# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/api"
require "samagotchi/plugin/loader"
require "samagotchi/peer_registry"
require "samagotchi/commands/registry"
require "samagotchi/hooks/registry"
require "samagotchi/tools/registry"

# chi.peer: a plugin declares a peer agent whose mailbox messages become
# its notes (PeerRegistry), staged like any registration.
RSpec.describe "chi.peer" do
  let(:registry) { Samagotchi::PeerRegistry.new }
  let(:registries) do
    Samagotchi::Plugin::Registries.new(commands: Samagotchi::Commands::Registry.new, tools: Samagotchi::Tools::Registry.new,
                                       hooks: Samagotchi::Hooks::Registry.new, peer_registry: registry, init: ->(*, **) {})
  end

  def api(bundle = "mine") = Samagotchi::Plugin::Api.new(bundle: bundle, label: "plugin.rb (bundle #{bundle})", registries: registries)

  it "declares the peer when the plugin's register returns, and nothing for one that doesn't" do
    chi = api
    chi.peer("codex")
    expect(registry.declared?("codex")).to be(false)

    chi.commit!
    expect(registry.declared?("codex")).to be(true)
    expect(chi.counts[:peers]).to eq(1)

    api("aborted").peer("other")
    expect(registry.names).to eq(["codex"])
  end

  it "refuses a bad name, one declared twice or by another bundle, and a chi without plugins" do
    expect { api.peer("Codex") }.to raise_error(ArgumentError, /isn't a peer name/)
    expect { api.peer("codex-outbox") }.to raise_error(ArgumentError, /isn't a peer name/)
    twice = api
    twice.peer("x")
    expect { twice.peer("x") }.to raise_error(ArgumentError, "peer x is declared twice")
    other = api("other")
    other.peer("y")
    other.commit!
    expect { api.peer("y") }.to raise_error(ArgumentError, "peer y is already declared (other)")

    bare = Samagotchi::Plugin::Registries.new(commands: nil, tools: nil, hooks: nil)
    expect { Samagotchi::Plugin::Api.new(bundle: "b", label: "l", registries: bare).peer("z") }
      .to raise_error(ArgumentError, "this chi has no peer registry (plugins: false)")
  end

  it "is in SINCE, with ctx.peers, as 0.188.0" do
    expect(Samagotchi::Plugin::Api::SINCE).to include("chi.peer" => "0.188.0", "ctx.peers" => "0.188.0")
  end
end
