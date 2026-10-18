# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/context"
require "samagotchi/session_setup"

# ctx.settings: config.yml's bundles: <name>: with the session's own --set
# values for the bundle laid over it (SessionSetup#bundle_settings, through
# the Host's setup), frozen, rebuilt when the session id changes.
RSpec.describe Samagotchi::Plugin::Context, "#settings" do
  let(:session_id) { [nil] }
  let(:setup_calls) { [0] }
  let(:session_values) { [{ "cost-cap" => { "cap" => 0.5 }, "other" => { "cap" => 9 } }] }
  let(:host) do
    Samagotchi::Plugin::Host.new(session_id: -> { session_id.first },
                                 setup: lambda {
                                   setup_calls[0] += 1
                                   Samagotchi::SessionSetup.new(bundle_settings: session_values.first)
                                 })
  end
  let(:config) { { "default" => 5, "warn_at" => 0.8, "nested" => { "a" => [1] } } }

  def ctx(settings = config, bundle: "cost-cap") = described_class.new(bundle: bundle, label: "plugin.rb", settings: settings, host: host)

  it "is the config alone before the session is bound, and doesn't read the setup then" do
    context = ctx
    expect(context.settings).to eq(config)
    expect(context.settings).to be_frozen
    expect(context.settings["nested"]["a"]).to be_frozen
    expect(setup_calls.first).to eq(0)
  end

  it "lays the session's values for this bundle over the config once the session is bound, frozen" do
    context = ctx
    context.settings
    session_id[0] = "s1"
    expect(context.settings).to eq("default" => 5, "warn_at" => 0.8, "nested" => { "a" => [1] }, "cap" => 0.5)
    expect(context.settings).to be_frozen
    expect(context.settings["nested"]).to be_frozen
  end

  it "reads the setup once per session id, and again after the session changes" do
    context = ctx
    session_id[0] = "s1"
    3.times { context.settings }
    expect(setup_calls.first).to eq(1)

    session_values[0] = { "cost-cap" => { "cap" => 2, "default" => 1 } }
    expect(context.settings["cap"]).to eq(0.5)
    session_id[0] = "s2"
    expect(context.settings).to include("cap" => 2, "default" => 1)
    expect(setup_calls.first).to eq(2)
  end

  it "keeps a session value over a config one of the same key, and leaves the config Hash as given" do
    given = { "cap" => 3 }
    session_id[0] = "s1"
    expect(ctx(given).settings).to eq("cap" => 0.5)
    expect(given).to eq("cap" => 3)
  end

  it "is the config for a session without values for the bundle, or with a Host that has no setup" do
    session_id[0] = "s1"
    expect(ctx(bundle: "loop-guard").settings).to eq(config)
    bare = described_class.new(bundle: "cost-cap", label: "plugin.rb", settings: config,
                               host: Samagotchi::Plugin::Host.new(session_id: -> { "s1" }))
    expect(bare.settings).to eq(config)
  end
end
