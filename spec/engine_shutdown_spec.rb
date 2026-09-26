# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"

# Engine#shutdown (plan P5): the REPL's and the worker's way out.
RSpec.describe "Engine#shutdown" do
  around do |example|
    previous = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = previous
  end

  let(:engine) { Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client), plugins: false) }
  let(:log) { Queue.new }

  def add_service(name)
    engine.instance_variable_get(:@services).add(
      Samagotchi::Plugin::Service.new(name) { |svc| svc.on_stop { log << "stop #{name}" } }
    ).tap(&:value)
  end

  def drained = Array.new(log.size) { log.pop }

  it "waits for the running anytime commands, then stops the services newest first" do
    add_service("a")
    add_service("b")
    engine.spawn_anytime do
      sleep(0.2)
      log << "command done"
    end
    engine.shutdown
    expect(drained).to eq(["command done", "stop b", "stop a"])
  end

  it "waits at most join_timeout for an anytime command that doesn't end" do
    add_service("a")
    gate = Queue.new
    thread = engine.spawn_anytime { gate.pop }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    engine.shutdown(join_timeout: 0.2)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    expect(drained).to eq(["stop a"])
    expect(thread).to be_alive
    gate << true
    thread.join
  end

  it "stops the idle jobs, and runs once" do
    scheduler = engine.instance_variable_get(:@idle_scheduler)
    add_service("a")
    expect(scheduler).to receive(:stop).once
    engine.shutdown
    engine.shutdown
    expect(drained).to eq(["stop a"])
  end
end
