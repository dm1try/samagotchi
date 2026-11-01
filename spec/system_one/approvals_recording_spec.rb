# frozen_string_literal: true

require "tmpdir"
require "samagotchi/engine"
require "support/test_kernel"

# Approvals' client as the Engine builds it: its own mode key, recorded.
RSpec.describe Samagotchi::Engine do
  let(:state_dir) { Dir.mktmpdir("approvals-recording") }
  let(:store) { Samagotchi::SystemOne::Runs::MemoryStore.new }
  let(:engine) do
    client = test_client
    described_class.new(client: client, kernel: test_kernel(client: client), model_name: "Gemma-4B-it")
  end

  after { FileUtils.rm_rf(state_dir) }

  def approvals_client
    engine.send(:build_guardrail_wiring).instance_variable_get(:@system_one).call
  end

  def with_settings(mode)
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("guardrails.system_one.mode").and_return(mode)
    allow(Samagotchi::Config).to receive(:get).with("system_one.host").and_return("judge")
  end

  it "keeps guardrails.system_one.mode: audit stays audit, never on" do
    with_settings("audit")
    expect(approvals_client).to have_attributes(mode: "audit", host: "judge")
  end

  it "is no client while that mode is off, whatever toolkit or context are set to" do
    with_settings("off")
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.mode").and_return("on")
    expect(approvals_client).to be_nil
  end

  it "saves its asks as approvals.allow" do
    with_settings("audit")
    allow(engine).to receive(:system_one_runs).and_return(Samagotchi::SystemOne::Runs.new(store: store))
    allow_any_instance_of(Samagotchi::SystemOne::HttpBackend).to receive(:ask)
      .and_return({ "allow" => Samagotchi::SystemOne::Answer.new(id: "allow", type: :noul, noul: 0.9) })
    approvals_client.ask(state: "git push", questions: { "allow" => { "type" => "noul", "instructions" => "Allow?" } })
    expect(store.lines["approvals.allow"].first).to include("judgment" => "approvals.allow", "mode" => "audit", "state" => "git push")
  end
end
