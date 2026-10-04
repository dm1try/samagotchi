# frozen_string_literal: true

require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "support/test_kernel"

# What the user is told about the thinking level, once per session and host
# (a :hook_notice labelled "thinking", which both UIs render): an effort the
# native prompt has no knob for, and thinking off that the model ignored
# (logged each time).
RSpec.describe Samagotchi::Engine, "thinking notices" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "box:qwen-small"
    Dir.mktmpdir("chi-state") do |dir|
      @state_dir = dir
      example.run
    end
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
    ENV.delete("SAMAGOTCHI_THINKING_LEVEL")
  end

  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: { "box" => { host: "box.test", port: 8080 },
                                                 "other" => { host: "other.test", port: 8080 } })
  end
  let(:kernel) { test_kernel(client: registry.entries["box"].client) }
  let(:engine) do
    described_class.new(host_registry: registry, kernel: kernel, profile: "qwen36",
                        model_name: "box:qwen-small").tap { |e| e.session_state_dir = @state_dir }
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "box:qwen-small", working_directory: Dir.pwd) }
  let(:thinking_chars) { [0] }
  # Per generation, the thinking chunks it streamed (none by default).
  let(:thoughts) { [] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({})
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
    allow_any_instance_of(Samagotchi::Client).to receive(:cached_server_props).and_return(nil)
    allow(kernel).to receive(:run) do |messages, on_stream_event: nil, **|
      thinking_chars.each_with_index do |chars, index|
        on_stream_event&.call(type: :generation_started, iteration: index + 1)
        thoughts[index]&.each do |thought|
          on_stream_event&.call(type: :generation_chunk, iteration: index + 1, content: thought, thinking: thought, text: "")
        end
        on_stream_event&.call(type: :generation_completed, iteration: index + 1, content_length: 2, thinking_chars: chars)
      end
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
    end
  end

  def notices(prompt = "hi")
    events = []
    engine.run_turn(session, prompt, on_event: ->(e) { events << e })
    events.select { |e| e[:type] == :hook_notice }
  end

  it "says once per session and host that native Qwen has no effort knob" do
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "low"

    first = notices
    expect(first.size).to eq(1)
    expect(first.first).to include(hook: "thinking", level: :info)
    expect(first.first[:text]).to include("low", "qwen36", "box", "thinking stays as the model has it")
    expect(notices("again")).to be_empty

    engine.switch_model!("other:qwen-small")
    expect(notices("elsewhere").size).to eq(1)
  end

  describe "an effort on a llama.cpp chat host whose /props says the template takes none" do
    let(:registry) do
      Samagotchi::HostRegistry.new(hosts_config: { "box" => { host: "box.test", port: 8080, api: "openai" },
                                                   "other" => { host: "other.test", port: 8080, api: "openai" } })
    end
    let(:caps) { { "chat_template_caps" => { "supports_reasoning_effort" => false } } }

    # The chat loop's one request per turn, answered here (no server).
    before do
      allow_any_instance_of(Samagotchi::LLM::OpenAIChat).to receive(:chat).and_return(
        Samagotchi::LLM::ChatResponse.new(text: "ok", reasoning: "", tool_calls: [], usage: Samagotchi::LLM::Usage.none,
                                          finish_reason: "stop")
      )
      allow_any_instance_of(Samagotchi::LLM::OpenAIChat).to receive(:list_models).and_return([])
    end

    def props_seen(body)
      allow_any_instance_of(Samagotchi::Client).to receive(:cached_server_props)
        .and_return(body && Samagotchi::Client::ServerProps.new(body: body, status: :ok))
    end

    it "says once per session and host that the effort is ignored, from the probe the turn already made" do
      ENV["SAMAGOTCHI_THINKING_LEVEL"] = "low"
      props_seen(caps)

      first = notices
      expect(first.size).to eq(1)
      expect(first.first).to include(hook: "thinking", level: :info)
      expect(first.first[:text]).to eq("low isn't supported by qwen-small's chat template on box (/props: " \
                                       "supports_reasoning_effort false); thinking stays as the model has it")
      expect(notices("again")).to be_empty

      engine.switch_model!("other:qwen-small")
      expect(notices("elsewhere").size).to eq(1)
    end

    it "says nothing for off or default, for a template that takes an effort, or with no /props answer cached" do
      ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
      props_seen(caps)
      expect(notices).to be_empty
      ENV["SAMAGOTCHI_THINKING_LEVEL"] = "high"
      props_seen({ "chat_template_caps" => { "supports_reasoning_effort" => true } })
      expect(notices).to be_empty
      props_seen({ "chat_template" => "..." })
      expect(notices).to be_empty
      props_seen(nil)
      expect(notices).to be_empty
    end
  end

  it "says nothing for off or default on a native host that honours them" do
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    expect(notices).to be_empty
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "default"
    thinking_chars.replace([500])
    expect(notices).to be_empty
  end

  it "warns once when thinking off wasn't honoured, and logs it every time" do
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    thinking_chars.replace([0, 120])
    allow(Samagotchi::Log).to receive(:warn).and_call_original

    first = notices
    thinking_chars.replace([80])
    second = notices("again")

    expect(first.size).to eq(1)
    expect(first.first).to include(hook: "thinking", level: :warn)
    expect(first.first[:text]).to include("off", "qwen-small", "120", "sampling:")
    expect(second).to be_empty
    expect(Samagotchi::Log).to have_received(:warn).with(:model, "thinking_not_honoured", hash_including(chars: 120, host: "box"))
    expect(Samagotchi::Log).to have_received(:warn).with(:model, "thinking_not_honoured", hash_including(chars: 80))
  end

  it "says nothing when off's thinking lane held only whitespace (Gemma 4's empty thought)" do
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    thinking_chars.replace([1, 2])
    thoughts.replace([["\n"], [" ", "\n"]])
    expect(notices).to be_empty
  end

  it "still warns when off's thinking lane held a real thought after whitespace" do
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    thinking_chars.replace([1, 9])
    thoughts.replace([["\n"], ["\n", "let me "]])
    expect(notices.map { |n| n[:text] }).to contain_exactly(include("(9 chars of thinking)"))
  end

  it "says once that the host refused the thinking fields, and not also that off wasn't honoured" do
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    allow(kernel).to receive(:run) do |messages, on_stream_event: nil, **|
      on_stream_event&.call(type: :thinking_refused, iteration: 1, model: "qwen-small", level: :off,
                            detail: "HTTP 400: Reasoning is mandatory for this endpoint and cannot be disabled.")
      on_stream_event&.call(type: :generation_completed, iteration: 1, content_length: 2, thinking_chars: 300)
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
    end

    events = []
    engine.run_turn(session, "hi", on_event: ->(e) { events << e })
    shown = events.select { |e| e[:type] == :hook_notice }

    expect(shown.size).to eq(1)
    expect(shown.first).to include(hook: "thinking", level: :warn)
    expect(shown.first[:text]).to eq("box refused thinking: off for qwen-small (HTTP 400: Reasoning is mandatory for this " \
                                     "endpoint and cannot be disabled.); sent without it, so thinking stays as the model has it")
    expect(events.map { |e| e[:type] }).not_to include(:thinking_refused)
    expect(notices("again")).to be_empty
  end
end
