# frozen_string_literal: true

require "samagotchi/engine"

# The loop follows the effective model's host: hosts with api: openai use the
# chat backend (against that host's /v1), everything else the raw-prompt
# NativeBackend. /model moves between them.
RSpec.describe "Engine picks the loop from the host's api" do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { host: "box.test", port: 8080 },
      "oai" => { host: "oai.test", port: 8000, api: :openai }
    })
  end

  around do |example|
    previous = ENV.delete("SAMAGOTCHI_BACKEND")
    example.run
  ensure
    ENV["SAMAGOTCHI_BACKEND"] = previous if previous
  end

  def engine(model) = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: model)

  it "uses NativeBackend for a host without api" do
    expect(engine("box:gemma4-small").backend).to be_a(Samagotchi::LLM::NativeBackend)
  end

  it "uses the chat backend against the host's /v1 for api: openai" do
    backend = engine("oai:some-model").backend
    expect(backend).to be_a(Samagotchi::LLM::RubyLLMBackend)
    expect(backend.base_url).to eq("http://oai.test:8000/v1")
  end

  it "follows switch_model! both ways, keeping one chat backend" do
    e = engine("box:gemma4-small")
    e.switch_model!("oai:some-model")
    chat = e.backend
    expect(chat).to be_a(Samagotchi::LLM::RubyLLMBackend)

    e.switch_model!("box:gemma4-small")
    expect(e.backend).to be_a(Samagotchi::LLM::NativeBackend)

    e.switch_model!("oai:other")
    expect(e.backend).to be(chat)
  end

  it "runs a turn through the chosen backend with the bare model name" do
    e = engine("oai:some-model")
    chat = e.backend
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(chat).to receive(:complete).and_return(Samagotchi::LLM::ModelResult.new(text: "hi", conversation: []))
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "oai:some-model", working_directory: Dir.pwd)

    e.run_turn(session, "hello")

    expect(chat).to have_received(:complete).with(hash_including(model_name: "some-model"))
  end
end
