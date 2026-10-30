# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/session"
require "samagotchi/plugin/context"
require "samagotchi/plugin/tool_spec"
require "support/thinking_off"
require "support/test_kernel"
require_relative "../../support/fake_provider_server"

# A plugin's ctx.http call really stops when the user presses Stop
# (Engine#cancel_current_turn!): a tool's call, on a real Engine and a real
# socket; and the after_turn hook of the stopped turn can still call.
RSpec.describe "ctx.http and the turn's Stop" do
  include_context "thinking off"

  around do |example|
    FakeProviderServer.without_webmock { with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }
  end

  let(:server) { FakeProviderServer.start }
  let(:client) { test_client }
  let(:engine) { Samagotchi::Engine.new(client: client) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:ctx) do
    Samagotchi::Plugin::Context.new(bundle: "demo", label: "plugin.rb (bundle demo)", settings: {},
                                    host: engine.send(:plugin_host))
  end
  let(:outcome) { Queue.new }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    server.enqueue("/slow", sse: [], hold: true)
    server.enqueue("/after", body: "after-ok")
    tool = Samagotchi::Plugin::ToolSpec.build("slow_call", "calls a slow service", params: {}) do |_args, context|
      context.http.get("#{server.root_url}/slow", timeout: 60).body
    rescue Samagotchi::Plugin::HttpCancelled
      outcome << :tool_cancelled
      "cancelled"
    end
    Samagotchi::Plugin::ToolSpec.apply(engine.tools, "demo", [tool], ctx)
    engine.instance_variable_get(:@hooks).register_persistent(:after_turn, label: "demo") do |_event|
      ctx.with_event({}) { outcome << [:hook, ctx.http.get("#{server.root_url}/after").body] }
    rescue Samagotchi::Plugin::HttpError => e
      outcome << [:hook_failed, e.class]
    end
    replies = ["<|tool_call>call:slow_call{}<tool_call|>", "done"]
    allow(client).to receive(:complete) do |_prompt, **kwargs|
      ctrl = kwargs[:cancel_controller]
      raise Samagotchi::Client::RequestCancelled, ctrl.reason if ctrl&.cancelled?

      replies.shift || "done"
    end
  end

  after do
    server.stop
    engine.shutdown
  end

  it "stops a tool's call promptly (not after its 60 s timeout), and the after_turn hook's call still goes through" do
    events = []
    turn = Thread.new { engine.run_turn(session, "go", on_event: ->(e) { events << e }) }
    wait_for("the tool's /slow request", timeout: 10) { server.requests.any? { |request| request.path == "/slow" } }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect(engine.cancel_current_turn!(:manual)).to be(true)
    join!(turn, "the cancelled turn", timeout: 10)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(5, below: 60)
    expect(outcome.pop(timeout: 1)).to eq(:tool_cancelled)
    expect(outcome.pop(timeout: 5)).to eq([:hook, "after-ok"])
    expect(events.map { |e| e[:type] }).to include(:turn_canceled)
  end
end
