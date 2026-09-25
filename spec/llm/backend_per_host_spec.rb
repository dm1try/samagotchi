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
    Samagotchi::Engine.instance_variable_set(:@warned_removed_backend, nil)
    example.run
  ensure
    previous ? ENV["SAMAGOTCHI_BACKEND"] = previous : ENV.delete("SAMAGOTCHI_BACKEND")
    Samagotchi::Engine.instance_variable_set(:@warned_removed_backend, nil)
  end

  def engine(model) = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: model)

  it "uses NativeBackend for a host without api" do
    expect(engine("box:gemma4-small").backend).to be_a(Samagotchi::LLM::NativeBackend)
  end

  it "uses the chat backend against the host's /v1 for api: openai" do
    backend = engine("oai:some-model").backend
    expect(backend).to be_a(Samagotchi::LLM::ChatLoop)
    expect(backend.adapter.base_url).to eq("http://oai.test:8000/v1")
  end

  it "follows switch_model! both ways, keeping one chat backend" do
    e = engine("box:gemma4-small")
    e.switch_model!("oai:some-model")
    chat = e.backend
    expect(chat).to be_a(Samagotchi::LLM::ChatLoop)

    e.switch_model!("box:gemma4-small")
    expect(e.backend).to be_a(Samagotchi::LLM::NativeBackend)

    e.switch_model!("oai:other")
    expect(e.backend).to be(chat)
  end

  # 7b: the chat backend's endpoint was fixed from the default model at
  # construction, so /model, --model host:x and resumed sessions kept talking
  # to the default model's host.
  it "moves the chat backend to the new openai host on switch_model!" do
    registry = Samagotchi::HostRegistry.new(hosts_config: {
      "alpha" => { host: "alpha.test", port: 1111, api: :openai },
      "beta" => { host: "beta.test", port: 2222, api: :openai }
    })
    e = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "alpha:gemma4-small")
    expect(e.backend.adapter.base_url).to eq("http://alpha.test:1111/v1")

    e.switch_model!("beta:Qwen3-14B")

    expect(e.backend.adapter.base_url).to eq("http://beta.test:2222/v1")
  end

  it "warns once that SAMAGOTCHI_BACKEND is ignored, and still follows the host" do
    ENV["SAMAGOTCHI_BACKEND"] = "ruby_llm"
    expect { engine("box:gemma4-small") }.to output(/backend setting .* was removed and is ignored/).to_stderr
    expect { expect(engine("box:gemma4-small").backend).to be_a(Samagotchi::LLM::NativeBackend) }.not_to output.to_stderr
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
