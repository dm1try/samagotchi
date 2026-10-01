# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/session"
require "samagotchi/bridge"
require "samagotchi/cancellation_controller"
require "samagotchi/plugin/context"
require "support/thinking_off"

# Plugin init tasks (chi.init, docs/plugins.md): Engine#add_init_task,
# #start_init_tasks!, the turn's wait for tools (#await_init_tasks), their
# events, and the load events announced before the first turn.
RSpec.describe "Plugin init tasks" do
  include_context "thinking off"

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:seen) { [] }
  let(:ctx) do
    Samagotchi::Plugin::Context.new(bundle: "slowb", label: "plugin.rb (bundle slowb)", settings: {},
                                    host: engine.send(:plugin_host))
  end
  # The tools the kernel had when the turn's first model request went out.
  let(:tools_at_request) { [] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run) do
      tools_at_request << engine.instance_variable_get(:@tools).names.grep(/\Aslow_/)
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: [{ role: "model", content: "ok" }], exhausted: false,
                                       pending_tool_calls: false, tool_activity: [])
    end
    engine.subscribe(observer: ->(e) { seen << e })
  end

  # Gates the examples leave shut: opened before the shutdown, so it
  # doesn't wait out its join deadline.
  let(:gates) { [] }

  after do
    gates.each { |gate| gate << :go }
    engine.shutdown
  end

  def events(type) = seen.select { |e| e[:type] == type }
  def tasks = engine.instance_variable_get(:@plugin_tasks).tasks
  def join_tasks = tasks.each { |task| task.thread&.join(5) }

  # A task that brings the tool slow_tool once +gate+ opens.
  def add_tool_task(gate, timeout: 5, label: "Warming up")
    gates << gate
    engine.add_init_task(bundle: "slowb", label: label, plugin_label: "plugin.rb (bundle slowb)", provides_tools: true,
                         quiet: false, timeout: timeout) do
      gate.pop
      spec = Samagotchi::Plugin::Api.tool_spec("slow_tool", "a late tool") { "done" }
      engine.send(:stage_tools, "slowb", [spec], ctx)
      "1 tool"
    end
  end

  it "doesn't run before it is started; runs on its own thread, announced started and finished" do
    gate = Queue.new
    add_tool_task(gate)
    expect(events(:plugin_init_started)).to be_empty
    engine.start_init_tasks!
    Timeout.timeout(2) { sleep(0.01) until engine.init_tasks.any? }
    expect(engine.init_tasks).to eq([{ bundle: "slowb", id: "slowb-1", label: "Warming up" }])
    expect(events(:plugin_init_started)).to eq([{ type: :plugin_init_started, bundle: "slowb", id: "slowb-1",
                                                  label: "Warming up", event_seq: 1 }])
    gate << :go
    join_tasks
    expect(events(:plugin_init_finished).map { |e| e.except(:event_seq) })
      .to eq([{ type: :plugin_init_finished, bundle: "slowb", id: "slowb-1", label: "Warming up", ok: true, summary: "1 tool" }])
    expect(engine.init_tasks).to be_empty
    engine.start_init_tasks!
    expect(events(:plugin_init_started).size).to eq(1)
  end

  it "holds a turn before its first model request until the task is done, so the first prompt has its tools" do
    gate = Queue.new
    add_tool_task(gate)
    engine.start_init_tasks!
    sink = []
    turn = Thread.new { engine.run_turn(session, "hi", on_event: ->(e) { sink << e }) }
    Timeout.timeout(2) { sleep(0.01) until sink.any? { |e| e[:type] == :plugin_init_wait } }
    expect(sink.map { |e| e[:type] }.first).to eq(:turn_started)
    expect(sink.find { |e| e[:type] == :plugin_init_wait }[:tasks]).to eq([{ bundle: "slowb", id: "slowb-1", label: "Warming up" }])
    sleep(0.2)
    expect(tools_at_request).to be_empty
    gate << :go
    turn.join(5)
    expect(tools_at_request).to eq([["slow_tool"]])
  end

  it "starts the tasks itself when nothing did (a -p run)" do
    gate = Queue.new
    gate << :go
    add_tool_task(gate)
    engine.run_turn(session, "hi", on_event: ->(_e) {})
    expect(tools_at_request).to eq([["slow_tool"]])
  end

  it "stops waiting when the turn is cancelled (Ctrl-C); the task goes on and its tools come next turn" do
    gate = Queue.new
    add_tool_task(gate)
    engine.start_init_tasks!
    controller = Samagotchi::CancellationController.new
    Thread.new { sleep(0.3); controller.cancel!(:ctrl_c) }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    engine.await_init_tasks(controller)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(0.25, 1.5)
    expect(tasks.first.state).to eq(:running)
    expect(tasks.first.cancelled?).to be(false)
    gate << :go
    join_tasks
    engine.run_turn(session, "again", on_event: ->(_e) {})
    expect(tools_at_request).to eq([["slow_tool"]])
  end

  it "waits at most the task's timeout" do
    add_tool_task(Queue.new, timeout: 0.3)
    engine.start_init_tasks!
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    engine.run_turn(session, "hi", on_event: ->(_e) {})
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(0.25, 2)
    expect(tools_at_request).to eq([[]])
  end

  it "never holds a turn for a task that brings no tools" do
    gate = Queue.new
    gates << gate
    engine.add_init_task(bundle: "slowb", label: "Indexing", plugin_label: "x", provides_tools: false, quiet: false,
                         timeout: 5) { gate.pop }
    engine.start_init_tasks!
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    engine.run_turn(session, "hi", on_event: ->(_e) {})
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
  end

  it "shows a failure as finished (not ok) and a warn card a late UI still gets; the turn goes on without its tools" do
    store = Samagotchi::Bridge::CardStore.new
    engine.subscribe(observer: store)
    engine.add_init_task(bundle: "slowb", label: "Logging in", plugin_label: "x", provides_tools: true, quiet: false,
                         timeout: 5) { raise "no network" }
    engine.run_turn(session, "hi", on_event: ->(_e) {})
    expect(events(:plugin_init_finished).map { |e| e.slice(:ok, :error) }).to eq([{ ok: false, error: "no network" }])
    card = events(:card).first
    expect(card).to include(source: "slowb", title: "setup failed", body: "Logging in: no network", level: :warn,
                            in_turn: false)
    expect(store.list.map { |e| e[:title] }).to eq(["setup failed"])
    expect(tools_at_request).to eq([[]])
  end

  it "titles a failure's card with the task's own short title (failed:), the error alone in the body" do
    engine.add_init_task(bundle: "mcp", label: "Starting MCP server chrome (first run, saving its tools)", plugin_label: "x",
                         provides_tools: false, quiet: false, timeout: 5, failed: "chrome didn't start") { raise "no npx" }
    engine.start_init_tasks!
    Timeout.timeout(2) { sleep(0.01) until events(:card).any? }
    join_tasks
    expect(events(:card).first).to include(source: "mcp", title: "chrome didn't start", body: "no npx", level: :warn)
  end

  it "keeps a quiet task out of sight unless it fails" do
    engine.add_init_task(bundle: "slowb", label: "Refreshing", plugin_label: "x", provides_tools: false, quiet: true,
                         timeout: 5) { "fine" }
    engine.add_init_task(bundle: "slowb", label: "Refreshing more", plugin_label: "x", provides_tools: false, quiet: true,
                         timeout: 5) { raise "gone" }
    engine.start_init_tasks!
    Timeout.timeout(2) { sleep(0.01) until engine.init_tasks.empty? && tasks.all? { |t| %i[done failed].include?(t.state) } }
    join_tasks
    expect(events(:plugin_init_started) + events(:plugin_init_finished)).to be_empty
    expect(events(:card).map { |c| [c[:title], c[:body]] }).to eq([["setup failed", "Refreshing more: gone"]])
  end

  it "announces the task's notices and cards between turns, even while a turn runs; its ctx.cancelled? is its own" do
    gate = Queue.new
    cancelled = []
    engine.add_init_task(bundle: "slowb", label: "Busy", plugin_label: "x", provides_tools: false, quiet: false,
                         timeout: 5) do
      gate.pop
      ctx.notify("from the task")
      ctx.card(title: "task card")
      cancelled << ctx.cancelled?
      nil
    end
    engine.start_init_tasks!
    sink = []
    engine.register_hook(:before_turn) do |_e|
      gate << :go
      join_tasks
    end
    allow(engine).to receive(:active_cancel_controller).and_return(double(cancelled?: true))
    engine.run_turn(session, "hi", on_event: ->(e) { sink << e })
    expect(events(:hook_notice).map { |e| [e[:text], e[:between_turns]] }).to eq([["from the task", true]])
    expect(events(:card).map { |e| [e[:title], e[:in_turn]] }).to eq([["task card", false]])
    expect(sink.map { |e| e[:type] }).not_to include(:hook_notice, :card)
    expect(cancelled).to eq([false])
  end

  it "is cancelled and joined on shutdown, and announces nothing after it" do
    stopped = Queue.new
    engine.add_init_task(bundle: "slowb", label: "Downloading", plugin_label: "x", provides_tools: true, quiet: false,
                         timeout: 30) do
      sleep(0.01) until ctx.cancelled?
      stopped << :cancelled
      raise "cancelled"
    end
    engine.start_init_tasks!
    Timeout.timeout(2) { sleep(0.01) until engine.init_tasks.any? }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    engine.shutdown
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    expect(stopped.pop(timeout: 1)).to eq(:cancelled)
    expect(events(:plugin_init_finished) + events(:card)).to be_empty
    engine.start_init_tasks!
  end

  describe "Engine#announce_load_events!" do
    it "announces the load warnings and what plugins showed while loading, once, between turns" do
      engine.instance_variable_get(:@guardrail_failures).add("hook x.rb", "missing", required: true)
      engine.instance_variable_get(:@plugin_failures).add("plugin plugin.rb (bundle b)", "boom", required: false)
      engine.instance_variable_set(:@plugin_load_events, [
                                     { type: :hook_notice, hook: "plugin.rb (bundle b)", text: "loaded", level: :info },
                                     { type: :card, id: "c", source: "b", title: "hi", body: "", level: :info, actions: [], in_turn: true }
                                   ])
      expect(engine.guardrail_warning).to be_nil
      engine.announce_load_events!
      engine.announce_load_events!
      expect(seen.map { |e| [e[:type], e[:label], e[:between_turns], e[:in_turn]] }).to eq(
        [[:guardrail_warning, nil, nil, nil], [:guardrail_warning, "plugins", nil, nil],
         [:hook_notice, nil, true, nil], [:card, nil, nil, false]]
      )
      expect(engine.guardrail_warning).to include("missing")
      expect(engine.plugin_warning).to include("boom")
      sink = []
      engine.run_turn(session, "hi", on_event: ->(e) { sink << e })
      expect(sink.map { |e| e[:type] }).not_to include(:guardrail_warning, :hook_notice, :card)
    end
  end
end
