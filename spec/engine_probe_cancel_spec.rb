# frozen_string_literal: true

require "socket"
require "samagotchi/engine"
require "samagotchi/session"
require_relative "support/fake_chat_adapter"
require_relative "support/fake_provider_server"
require "support/test_kernel"

# A Stop right after a turn starts, while the turn's /props probe waits on a
# server that doesn't answer (a llama.cpp busy on a long prompt): the probe is
# cut and the turn ends as canceled at once, not after the probe's timeout.
RSpec.describe Samagotchi::Engine, "#run_turn with a hung /props" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    FakeProviderServer.without_webmock { example.run }
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  # Accepts and never answers.
  let(:hung) { TCPServer.new("127.0.0.1", 0) }
  let(:accepted) { Queue.new }
  let(:client) { Samagotchi::Client.new(host: "127.0.0.1", port: hung.addr[1], sleeper: ->(_seconds) {}) }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:events) { [] }
  let(:adapter) do
    FakeChatAdapter.new(lambda { |cancel_controller:, **|
      raise Samagotchi::LLM::RequestCancelled, cancel_controller.reason if cancel_controller&.cancelled?

      FakeChatAdapter.text("PONG")
    })
  end

  before do
    stub_const("Samagotchi::Client::CONTEXT_WINDOW_PROBE_READ_TIMEOUT", 5)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(engine).to receive(:backend_for).and_return(Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter))
    @acceptor = Thread.new do
      loop { accepted << hung.accept }
    rescue IOError, Errno::EBADF
      nil
    end
  end

  after do
    @acceptor.kill
    hung.close
    accepted.size.times { accepted.pop.close }
  end

  it "ends the turn as canceled well under a second after the Stop" do
    controller = Samagotchi::CancellationController.new
    stopped_at = nil
    on_event = lambda do |event|
      events << event
      next unless event[:type] == :turn_started

      Thread.new do
        accepted.pop.tap { |socket| accepted << socket } # the probe is waiting
        sleep 0.1
        stopped_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        controller.cancel!(:user)
      end
    end

    engine.run_turn(session, "hi", on_event: on_event, cancel_controller: controller)

    expect(events.map { |e| e[:type] }).to include(:turn_canceled)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - stopped_at).to be < 0.5
    expect(Samagotchi::Client.probe_cancel).to be_nil
  end
end
