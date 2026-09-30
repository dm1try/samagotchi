# frozen_string_literal: true

require "samagotchi/engine"

# The chat loop sends the tools as schemas, so its system prompt leaves out
# the raw-prompt tool declarations, the call syntax, the Qwen turn preamble
# and Gemma's thinking token (F1). The native prompt is unchanged (the
# prompt snapshots pin it).
RSpec.describe "Engine#system_prompt per loop" do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { host: "box.test", port: 8080 },
      "oai" => { host: "oai.test", port: 8000, api: :openai }
    })
  end

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("(index)") }

  def engine(model, profile)
    Samagotchi::Engine.new(host_registry: registry, model_name: model, profile: profile)
  end

  %w[gemma4 qwen36].each do |profile|
    it "gives a #{profile} model on a chat host no raw tool-call text" do
      prompt = engine("oai:m", profile).system_prompt

      expect(prompt).not_to include("<tools>", "<tool_call>", "<|tool_call>", "<|think|>", "Turn preamble", "call:execute")
      expect(prompt).not_to include(Samagotchi::ToolDeclarations::TOOL_CALL_HINT.strip.lines.first.strip)
      expect(prompt).to start_with("You are Chi")
      expect(prompt).to include("Editing workflow:", "Memory convention:", "Small-context retrieval protocol:", "Project memories:\n(index)")
    end
  end

  it "keeps the native prompt for a raw host" do
    e = engine("box:gemma-small", "gemma4")

    expect(e.system_prompt).to start_with("<|think|>\n" + e.assist_system_prompt)
  end

  it "answers for a given target, and rebuilds both after a model switch" do
    e = engine("box:gemma-small", "gemma4")
    native = e.system_prompt
    chat = e.system_prompt(registry.resolve("oai:m"))
    expect(chat).not_to include("<|tool_call>")
    expect(native).to include("<|tool_call>")

    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("(new index)")
    e.switch_model!("oai:m")

    expect(e.system_prompt).to include("(new index)")
    expect(e.system_prompt(registry.resolve("box:gemma-small"))).to include("(new index)")
  end

  describe "with a thinking level" do
    around do |example|
      ENV["SAMAGOTCHI_THINKING_LEVEL"] = level
      example.run
    ensure
      ENV.delete("SAMAGOTCHI_THINKING_LEVEL")
    end

    context "off" do
      let(:level) { "off" }

      it "leaves out Gemma's thinking token" do
        e = engine("box:gemma-small", "gemma4")

        expect(e.system_prompt).to start_with(e.assist_system_prompt)
        expect(e.system_prompt).not_to include("<|think|>")
      end

      it "leaves out the Qwen turn preamble (there is no thinking to start with TURN:)" do
        expect(engine("box:qwen-small", "qwen36").system_prompt).not_to include("Turn preamble")
      end
    end

    context "low (no native knob)" do
      let(:level) { "low" }

      it "keeps the thinking token and the preamble" do
        expect(engine("box:gemma-small", "gemma4").system_prompt).to start_with("<|think|>\n")
        expect(engine("box:qwen-small", "qwen36").system_prompt).to include("Turn preamble")
      end
    end
  end

  it "builds the prompt again when the level changes" do
    e = engine("box:gemma-small", "gemma4")
    expect(e.system_prompt).to start_with("<|think|>")

    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    expect(e.system_prompt).not_to include("<|think|>")
  ensure
    ENV.delete("SAMAGOTCHI_THINKING_LEVEL")
  end
end
