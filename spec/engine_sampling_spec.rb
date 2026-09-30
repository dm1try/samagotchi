# frozen_string_literal: true

require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"

RSpec.describe Samagotchi::Engine, "#run_turn sampling" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Ornith"
    Dir.mktmpdir("chi-state") do |dir|
      @state_dir = dir
      example.run
    end
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) do
    described_class.new(client: client, kernel: kernel, profile: "qwen36").tap do |e|
      e.session_state_dir = @state_dir
    end
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Ornith", working_directory: Dir.pwd) }
  let(:sampling_set) { [] }
  let(:thinking_set) { [] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:vision=)
    allow(kernel).to receive(:sampling=) { |value| sampling_set << value }
    allow(kernel).to receive(:thinking=) { |value| thinking_set << value }
    allow(kernel).to receive(:run) do |messages, **|
      Samagotchi::KernelLoop::Result.new(output: "ok", conversation: messages + [{ role: "model", content: "ok" }],
                                         exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
    end
  end

  it "resolves the effective model's sampling each turn and sets it on the kernel" do
    models = { "ornith" => { profile: nil, sampling: { temperature: 0.6 } } }
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return(models)

    engine.run_turn(session, "hi")
    models["ornith"][:sampling] = { temperature: 0.2 }
    engine.run_turn(session, "again")

    expect(sampling_set).to eq([{ temperature: 0.6 }, { temperature: 0.2 }])
  end

  it "sets an empty map when nothing is configured" do
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({})

    engine.run_turn(session, "hi")

    expect(sampling_set).to eq([{}])
  end

  it "resolves the effective model's thinking level each turn and sets it on the kernel" do
    models = { "ornith" => { profile: nil, thinking: :off } }
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return(models)

    engine.run_turn(session, "hi")
    models["ornith"][:thinking] = :high
    engine.run_turn(session, "again")
    models["ornith"].delete(:thinking)
    engine.run_turn(session, "and again")

    expect(thinking_set).to eq(%i[off high default])
  end
end
