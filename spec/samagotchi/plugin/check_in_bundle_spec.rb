# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/session_commands"
require "samagotchi/turn_flow"
require "samagotchi/memory_bundle/installer"
require "support/plugin_handler_ctx"
require "support/test_kernel"

# The shipped check-in bundle (lib/samagotchi/bundles/check-in): the plugin
# on its own with a recording chi and ctx, then installed as a user would
# and loaded by an Engine that runs real turns.
RSpec.describe "The check-in plugin" do
  let(:source) { File.expand_path("../../../lib/samagotchi/bundles/check-in/plugin.rb", __dir__) }
  let(:ctx) do
    Class.new do
      prepend PluginHandlerCtx

      attr_reader :notices, :cards, :steers, :stops
      attr_accessor :running, :session_id, :data_dir

      def initialize
        @session_id = "s1"
        @data_dir = Dir.mktmpdir("check-in-data-")
        @notices = []
        @cards = []
        @steers = []
        @stops = []
        @running = true
      end

      def notify(text, level: :info) = @notices << [text, level]
      def card(**card) = @cards << card
      def steer(text) = @running && (@steers << text) && true
      def stop_turn(reason) = @running && (@stops << reason) && true
    end.new
  end
  let(:steered) { [] }

  after { FileUtils.rm_rf(ctx.data_dir) }

  # The plugin as the loader builds it: its file in a module of its own,
  # register(chi) collecting the chi.on blocks and the command.
  def plugin(settings = {})
    mod = Module.new
    mod.module_eval(File.read(source), source)
    hooks = Hash.new { |h, k| h[k] = [] }
    commands = {}
    chi = Object.new
    chi.define_singleton_method(:on) { |event, priority: 100, &block| hooks[event] << block }
    chi.define_singleton_method(:command) { |name, _description, anytime: false, &block| commands[name] = [block, anytime] }
    mod::Plugin.new(settings).register(chi)
    { hooks: hooks, commands: commands }
  end

  def fire(p, type, **event)
    p[:hooks][type].each do |block|
      fired = { type: type, **event }
      ctx.with_event(fired) { block.call(fired, ctx) }
    end
  end

  def turn(p) = fire(p, :before_turn, prompt: "go")

  def tools(p, *names)
    names.each do |name|
      fire(p, :after_tool_call, tool: name, output: "x", steer: ->(text) { (steered << text) && true })
    end
  end

  def checkin(p, args = "") = p[:commands]["/checkin"].first.call(args, ctx)

  it "is an anytime command" do
    expect(plugin[:commands]["/checkin"].last).to be(true)
  end

  describe "mode ask (the default)" do
    it "shows one card at `after` calls, updated in place at every `every` more, with the three actions" do
      p = plugin("after" => 3, "every" => 2)
      turn(p)
      tools(p, "read", "read")
      expect(ctx.cards).to be_empty

      tools(p, "execute")
      tools(p, "read", "grep")

      expect(ctx.cards.size).to eq(2)
      first, second = ctx.cards
      expect(first[:title]).to eq("3 tool calls, no answer yet")
      expect(second[:title]).to eq("5 tool calls, no answer yet")
      expect(second[:id]).to eq(first[:id])
      expect(second[:body]).to match(/\A\d+s in this turn\. Last tools: read, read, execute, read, grep\.\z/)
      expect(second[:actions]).to eq([{ label: "Nudge", command: "/checkin nudge" },
                                      { label: "Keep going", command: "/checkin later" },
                                      { label: "Stop", command: "/checkin stop" }])
      expect(steered).to be_empty
    end

    it "doesn't count ignore_tools (task_wait, task_get, delegate_result by default)" do
      p = plugin("after" => 2)
      turn(p)
      tools(p, "task_wait", "task_get", "delegate_result", "read")
      expect(ctx.cards).to be_empty

      p2 = plugin("after" => 2, "ignore_tools" => ["read"])
      turn(p2)
      tools(p2, "read", "read", "task_wait", "task_wait")
      expect(ctx.cards.size).to eq(1)
    end

    it "replaces the open card with one without actions when the turn ends" do
      p = plugin("after" => 1)
      turn(p)
      tools(p, "read")
      fire(p, :after_turn, status: "completed")

      closed = ctx.cards.last
      expect(closed).to include(id: ctx.cards.first[:id], title: "check-in", body: "The turn ended after 1 tool calls.")
      expect(closed).not_to have_key(:actions)
    end

    it "closes a card a failed turn left open at the next before_turn, and starts counting from zero" do
      p = plugin("after" => 2)
      turn(p)
      tools(p, "read", "read")
      turn(p)

      expect(ctx.cards.last).to include(title: "check-in", body: "The turn ended after 2 tool calls.")
      tools(p, "read")
      expect(ctx.cards.size).to eq(2)
      expect(checkin(p)).to end_with("this turn: 1 tool calls")
    end

    it "shows nothing at the turn's end without a card" do
      p = plugin("after" => 5)
      turn(p)
      tools(p, "read")
      fire(p, :after_turn, status: "completed")
      expect(ctx.cards).to be_empty
    end
  end

  describe "the card's actions" do
    let!(:p) { plugin("after" => 2, "every" => 3).tap { |pl| turn(pl) && tools(pl, "read", "read") } }

    it "Nudge steers the message with the count and closes the card" do
      expect(checkin(p, "nudge")).to be_nil

      expect(ctx.steers).to eq(["You've made 2 tool calls in this turn without answering. Say briefly what you've found " \
                                "so far and what's left, then answer now or continue."])
      expect(ctx.cards.last).to include(title: "check-in", body: "Nudged the model at 2 tool calls.")
    end

    it "Nudge says at the turn's end that the nudge wasn't sent when the answer came first" do
      checkin(p, "nudge")
      fire(p, :after_turn, status: "completed", messages: [{ role: "user", content: "go" }, { role: "model", content: "done" }])

      expect(ctx.cards.last).to include(id: ctx.cards.first[:id], title: "check-in", body: "The answer came first; nudge not sent.")
    end

    it "Nudge keeps its card when the steer joined the turn" do
      checkin(p, "nudge")
      steer = { role: "user", kind: "steer", source: "check-in", content: ctx.steers.last }
      fire(p, :after_turn, status: "completed", messages: [{ role: "user", content: "go" }, steer, { role: "model", content: "done" }])

      expect(ctx.cards.last[:body]).to eq("Nudged the model at 2 tool calls.")
    end

    it "Nudge says the turn ended first when it was stopped before the nudge joined" do
      checkin(p, "nudge")
      fire(p, :after_turn, status: "canceled", messages: [{ role: "user", content: "go" }])

      expect(ctx.cards.last[:body]).to eq("The turn ended first; nudge not sent.")
    end

    it "Keep going closes the card and names the next check-in; the card comes back there" do
      expect(checkin(p, "later")).to be_nil
      expect(ctx.cards.last[:body]).to eq("Kept going; the next check-in is at 5 tool calls.")
      expect(checkin(p, "later")).to eq("check-in: no check-in open")

      tools(p, "read", "read", "read")
      expect(ctx.cards.last).to include(title: "5 tool calls, no answer yet", id: ctx.cards.first[:id])
    end

    it "Stop stops the turn and closes the card" do
      expect(checkin(p, "stop")).to be_nil
      expect(ctx.stops).to eq(["stopped from check-in"])
      expect(ctx.cards.last[:body]).to eq("Stopped the turn at 2 tool calls.")
    end

    it "with no turn running, Nudge and Stop say so and leave the card" do
      ctx.running = false
      cards = ctx.cards.size

      expect(checkin(p, "nudge")).to eq("check-in: no turn running")
      expect(checkin(p, "stop")).to eq("check-in: no turn running")
      expect(ctx.cards.size).to eq(cards)
    end
  end

  describe "modes nudge and notify" do
    it "nudge steers through the event with a custom message and says so" do
      p = plugin("after" => 2, "mode" => "nudge", "message" => "{calls} calls: status?")
      turn(p)
      tools(p, "read", "read")

      expect(steered).to eq(["2 calls: status?"])
      expect(ctx.notices).to eq([["nudged the model after 2 tool calls", :info]])
      expect(ctx.cards).to be_empty
    end

    it "notify only says so" do
      p = plugin("after" => 1, "every" => 1, "mode" => "notify")
      turn(p)
      tools(p, "read", "read")

      expect(ctx.notices.map(&:first)).to eq(["1 tool calls in this turn, no answer yet", "2 tool calls in this turn, no answer yet"])
      expect(steered).to be_empty
      expect(ctx.cards).to be_empty
    end

    it "nudge says at the turn's end that the nudge wasn't sent when the answer came first" do
      p = plugin("after" => 2, "mode" => "nudge")
      turn(p)
      tools(p, "read", "read")
      fire(p, :after_turn, status: "completed", messages: [{ role: "user", content: "go" }, { role: "model", content: "done" }])

      expect(ctx.notices.last).to eq(["The answer came first; nudge not sent.", :warn])
    end

    it "nudge says nothing at the turn's end when the steer joined the turn" do
      p = plugin("after" => 2, "mode" => "nudge")
      turn(p)
      tools(p, "read", "read")
      steer = { role: "user", kind: "steer", source: "check-in", content: steered.last }
      fire(p, :after_turn, status: "completed", messages: [{ role: "user", content: "go" }, steer, { role: "model", content: "done" }])

      expect(ctx.notices.map(&:first)).to eq(["nudged the model after 2 tool calls"])
    end

    it "nudge says nothing at the turn's end when a user line was merged after the steer" do
      p = plugin("after" => 2, "mode" => "nudge")
      turn(p)
      tools(p, "read", "read")
      steer = { role: "user", kind: "steer", source: "check-in", content: steered.last }
      merged = { role: "user", kind: "input", content: "also this" }
      fire(p, :after_turn, status: "completed",
                           messages: [{ role: "user", content: "go" }, steer, merged, { role: "model", content: "done" }])

      expect(ctx.notices.map(&:first)).to eq(["nudged the model after 2 tool calls"])
    end
  end

  describe "/checkin" do
    let(:p) { plugin }

    it "reports its state, and changes it for this session" do
      expect(checkin(p)).to eq("check-in is on: mode ask, after 50 tool calls, then every 50; this turn: 0 tool calls")
      expect(checkin(p, "off")).to eq("check-in is off for this session")
      expect(checkin(p, "mode nudge")).to eq("check-in mode is nudge for this session")
      expect(checkin(p, "mode loud")).to eq("check-in: unknown mode loud (ask, nudge or notify)")
      expect(checkin(p, "30")).to eq("check-in after 30 tool calls, then every 30, for this session")
      expect(checkin(p, "0")).to eq("check-in: the threshold must be at least 1")
      expect(checkin(p)).to eq("check-in is off: mode nudge, after 30 tool calls, then every 30; this turn: 0 tool calls")
      expect(checkin(p, "what")).to start_with("usage: /checkin")
    end

    it "keeps the session's changes across a restart (a new plugin), and only that session's" do
      checkin(p, "off")
      checkin(p, "mode nudge")
      checkin(p, "30")
      restarted = plugin
      expect(checkin(restarted)).to eq("check-in is off: mode nudge, after 30 tool calls, then every 30; this turn: 0 tool calls")

      ctx.session_id = "s2"
      expect(checkin(restarted)).to eq("check-in is on: mode ask, after 50 tool calls, then every 50; this turn: 0 tool calls")
      turn(restarted)
      ctx.session_id = "s1"
      turn(restarted)
      expect(checkin(restarted)).to start_with("check-in is off: mode nudge, after 30 tool calls")
      expect(Dir.children(File.join(ctx.data_dir, "sessions"))).to eq(["s1.json"])
    end

    it "a restored threshold counts from the session's next turn" do
      checkin(p, "2")
      restarted = plugin
      turn(restarted)
      tools(restarted, "a", "b")
      expect(ctx.cards.last[:title]).to eq("2 tool calls, no answer yet")
    end

    it "off stops the check-ins; on brings them back" do
      checkin(p, "3")
      checkin(p, "off")
      turn(p)
      tools(p, "a", "b", "c")
      expect(ctx.cards).to be_empty

      checkin(p, "on")
      tools(p, "d")
      expect(ctx.cards.size).to eq(1)
    end

    it "a threshold a running turn is already past checks in that many calls from now" do
      turn(p)
      tools(p, *Array.new(10, "read"))
      checkin(p, "4")

      tools(p, "a", "b", "c")
      expect(ctx.cards).to be_empty
      tools(p, "d")
      expect(ctx.cards.last[:title]).to eq("14 tool calls, no answer yet")
    end
  end
end

RSpec.describe "The check-in bundle, installed" do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/check-in", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("check-in-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:state_dir) { File.join(tmpdir, "sessions") }
  let(:client) { test_client }
  let(:settings) { { "after" => 2, "every" => 10 } }
  let(:engine) { Samagotchi::Engine.new(client: client).tap { |e| e.session_state_dir = state_dir } }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir) }
  let(:commands) do
    Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                    default_model: "Gemma-4B-it", registry: engine.command_registry)
  end
  let(:events) { [] }
  let(:tool_call) { %(<|tool_call>call:execute{command: "true"}<tool_call|>) }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME", "SAMAGOTCHI_THINKING_LEVEL")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME SAMAGOTCHI_THINKING_LEVEL].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  before do
    FileUtils.mkdir_p(system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow_any_instance_of(Samagotchi::ExtensionLoad).to receive(:bundle_settings).and_return("check-in" => settings)
    @installer = Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "check-in", scope: "system", strict: true)
    @installer.run
    engine.session = session
    engine.subscribe(observer: ->(e) { events << e })
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def cards = events.select { |e| e[:type] == :card }

  it "installs cleanly, with no memory, as an anytime command" do
    expect(@installer.warnings).to be_empty
    entry = engine.command_registry.lookup("/checkin nudge")
    expect([entry.name, entry.anytime, entry.source]).to eq(["/checkin", true, "check-in"])
    index = File.join(system_dir, "index.md")
    expect(File.exist?(index) ? File.read(index) : "").not_to include("check-in")
  end

  it "asks with a card mid-turn; its Nudge puts the message into the turn, and the card closes at the end" do
    replies = [tool_call, tool_call, tool_call, "found it"]
    nudged = nil
    allow(client).to receive(:complete) do
      # The user presses Nudge once the card is up (an anytime command).
      nudged ||= engine.running_anytime { commands.run("/checkin nudge") } if cards.any?
      replies.shift || "found it"
    end

    engine.run_turn(session, "look around")

    expect(cards.first).to include(title: "2 tool calls, no answer yet", source: "check-in", in_turn: true)
    expect(session.messages).to include(role: "user", kind: "steer", source: "check-in",
                                        content: a_string_starting_with("You've made 2 tool calls in this turn"))
    steer_at = session.messages.index { |m| m[:kind] == "steer" }
    expect(session.messages[(steer_at + 1)..].map { |m| m[:role] }).to include("model")
    expect(events.find { |e| e[:type] == :pending_input_merged && e[:steers] })
      .to include(count: 0, steers: [{ source: "check-in", text: a_string_starting_with("You've made 2") }])
    expect(cards.last).to include(id: cards.first[:id], title: "check-in", body: "Nudged the model at 2 tool calls.")
  end

  it "says the nudge wasn't sent when the model answered before the nudge could join" do
    replies = [tool_call, tool_call, "found it"]
    allow(client).to receive(:complete) do
      # Nudge pressed while the model writes its final answer.
      engine.running_anytime { commands.run("/checkin nudge") } if cards.any? && replies.size == 1
      replies.shift || "found it"
    end

    engine.run_turn(session, "look around")

    expect(session.messages.none? { |m| m[:kind] == "steer" }).to be(true)
    expect(cards.map { |c| c[:body] }).to include("Nudged the model at 2 tool calls.")
    expect(cards.last).to include(id: cards.first[:id], title: "check-in", body: "The answer came first; nudge not sent.")
  end

  context "in nudge mode" do
    let(:settings) { { "after" => 2, "mode" => "nudge", "message" => "{calls} calls so far: answer now." } }

    it "nudges by itself; a --non-interactive turn (no caller drain) gets it too" do
      replies = [tool_call, tool_call, "answered"]
      allow(client).to receive(:complete) { replies.shift || "answered" }

      engine.run_turn(session, "go", pending_input: nil)

      expect(session.messages).to include(role: "user", kind: "steer", source: "check-in", content: "2 calls so far: answer now.")
      expect(events.find { |e| e[:type] == :hook_notice }).to include(text: "nudged the model after 2 tool calls")
    end
  end
end
