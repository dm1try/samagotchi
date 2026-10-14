# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/api"
require "samagotchi/plugin/loader"
require "samagotchi/peer_sources"
require "samagotchi/commands/registry"
require "samagotchi/hooks/registry"

# chi.peer_source: a plugin declares a context source as a peer agent's
# answers (PeerSources), staged like any registration.
RSpec.describe "chi.peer_source" do
  let(:peer_sources) { Samagotchi::PeerSources.new }
  let(:registries) do
    Samagotchi::Plugin::Registries.new(commands: Samagotchi::Commands::Registry.new, tools: Samagotchi::Tools::Registry.new,
                                       hooks: Samagotchi::Hooks::Registry.new, peer_sources: peer_sources)
  end

  def api(bundle = "mine") = Samagotchi::Plugin::Api.new(bundle: bundle, label: "plugin.rb (bundle #{bundle})", registries: registries)

  it "declares the source when the plugin's register returns, and nothing for one that doesn't" do
    chi = api
    chi.peer_source("codex-outbox", label: "Codex")
    expect(peer_sources.label_for("codex-outbox")).to be_nil

    chi.commit!
    expect(peer_sources.label_for("codex-outbox")).to eq("Codex")
    expect(chi.counts[:peer_sources]).to eq(1)

    api("aborted").peer_source("other-outbox", label: "Other")
    expect(peer_sources.names).to eq(["codex-outbox"])
  end

  it "refuses a bad name or label, one declared twice or by another bundle, and a chi without plugins" do
    expect { api.peer_source("Bad Name", label: "Codex") }.to raise_error(ArgumentError, /peer source/)
    expect { api.peer_source("x-outbox", label: "rm -rf /; echo") }.to raise_error(ArgumentError, /label must match/)
    twice = api
    twice.peer_source("x-outbox", label: "X")
    expect { twice.peer_source("x-outbox", label: "X") }.to raise_error(ArgumentError, "peer source x-outbox is declared twice")
    other = api("other")
    other.peer_source("y-outbox", label: "Y")
    other.commit!
    expect { api.peer_source("y-outbox", label: "Y") }
      .to raise_error(ArgumentError, "peer source y-outbox is already declared (other)")

    bare = Samagotchi::Plugin::Registries.new(commands: nil, tools: nil, hooks: nil)
    expect { Samagotchi::Plugin::Api.new(bundle: "b", label: "l", registries: bare).peer_source("z", label: "Z") }
      .to raise_error(ArgumentError, "this chi has no peer sources (plugins: false)")
  end

  %w[claude Claude codex Codex].each_slice(2) do |peer, name|
    it "is declared by the shipped #{peer}-peer bundle for its review source" do
      path = File.expand_path("../../../lib/samagotchi/bundles/#{peer}-peer/plugin.rb", __dir__)
      plugin = Module.new.tap { |n| n.module_eval(File.read(path), path, 1) }.const_get(:Plugin).new({})
      chi = api("#{peer}-peer")
      plugin.register(chi)
      chi.commit!

      expect(peer_sources.label_for("#{peer}-outbox")).to eq(name)
    end
  end
end
