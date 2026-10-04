# frozen_string_literal: true

require "json"
require "samagotchi/model_profile"
require "samagotchi/client"
require "samagotchi/host_registry"

# Which prompt profile a model gets: --profile/env, then models:, then
# hosts.<name>.profile, then the llama.cpp server's chat template, then the
# name, then the default. A wrong profile is dangerous, not just degraded:
# a Qwen-based model under the gemma4 profile never hits a stop sequence and
# runs tool calls nobody asked for (see the plan's spike).
RSpec.describe "ModelProfile.resolve" do
  let(:ornith_props) { JSON.parse(File.read(File.expand_path("fixtures/llama_cpp/props_ornith.json", __dir__))) }
  let(:gemma4_template) { File.read(File.expand_path("fixtures/llama_cpp/gemma4_template_excerpt.jinja", __dir__)) }

  # A client whose /props answer is given; records the models it was asked about.
  class FakePropsClient
    attr_reader :asked, :transport

    def initialize(props, transport: :llama_cpp)
      @props = props
      @transport = Samagotchi::Client::Transport.new(transport)
      @asked = []
    end

    def server_props(model: nil)
      @asked << model
      @props
    end
  end

  def answered(body) = Samagotchi::Client::ServerProps.new(body: body, status: :ok)
  def failed(status = :network_error) = Samagotchi::Client::ServerProps.new(body: nil, status: status)

  def entry(**attrs) = Samagotchi::HostRegistry::HostEntry.new(name: "main", host: "h", port: 8081, **attrs)

  # entry() calls the helper above; without the () the default would be the
  # parameter itself (a circular argument reference).
  # rubocop:disable Style/MethodCallWithoutArgsParentheses
  def resolve(names: ["ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M"], entry: entry(), client: FakePropsClient.new(answered(ornith_props)),
              bare_model: names.first, override: [nil, :default], models: {})
    # rubocop:enable Style/MethodCallWithoutArgsParentheses
    Samagotchi::ModelProfile.resolve(names: names, entry: entry, client: client, bare_model: bare_model,
                                     override: override, models: models)
  end

  describe "ModelProfile.fingerprint" do
    it "reads qwen36 from the real Ornith /props (ChatML turns, <function= calls)" do
      expect(Samagotchi::ModelProfile.fingerprint(ornith_props)).to eq(["qwen36", "<|im_start|> + <function="])
    end

    it "reads gemma4 from Gemma 4's template" do
      expect(Samagotchi::ModelProfile.fingerprint("chat_template" => gemma4_template))
        .to eq(["gemma4", "<|turn> + <|tool_call>"])
    end

    it "gives any other ChatML template qwen36, whose <|im_end|> stop ends its turns" do
      expect(Samagotchi::ModelProfile.fingerprint("chat_template" => "<|im_start|>{{ m }}<|im_end|><tool_call>{"))
        .to eq(%w[qwen36 ChatML])
    end

    it "matches nothing without a template, or with Gemma 3's" do
      expect(Samagotchi::ModelProfile.fingerprint({})).to be_nil
      expect(Samagotchi::ModelProfile.fingerprint(nil)).to be_nil
      expect(Samagotchi::ModelProfile.fingerprint("chat_template" => "<start_of_turn>user\n{{ c }}<end_of_turn>")).to be_nil
    end
  end

  describe "ModelProfile.named" do
    it "is strict: a known name or nil" do
      expect(Samagotchi::ModelProfile.named(" Qwen36 ").name).to eq("qwen36")
      expect(Samagotchi::ModelProfile.named("gemma4").name).to eq("gemma4")
      expect(Samagotchi::ModelProfile.named("qwen")).to be_nil
      expect(Samagotchi::ModelProfile.named(nil)).to be_nil
    end

    it "knows the same names as the model.profile setting" do
      expect(Samagotchi::Config.find_by_key("model.profile").enum_values).to eq(Samagotchi::ModelProfile::NAMES)
    end
  end

  it "reads the server's chat template when nothing is configured (Ornith's name alone says neither family)" do
    client = FakePropsClient.new(answered(ornith_props))
    result = resolve(client: client)

    expect([result.profile.name, result.source, result.label]).to eq(["qwen36", :server, "server (chat_template)"])
    expect(result.detail).to eq("<|im_start|> + <function=")
    expect(result).not_to be_retry
    expect(client.asked).to eq(["ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M"])
  end

  it "beats the name with the server's answer" do
    result = resolve(names: ["gemma-looking-name"], client: FakePropsClient.new(answered(ornith_props)))

    expect([result.profile.name, result.source]).to eq(["qwen36", :server])
  end

  it "takes each layer in order: override, models:, hosts:, server, name, default" do
    gemma_server = FakePropsClient.new(answered("chat_template" => gemma4_template))
    models = { "ista" => { profile: "qwen36" } }
    host = entry(profile: "gemma4")

    expect(resolve(names: ["ista"], entry: host, models: models, override: ["gemma4", :cli]))
      .to have_attributes(source: :cli, label: "cli")
    expect(resolve(names: ["ista"], entry: host, models: models, override: ["gemma4", :env]))
      .to have_attributes(source: :env, label: "env")
    expect(resolve(names: ["ista"], entry: host, models: models, client: gemma_server).profile.name).to eq("qwen36")
    expect(resolve(names: ["ista"], entry: host, models: models).label).to eq("config (models: ista)")
    expect(resolve(names: ["other"], entry: host, models: models, client: FakePropsClient.new(answered(ornith_props))))
      .to have_attributes(source: :config, label: "config (hosts.main)")
    expect(resolve(names: ["other"], client: gemma_server).profile.name).to eq("gemma4")
    expect(resolve(names: ["my-qwen-finetune"], client: FakePropsClient.new(answered({}))))
      .to have_attributes(source: :name, label: "name")
    expect(resolve(names: ["mystery"], client: FakePropsClient.new(answered({}))))
      .to have_attributes(source: :default, label: "default")
  end

  it "matches models: under any of the names (as typed, alias-resolved, bare), ignoring case" do
    models = { "ornith-ai/ornith-1.5-35b-a3b-gguf:q4_k_m" => { profile: "gemma4" } }
    result = resolve(names: ["orn", "main:ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M", "ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M"],
                     models: models)

    expect([result.profile.name, result.detail]).to eq(["gemma4", "models: ornith-ai/ornith-1.5-35b-a3b-gguf:q4_k_m"])
  end

  it "treats a nil override as not set, whatever its origin" do
    expect(resolve(override: [nil, :cli]).source).to eq(:server)
  end

  it "warns once about an unknown configured profile and skips that layer" do
    result = nil
    expect { result = resolve(names: ["ista"], entry: entry(profile: "llama"), models: { "ista" => { profile: "qwen" } }) }
      .to output(/unknown profile "qwen" in models: ista.*\n.*unknown profile "llama" in hosts.main/).to_stderr
    expect(result.source).to eq(:server)
  end

  it "does not probe a chat host, mlx or omlx" do
    chat = FakePropsClient.new(answered(ornith_props))
    expect(resolve(names: ["mystery"], entry: entry(api: :openai), client: chat).source).to eq(:default)
    expect(chat.asked).to be_empty

    %i[mlx omlx].each do |transport|
      client = FakePropsClient.new(answered(ornith_props), transport: transport)
      expect(resolve(names: ["mystery"], entry: entry(transport: transport), client: client).source).to eq(:default)
      expect(client.asked).to be_empty
    end
  end

  it "marks the result retry when the probe failed (network error or non-200), falling back to the name" do
    [failed(:network_error), failed(:http_error)].each do |props|
      result = resolve(names: ["my-qwen-finetune"], client: FakePropsClient.new(props))

      expect([result.profile.name, result.source]).to eq(["qwen36", :name])
      expect(result).to be_retry
    end
  end

  it "is not retry when the server answered but matched nothing" do
    expect(resolve(names: ["mystery"], client: FakePropsClient.new(answered({})))).not_to be_retry
  end

  it "works without a client (no probe)" do
    expect(resolve(names: ["my-gemma"], client: nil).source).to eq(:name)
  end
end
