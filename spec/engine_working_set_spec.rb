# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/client"
require "samagotchi/kernel_loop"
require "tmpdir"
require_relative "support/fake_provider_server"

# The working set's :working_set_updated event (WorkingSet), through the real
# Engine and KernelLoop over HTTP: at each request after a tool ran and at
# turn end, only when the set changed, never while it is empty.
RSpec.describe Samagotchi::Engine, "working set event" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "gemma-4-e4b"
    Dir.mktmpdir("ws-engine") do |dir|
      @dir = dir
      FakeProviderServer.without_webmock { example.run }
    end
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  let(:server) { FakeProviderServer.start }
  let(:client) { Samagotchi::Client.new(host: "127.0.0.1", port: server.port, sleeper: ->(_s) {}) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "gemma-4-e4b", working_directory: @dir) }
  let(:kernel) { Samagotchi::KernelLoop.new(client: client, profile: Samagotchi::ModelProfile.normalize("gemma4")) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:events) { [] }
  let(:path) { File.join(@dir, "notes.txt") }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    File.write(path, "one\ntwo\n")
  end

  after { server.stop }

  def stream(*pieces)
    server.enqueue("/completion", sse: pieces.map { |piece| "data: #{JSON.generate(content: piece)}\n\n" } +
                                       ["data: #{JSON.generate(content: "", stop: true)}\n\n"])
  end

  def run_turn(prompt = "hi") = engine.run_turn(session, prompt, on_event: ->(e) { events << e })

  def updates = events.select { |e| e[:type] == :working_set_updated }

  it "emits the set at the request after a tool ran, and not again at turn end when it didn't change" do
    stream(%(<|tool_call>call:read{path:<|"|>#{path}<|"|>}<tool_call|>))
    stream("Read it.")

    run_turn

    expect(updates.size).to eq(1)
    expect(updates.first[:items]).to match([include(kind: "file", key: path, state: "live", ops: %w[read], count: 1)])
    expect(updates.first[:at]).to be_a(Integer)
    started = events.index { |e| e[:type] == :generation_started && e[:iteration] == 2 }
    expect(events.index(updates.first)).to be > started
  end

  it "emits it again when it changed: the file changed outside chi since the model read it" do
    stream(%(<|tool_call>call:read{path:<|"|>#{path}<|"|>}<tool_call|>))
    stream("Read it.")
    run_turn
    File.write(path, "one\ntwo\nthree\n")
    stream("Still here.")

    run_turn("again")

    expect(updates.map { |u| u[:items].first[:state] }).to eq(%w[live stale])
  end

  it "emits it at turn end when the turn's last step ran a tool no request followed (out of iterations)" do
    stream(%(<|tool_call>call:read{path:<|"|>#{path}<|"|>}<tool_call|>))

    engine.run_turn(session, "hi", on_event: ->(e) { events << e }, max_iterations: 1)

    expect(updates.size).to eq(1)
    expect(events.index(updates.first)).to be > events.rindex { |e| e[:type] == :tool_call_completed }
    expect(events.index(updates.first)).to be < events.index { |e| e[:type] == :turn_completed }
  end

  it "emits nothing for a tool-free turn" do
    stream("Hello.")

    run_turn

    expect(updates).to be_empty
  end
end
