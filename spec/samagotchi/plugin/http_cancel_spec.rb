# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/session"
require "samagotchi/plugin/context"
require "support/thinking_off"
require "support/test_kernel"

# What a ctx.http call without cancel: stops with (docs/plugins.md,
# "Calling services"): Host#cancel_controller on a real Engine, and how
# Context asks it.
RSpec.describe "ctx.http's default cancel controller" do
  include_context "thinking off"

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:engine) { Samagotchi::Engine.new(client: client) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:host) { engine.send(:plugin_host) }
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "demo", label: "plugin.rb (bundle demo)", settings: {}, host: host) }
  let(:turn_controller) { Samagotchi::CancellationController.new }

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  # The controller a call would use, as ctx.http reads it (Context's lookup).
  def lookup = host.cancel_controller.call(handler: ctx.send(:in_handler?))

  def run_turn(&)
    allow(client).to receive(:complete) do |*|
      yield
      "done"
    end
    engine.run_turn(session, "go", cancel_controller: turn_controller)
  end

  it "is nil between turns" do
    expect(lookup).to be_nil
  end

  it "is the turn's controller on the turn thread (where tool calls run)" do
    seen = nil

    run_turn { seen = lookup }

    expect(seen).to be(turn_controller)
  end

  it "is the turn's controller inside a plugin handler, whatever thread fires it" do
    seen = nil

    run_turn do
      event = { type: :before_tool_call }
      Thread.new { ctx.with_event(event) { seen = lookup } }.join
    end

    expect(seen).to be(turn_controller)
  end

  it "is nil on a thread the plugin started, an anytime command's among them" do
    seen = :unset

    run_turn { Thread.new { seen = lookup }.join }

    expect(seen).to be_nil
  end

  it "is nil in an after_turn hook of a stopped turn, though the turn's controller is still cancelled" do
    allow(client).to receive(:complete) do |*|
      turn_controller.cancel!(:manual)
      raise Samagotchi::Client::RequestCancelled, :manual
    end
    during_hook = []
    engine.instance_variable_get(:@hooks).register_persistent(:after_turn, label: "demo") do |_event|
      during_hook << lookup << host.cancelled.call
      during_hook << Thread.new { ctx.with_event({}) { lookup } }.value
    end

    engine.run_turn(session, "go", cancel_controller: turn_controller)

    expect(during_hook).to eq([nil, true, nil])
  end

  it "is nil in a session_end hook of a completed turn" do
    seen = :unset
    engine.instance_variable_get(:@hooks).register_persistent(:session_end, label: "demo") { |_event| seen = lookup }
    allow(client).to receive(:complete).and_return("done")

    engine.run_turn(session, "go", cancel_controller: turn_controller)

    expect(seen).to be_nil
  end

  it "is the turn's again for the next turn (the ended flag doesn't carry over)" do
    seen = nil
    allow(client).to receive(:complete).and_return("done")
    engine.run_turn(session, "one")
    next_controller = Samagotchi::CancellationController.new

    allow(client).to receive(:complete) do |*|
      seen = lookup
      "done"
    end
    engine.run_turn(session, "two", cancel_controller: next_controller)

    expect(seen).to be(next_controller)
  end

  it "is an init task's own controller inside the task, not the turn's" do
    inside = nil
    release = Queue.new
    engine.add_init_task(bundle: "demo", label: "warm", plugin_label: "plugin.rb (bundle demo)", provides_tools: false,
                         quiet: true, timeout: 5) do
      inside = lookup
      release.pop
      "ok"
    end
    engine.start_init_tasks!
    Timeout.timeout(5) { sleep(0.01) until inside }
    task = engine.instance_variable_get(:@plugin_tasks).tasks.first

    expect(inside).to be(task.cancel)
    expect(inside).not_to be(turn_controller)
  ensure
    release << :go
    engine.shutdown
  end

  it "is what ctx.http uses when a call gives no cancel: (a Host without the member, a spec's own, means none)" do
    stopped = Samagotchi::CancellationController.new.tap { |c| c.cancel!(:manual) }
    seen = []
    stopping = Samagotchi::Plugin::Host.new(cancel_controller: lambda { |handler:|
      seen << handler
      stopped
    })
    context = Samagotchi::Plugin::Context.new(bundle: "demo", label: "x", settings: {}, host: stopping)

    expect { context.http.get("http://127.0.0.1:1/x") }.to raise_error(Samagotchi::Plugin::HttpCancelled)
    expect(context.http).to equal(context.http)
    expect(seen).to eq([false])
    bare = Samagotchi::Plugin::Context.new(bundle: "demo", label: "x", settings: {}, host: Samagotchi::Plugin::Host.new)
    expect(bare.http.send(:instance_variable_get, :@cancel_lookup).call).to be_nil
  end
end
