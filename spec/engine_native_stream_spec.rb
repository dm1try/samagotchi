# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/client"
require "samagotchi/kernel_loop"
require "samagotchi/bridge/turn_accumulator"
require_relative "support/fake_provider_server"

# What the UIs get from a native (/completion) turn, through the real Engine
# and KernelLoop over HTTP: every :generation_chunk carries the split lanes,
# so the web's text lane (chunk_router.js) has the answer while it streams,
# and no model markup.
RSpec.describe Samagotchi::Engine, "native stream lanes" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = model
    FakeProviderServer.without_webmock { example.run }
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  let(:server) { FakeProviderServer.start }
  let(:client) { Samagotchi::Client.new(host: "127.0.0.1", port: server.port, transport: :llama_cpp, sleeper: ->(_s) {}) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: Dir.pwd) }
  let(:kernel) { Samagotchi::KernelLoop.new(client: client, profile: Samagotchi::ModelProfile.normalize(profile)) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: profile) }
  let(:events) { [] }

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }
  after { server.stop }

  def event(content) = "data: #{JSON.generate(content: content)}\n\n"
  def stop = "data: #{JSON.generate(content: "", stop: true)}\n\n"

  def stream(*pieces)
    server.enqueue("/completion", sse: pieces.map { |piece| event(piece) } + [stop])
  end

  def run_turn
    engine.run_turn(session, "hi", on_event: ->(e) { events << e })
  end

  # chunk_router.js#routeChunk: the split lanes when a chunk has them, else
  # raw content as text.
  def web_lanes(iteration = nil)
    chunks = events.select { |e| e[:type] == :generation_chunk && (iteration.nil? || e[:iteration] == iteration) }
    routed = chunks.map do |e|
      if e[:text].is_a?(String) || e[:thinking].is_a?(String)
        { text: e[:text].to_s, thinking: e[:thinking].to_s }
      else
        { text: e[:content].to_s, thinking: "" }
      end
    end
    { text: routed.map { |r| r[:text] }.join, thinking: routed.map { |r| r[:thinking] }.join }
  end

  context "with Gemma" do
    let(:model) { "gemma-4-e4b" }
    let(:profile) { "gemma4" }

    it "streams the answer into the web text lane" do
      stream("Hello ", "from ", "Gemma.")

      result = run_turn

      expect(result.output).to eq("Hello from Gemma.")
      expect(web_lanes).to eq(text: "Hello from Gemma.", thinking: "")
    end

    it "streams the thought channel into the thinking lane, no markup in either" do
      stream("<|channel>thought\nweighing ", "options<channel|>", "Hi ", "there.")

      run_turn

      expect(web_lanes).to eq(text: "Hi there.", thinking: "\nweighing options")
    end

    it "drops a tool call from the text lane and streams the answer after it" do
      stream('<|tool_call>call:memory_read{name:<|"|>notes<|"|>}', "<tool_call|>")
      stream("Nothing ", "saved.")

      result = run_turn

      expect(result.output).to eq("Nothing saved.")
      expect(events.map { |e| e[:type] }).to include(:tool_call_started)
      expect(web_lanes(1)).to eq(text: "", thinking: "")
      expect(web_lanes(2)).to eq(text: "Nothing saved.", thinking: "")
    end

    it "folds the lanes into the Bridge's turn the same way" do
      stream("<|channel>thought\npondering<channel|>", "Sure.")
      accumulator = Samagotchi::Bridge::TurnAccumulator.new
      accumulator.call(type: :turn_started, prompt: "hi")

      run_turn
      events.reject { |e| %i[turn_started turn_completed].include?(e[:type]) }.each { |e| accumulator.call(e) }

      parts = accumulator.current_turn[:parts].map { |part| part.slice(:kind, :text) }
      expect(parts).to eq([{ kind: "generation" }, { kind: "thinking", text: "\npondering" }, { kind: "text", text: "Sure." }])
    end
  end

  context "with Qwen" do
    let(:model) { "Qwen3.6" }
    let(:profile) { "qwen36" }

    it "keeps the lanes it had: thinking apart from the text" do
      stream("<think>", "reason", "</think>", "hi ", "there")

      run_turn

      expect(web_lanes).to eq(text: "hi there", thinking: "reason")
    end
  end
end
