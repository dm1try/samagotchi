# frozen_string_literal: true

require "json"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/kernel_loop"

# The Engine resolves its prompt profile with ModelProfile.resolve (config,
# the llama.cpp server's chat template, the name, qwen36): lazily, once per
# model, again after /model, and again before a turn when the last /props
# probe failed. The kernel and the system prompt follow the resolution.
RSpec.describe "Engine prompt profile resolution" do
  let(:gemma4_template) { File.read(File.expand_path("fixtures/llama_cpp/gemma4_template_excerpt.jinja", __dir__)) }
  let(:ornith_props) { JSON.parse(File.read(File.expand_path("fixtures/llama_cpp/props_ornith.json", __dir__))) }

  # A llama.cpp client whose /props answers are queued (the last one repeats).
  class FakeResolvingClient
    attr_reader :asked, :transport, :prompts

    def initialize(*answers)
      @answers = answers
      @asked = []
      @prompts = []
      @transport = Samagotchi::Client::Transport.new(:llama_cpp)
    end

    def server_props(model: nil)
      @asked << model
      @answers.size > 1 ? @answers.shift : @answers.first
    end

    def invalidate_context_window! = nil
    def context_window(model: nil) = nil

    def complete(prompt, **)
      @prompts << prompt
      { "content" => "ok", "stop" => true }
    end
  end

  def answered(body) = Samagotchi::Client::ServerProps.new(body: body, status: :ok)
  def loading = Samagotchi::Client::ServerProps.new(body: nil, status: :http_error)

  around do |example|
    saved = ENV.values_at("SAMAGOTCHI_DEFAULT_MODEL", "SAMAGOTCHI_MODEL_PROFILE")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "house-blend-35b"
    ENV.delete("SAMAGOTCHI_MODEL_PROFILE")
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"], ENV["SAMAGOTCHI_MODEL_PROFILE"] = saved
  end

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({})
  end

  def engine_with(client)
    registry = Samagotchi::HostRegistry.new(hosts_config: { "main" => { host: "h.test", port: 8081 } })
    registry.client_override = client
    Samagotchi::Engine.new(mode: :assist, host_registry: registry)
  end

  def session = Samagotchi::Session.new_session(mode: "assist", model_name: "house-blend-35b", working_directory: Dir.pwd)

  it "asks the server nothing until the profile is needed" do
    client = FakeResolvingClient.new(answered("chat_template" => gemma4_template))
    engine_with(client)

    expect(client.asked).to be_empty
  end

  it "takes the family from the server's chat template when the name says none" do
    client = FakeResolvingClient.new(answered("chat_template" => gemma4_template))
    engine = engine_with(client)

    expect([engine.profile.name, engine.profile_resolution.label]).to eq(["gemma4", "server (chat_template)"])
    expect(client.asked).to eq(["house-blend-35b"])
  end

  it "formats the turn and the system prompt with the resolved profile" do
    client = FakeResolvingClient.new(answered(ornith_props))
    engine = engine_with(client)
    events = []

    engine.run_turn(session, "hi", on_event: ->(e) { events << e })

    expect(client.prompts.first).to start_with("<|im_start|>system")
    started = events.find { |e| e[:type] == :generation_started }
    expect(started).to include(profile: "qwen36", profile_source: "server (chat_template)")
  end

  it "resolves again after a model switch" do
    client = FakeResolvingClient.new(answered(ornith_props), answered("chat_template" => gemma4_template))
    engine = engine_with(client)
    expect(engine.profile.name).to eq("qwen36")

    engine.switch_model!("other-blend")

    expect([engine.profile.name, client.asked]).to eq(["gemma4", %w[house-blend-35b other-blend]])
  end

  it "keeps a resolution for the session: no new probe per turn" do
    client = FakeResolvingClient.new(answered(ornith_props))
    engine = engine_with(client)
    s = session

    engine.run_turn(s, "one")
    engine.run_turn(s, "two")

    expect(client.asked.size).to eq(1)
  end

  it "retries a failed probe before the next turn and rebuilds the system prompt" do
    client = FakeResolvingClient.new(loading, answered("chat_template" => gemma4_template))
    engine = engine_with(client)
    s = session

    engine.run_turn(s, "one")
    expect(engine.profile_resolution).to have_attributes(source: :default, retry: true)
    engine.run_turn(s, "two")

    expect(engine.profile_resolution.label).to eq("server (chat_template)")
    expect(client.prompts.first).to start_with("<|im_start|>system")
    expect(client.prompts.last).not_to include("<|im_start|>")
  end

  it "lets --profile / SAMAGOTCHI_MODEL_PROFILE win over the server" do
    ENV["SAMAGOTCHI_MODEL_PROFILE"] = "qwen36"
    client = FakeResolvingClient.new(answered("chat_template" => gemma4_template))

    expect(engine_with(client).profile_resolution).to have_attributes(source: :env, retry: false)
    expect(client.asked).to be_empty
  end

  it "looks up models: under the alias as typed" do
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return("ista" => { profile: "gemma4" })
    allow(Samagotchi::ConfigFile).to receive(:resolve_model_alias).and_call_original
    allow(Samagotchi::ConfigFile).to receive(:resolve_model_alias).with("ista").and_return("house-blend-35b")
    engine = engine_with(FakeResolvingClient.new(answered(ornith_props)))

    engine.switch_model!("ista")

    expect(engine.profile_resolution.label).to eq("config (models: ista)")
  end
end
