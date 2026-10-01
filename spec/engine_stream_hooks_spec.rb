# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/client"
require "samagotchi/kernel_loop"
require "samagotchi/llm/chat_loop"
require "samagotchi/llm/openai_chat"
require_relative "support/fake_provider_server"
require "support/test_kernel"

# The :generation_progress hook through the Engine, over real HTTP on both
# paths: a hook sees the stream in batches, and can stop the turn or cut
# the generation from inside the chunk callback (the turn's thread).
RSpec.describe Samagotchi::Engine, "stream hooks" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Qwen3.6"
    FakeProviderServer.without_webmock { example.run }
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  let(:server) { FakeProviderServer.start }
  let(:client) { Samagotchi::Client.new(host: "127.0.0.1", port: server.port, transport: :llama_cpp, sleeper: ->(_s) {}) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Qwen3.6", working_directory: Dir.pwd) }
  let(:controller) { Samagotchi::CancellationController.new }
  let(:events) { [] }
  let(:progress) { [] }
  let(:sentence) { "I should check the file again to be sure about it. " * 4 }

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }
  after { server.stop }

  def completions = server.requests.select { |r| r.path.end_with?("completion", "completions") }
  def of_type(type) = events.select { |e| e[:type] == type }

  def run_turn(engine)
    engine.run_turn(session, "hi", on_event: ->(e) { events << e }, cancel_controller: controller)
  end

  shared_examples "stream hooks" do
    it "stops the turn from the hook within one fire" do
      stream_loop
      engine.register_hook(:generation_progress) do |event|
        progress << event
        event[:stop_turn].call("enough")
      end

      result = run_turn(engine)

      expect(result).to be_canceled
      expect(of_type(:turn_canceled).first).to include(cancellation_reason: :hook)
      expect(progress.size).to eq(1)
      expect(completions.size).to eq(1)
      expect(of_type(:hook_notice).map { |e| e[:text] }).to eq(["stopped the turn: enough"])
      expect(session.messages.last[:content]).to include("the previous turn was cancelled (hook turn hook: enough)")
    end

    it "cuts the generation from the hook: the turn asks again and answers, and core posts no notice" do
      stream_loop
      stream_answer("PONG")
      engine.register_hook(:generation_progress) do |event|
        progress << event
        event[:stop_generation].call("loops") if event[:iteration] == 1
      end

      result = run_turn(engine)

      expect(result.output).to eq("PONG")
      expect(of_type(:turn_completed)).not_to be_empty
      expect(progress.first).to include(iteration: 1)
      expect(progress.first[:thinking]).to include("check the file again")
      expect(progress.map { |e| e[:iteration] }.uniq).to eq([1])
      expect(completions.size).to eq(2)
      expect(of_type(:empty_answer_retry)).to contain_exactly(include(stopped_by: "turn hook"))
      expect(of_type(:hook_notice)).to be_empty
      expect(session.messages.map { |m| m[:content].to_s }.join).not_to include("check the file again")
    end
  end

  describe "on the native path" do
    let(:kernel) { Samagotchi::KernelLoop.new(client: client, profile: Samagotchi::ModelProfile.qwen36) }
    let(:engine) { described_class.new(client: client, kernel: kernel, profile: "qwen36") }

    def event(content) = "data: #{JSON.generate(content: content)}\n\n"

    def stream_loop
      server.enqueue("/completion", sse: [event("<think>"), *Array.new(20) { event(sentence) }], delay: 0.005, hold: true)
    end

    def stream_answer(text)
      server.enqueue("/completion", sse: [event("<think>"), event("ok"), event("</think>"), event(text),
                                          "data: #{JSON.generate(content: "", stop: true)}\n\n"])
    end

    it_behaves_like "stream hooks"

    it "gives the hook Qwen's thinking apart from the text" do
      server.enqueue("/completion", sse: [event("<think>"), event("a" * 1200), event("b" * 1200), event("</think>"),
                                          event("c" * 2500), "data: #{JSON.generate(content: "", stop: true)}\n\n"])
      engine.register_hook(:generation_progress) { |event| progress << event }

      run_turn(engine)

      expect(progress.map { |e| e[:thinking] }.join).to eq(("a" * 1200) + ("b" * 1200))
      expect(progress.map { |e| e[:text] }.join).to eq("c" * 2500)
      expect(progress.map { |e| e[:text] }.join).not_to include("<think>", "</think>")
    end
  end

  describe "on the chat path" do
    let(:kernel) { test_kernel(client: client) }
    let(:engine) { described_class.new(client: client, kernel: kernel, profile: "qwen36") }
    let(:adapter) { Samagotchi::LLM::OpenAIChat.new(base_url: server.base_url, host_name: "box", sleeper: ->(_s) {}) }

    before do
      allow(kernel).to receive(:sampling=)
      allow(kernel).to receive(:strip_model_thought) { |text| text.to_s.strip }
      allow(engine).to receive(:backend_for).and_return(Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter))
    end

    def delta(fields = {}, finish: nil, **more)
      "data: #{JSON.generate(choices: [{ index: 0, delta: fields.merge(more), finish_reason: finish }])}\n\n"
    end

    def stream_loop
      server.enqueue("/v1/chat/completions", sse: Array.new(20) { delta(reasoning_content: sentence) }, delay: 0.005, hold: true)
    end

    def stream_answer(text)
      server.enqueue("/v1/chat/completions", sse: [delta(reasoning_content: "ok"), delta(content: text),
                                                   delta({}, finish: "stop"), "data: [DONE]\n\n"])
    end

    it_behaves_like "stream hooks"
  end

  describe "the stream handler" do
    let(:kernel) { test_kernel(client: client) }
    let(:engine) { described_class.new(client: client, kernel: kernel, profile: "qwen36") }

    it "builds no StreamWatch when no hook listens" do
      expect(Samagotchi::Hooks::StreamWatch).not_to receive(:new)

      handler = engine.send(:build_stream_event_handler, ->(e) { events << e }, cancel_controller: controller)
      handler.call({ type: :generation_started, iteration: 1 })
      handler.call({ type: :generation_chunk, iteration: 1, content: "x" * 3000 })

      expect(events.map { |e| e[:type] }).to eq(%i[generation_started generation_chunk])
    end

    it "gives the UIs a chunk before the hook sees it" do
      order = []
      engine.register_hook(:generation_progress) { |_e| order << :hook }
      handler = engine.send(:build_stream_event_handler, ->(e) { order << e[:type] }, cancel_controller: controller)
      handler.call({ type: :generation_started, iteration: 1 })
      handler.call({ type: :generation_chunk, iteration: 1, content: "x" * 3000 })

      expect(order).to eq(%i[generation_started generation_chunk hook])
    end
  end
end
