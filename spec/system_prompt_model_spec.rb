# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"

# The system prompt names the model the session runs on (its resolved ref,
# host and overlay key), so a model asked which one it is answers from that
# line and not from training. The text depends only on the effective model:
# built once, rebuilt only by a model switch (no new KV churn).
RSpec.describe "Engine#system_prompt names the model" do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { host: "box.test", port: 8080 },
      "oai" => { host: "oai.test", port: 8000, api: :openai }
    })
  end

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("(index)")
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
  end

  def engine(model, profile = "gemma4")
    Samagotchi::Engine.new(host_registry: registry, model_name: model, profile: profile)
  end

  def model_lines(prompt) = prompt.lines.grep(/\AModel: |\AAsked which model/).join

  it "states the ref, host and overlay key, and to answer from it" do
    prompt = engine("oai:Qwen3.8-27B-Splash").system_prompt

    expect(prompt).to include("Model: this session runs on oai:Qwen3.8-27B-Splash (host oai, oai.test:8000; " \
                              "model key qwen3-8-27b-splash).\n")
    expect(prompt).to include("Asked which model you are, answer with this line, not from training")
    expect(prompt).to include("memory_write current_model_only: true")
  end

  it "sits before the working directory and the session id" do
    e = engine("box:gemma-small")
    e.session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    prompt = e.system_prompt

    expect(prompt.index("Model: this session runs on")).to be < prompt.index("Current working directory:")
    expect(prompt.index("Current working directory:")).to be < prompt.index("Current session id:")
  end

  # The prompt caches reuse only an exact prefix: what differs between
  # sessions (model, location, session) closes the prompt, before only
  # Gemma's tool declarations.
  [["box:qwen", "qwen36", false], ["box:gemma-small", "gemma4", false], ["oai:m", "qwen36", true]].each do |model, profile, chat|
    it "ends with the model, location and session lines (#{profile}#{", chat" if chat})" do
      e = engine(model, profile)
      e.session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
      prompt = e.system_prompt
      prompt = prompt.split(/(?=<\|tool>)/, 2).first if profile == "gemma4"
      tail = prompt[prompt.index("Model: this session runs on")..]

      expect(tail).to include("Current working directory:", "Current session id:")
      expect(tail).not_to include("Project memories:", "System memories:", "System identity", "Editing workflow:")
      expect(prompt.index("System identity")).to be < prompt.index("Project memories:")
    end
  end

  # A remote Claude model's cache breakpoint goes there (PromptCache).
  it "says where a chat prompt's stable part ends, and the chat loop sends it with the system message" do
    e = engine("oai:m", "qwen36")
    e.session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    prompt = e.system_prompt
    split = e.instance_variable_get(:@prompt_builder).stable_length(prompt)

    expect(prompt[split..]).to start_with("Model: this session runs on oai:m")
    expect(prompt[0, split]).to end_with("System memories:\n(index)\n")
    wire = e.send(:backend_for, registry.resolve("oai:m")).wire_messages([{ role: "system", content: prompt },
                                                                          { role: "user", content: "hi" }])
    expect(wire.first).to eq({ role: "system", content: prompt, cache_split: split })

    native = engine("box:gemma-small")
    expect(native.instance_variable_get(:@prompt_builder).stable_length(native.system_prompt)).to be_nil
    expect(e.instance_variable_get(:@prompt_builder).stable_length("#{prompt} ")).to be_nil
  end

  it "is the same text across builds and changes after a model switch" do
    e = engine("box:gemma-small")
    first = model_lines(e.system_prompt)
    e.send(:tools_changed!)
    expect(model_lines(e.system_prompt)).to eq(first)

    e.switch_model!("oai:m")
    expect(model_lines(e.system_prompt)).to include("runs on oai:m (host oai, oai.test:8000; model key m)")
    expect(model_lines(e.system_prompt)).not_to eq(first)
  end

  describe "the served model clause (llama.cpp's /props, from the cache)" do
    def props(name) = Samagotchi::Client::ServerProps.new(body: { "model_alias" => name }, status: :ok)

    it "says what the server serves when it differs from the name" do
      allow_any_instance_of(Samagotchi::Client).to receive(:cached_server_props).and_return(props("ornith-1.5"))
      expect(engine("box:gemma-small").system_prompt)
        .to include("(host box, box.test:8080; model key gemma-small; the server says it serves ornith-1.5).")
    end

    it "says nothing when it serves the name, or nothing is known yet" do
      allow_any_instance_of(Samagotchi::Client).to receive(:cached_server_props).and_return(props("gemma-small"))
      expect(engine("box:gemma-small").system_prompt).not_to include("the server says")

      allow_any_instance_of(Samagotchi::Client).to receive(:cached_server_props).and_return(nil)
      expect(engine("box:gemma-small").system_prompt).not_to include("the server says")
    end

    it "never asks a chat host" do
      expect_any_instance_of(Samagotchi::Client).not_to receive(:cached_server_props)
      expect(engine("oai:m").system_prompt).not_to include("the server says")
    end
  end

  it "is left out without a model lookup" do
    prompt = Samagotchi::SystemPrompt.new(profile: -> { Samagotchi::ModelProfile.gemma4 }, tools: -> { [] },
                                          session: -> {}, thinking: -> {})
    expect(prompt.build).not_to include("Model: this session runs on")
  end
end
