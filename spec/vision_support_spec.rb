# frozen_string_literal: true

require "json"
require "samagotchi/vision_support"
require "samagotchi/host_registry"
require "samagotchi/model_profile"

RSpec.describe Samagotchi::VisionSupport do
  let(:ornith) { JSON.parse(File.read(File.expand_path("fixtures/llama_cpp/props_ornith.json", __dir__))) }
  let(:qwen) { Samagotchi::ModelProfile.qwen36 }
  let(:gemma) { Samagotchi::ModelProfile.gemma4 }

  def props(body, status: :ok) = Samagotchi::Client::ServerProps.new(body: body, status: status)

  def native_target(props_answer, transport: :llama_cpp, vision: nil, model: "Ornith")
    client = instance_double(Samagotchi::Client, transport: Samagotchi::Client::Transport.new(transport))
    allow(client).to receive(:server_props).and_return(props_answer)
    entry = Samagotchi::HostRegistry::HostEntry.new(name: "main", host: "h", port: 1, client: client, vision: vision)
    Samagotchi::HostRegistry::ModelTarget.new(model: model, entry: entry, bare_model: model, client: client)
  end

  def chat_target(props_answer: nil, remote: true, vision: nil, model: "vendor/m")
    client = instance_double(Samagotchi::Client)
    allow(client).to receive(:server_props).and_return(props_answer)
    entry = Samagotchi::HostRegistry::HostEntry.new(name: "or", host: "h", port: 1, client: client, api: :openai,
                                                    api_key_env: remote ? "OR_KEY" : nil, vision: vision)
    Samagotchi::HostRegistry::ModelTarget.new(model: "or:#{model}", entry: entry, bare_model: model, client: client)
  end

  def answer(target, profile: qwen, adapter: nil, models: {})
    described_class.for(target, profile: profile, adapter: adapter, models: models)
  end

  describe "a native host" do
    it "says yes for llama.cpp with vision, a media marker and Qwen's template" do
      expect(answer(native_target(props(ornith)))).to have_attributes(value: true, reason: nil)
    end

    it "says no without vision in /props" do
      result = answer(native_target(props(ornith.merge("modalities" => { "vision" => false }))))
      expect(result).to have_attributes(value: false, reason: /no vision model loaded.*--mmproj/)
      expect(answer(native_target(props(ornith.except("modalities")))).value).to be(false)
    end

    it "says no when /props can't be reached (no media marker to send an image with)" do
      result = answer(native_target(props(nil, status: :network_error)))
      expect(result).to have_attributes(value: false, reason: "can't reach /props for the media marker")
    end

    it "says no without a media marker" do
      expect(answer(native_target(props(ornith.except("media_marker")))).reason).to match(/no media marker/)
    end

    it "says no for a ChatML template that isn't Qwen's vision template" do
      chatml = ornith.merge("chat_template" => "{% for m in messages %}<|im_start|>{{ m.role }}\n{{ m.content }}<|im_end|>{% endfor %}")
      expect(answer(native_target(props(chatml)))).to have_attributes(value: false, reason: /doesn't use <\|vision_start\|>/)
    end

    it "says no for gemma4 (no image template yet)" do
      expect(answer(native_target(props(ornith)), profile: gemma).reason).to eq("profile gemma4 has no image template yet")
    end

    it "says no for mlx and omlx hosts" do
      expect(answer(native_target(props(ornith), transport: :mlx)).reason).to match(/mlx hosts take no images/)
      expect(answer(native_target(nil, transport: :omlx)).value).to be(false)
    end

    it "lets config say no, and yes skips only the modalities check" do
      expect(answer(native_target(props(ornith), vision: false))).to have_attributes(value: false, reason: "hosts.main sets vision: false")
      no_modalities = props(ornith.except("modalities"))
      expect(answer(native_target(no_modalities, vision: true)).value).to be(true)
      expect(answer(native_target(props(nil, status: :network_error), vision: true)).value).to be(false)
    end

    it "prefers models: over hosts:" do
      models = { "ornith" => { profile: nil, vision: false } }
      expect(answer(native_target(props(ornith), vision: true), models: models).reason).to eq("models: ornith sets vision: false")
    end
  end

  describe "a chat host" do
    let(:adapter) { instance_double(Samagotchi::LLM::OpenAIChat) }

    it "uses the host's model list" do
      allow(adapter).to receive(:image_input).with(model: "vendor/m").and_return(true, false, nil)
      expect(answer(chat_target, adapter: adapter).value).to be(true)
      expect(answer(chat_target, adapter: adapter)).to have_attributes(value: false, reason: "host or lists vendor/m as text-only")
      expect(answer(chat_target, adapter: adapter).value).to be_nil
    end

    it "asks a local llama.cpp's /props first" do
      allow(adapter).to receive(:image_input).and_return(true)
      local = chat_target(props_answer: props(ornith.merge("modalities" => { "vision" => false })), remote: false)
      expect(answer(local, adapter: adapter).value).to be(false)
      expect(answer(chat_target(props_answer: props(ornith), remote: false), adapter: adapter).value).to be(true)
    end

    it "lets config win both ways" do
      allow(adapter).to receive(:image_input).and_return(false)
      expect(answer(chat_target(vision: true), adapter: adapter).value).to be(true)
      expect(answer(chat_target(vision: false), adapter: adapter).reason).to eq("hosts.or sets vision: false")
    end

    it "answers unknown when the adapter fails" do
      allow(adapter).to receive(:image_input).and_raise("boom")
      expect(answer(chat_target, adapter: adapter).value).to be_nil
    end
  end

  describe "config" do
    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "samagotchi"))
        File.write(File.join(dir, "samagotchi", "config.yml"), <<~YAML)
          hosts:
            main: { host: 127.0.0.1, port: 8081, vision: false }
            box: { host: 127.0.0.1, port: 8082, vision: maybe }
          models:
            Ornith: { vision: true }
        YAML
        @env = { "XDG_CONFIG_HOME" => dir }
        example.run
      end
    end

    it "reads vision: for hosts and models" do
      hosts = Samagotchi::ConfigFile.hosts_config(env: @env)
      expect(hosts["main"][:vision]).to be(false)
      expect(hosts["box"][:vision]).to be_nil
      expect(Samagotchi::ConfigFile.model_settings(env: @env)["ornith"]).to eq(profile: nil, vision: true)
      expect(JSON.parse(Samagotchi::ConfigFile.hosts_json_for_env(env: @env))["main"]).to include("vision" => false)
    end
  end
end
