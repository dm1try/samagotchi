# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/api"
require "samagotchi/plugin/loader"
require "samagotchi/commands/registry"
require "samagotchi/hooks/registry"

# chi.peer_source is gone (a peer's answers come through its mailbox:
# chi.peer). It stays as a method that raises how to upgrade, so an
# installed older peer bundle fails to load with that sentence and chi
# starts without it (loader_spec: "an older peer bundle").
RSpec.describe "chi.peer_source" do
  let(:registries) do
    Samagotchi::Plugin::Registries.new(commands: Samagotchi::Commands::Registry.new, tools: Samagotchi::Tools::Registry.new,
                                       hooks: Samagotchi::Hooks::Registry.new, init: ->(*, **) {})
  end

  it "raises how to upgrade the bundle, whatever it is given" do
    api = Samagotchi::Plugin::Api.new(bundle: "codex-peer", label: "plugin.rb (bundle codex-peer)", registries: registries)
    expect { api.peer_source("codex-outbox", label: "Codex") }
      .to raise_error(ArgumentError, "chi.peer_source is gone: upgrade this bundle (chi bundle install codex-peer --force)")
    expect(api.counts).not_to have_key(:peer_sources)
  end
end
