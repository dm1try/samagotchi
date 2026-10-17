# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/session_commands"
require "samagotchi/turn_flow"
require "samagotchi/memory_bundle/installer"
require "support/test_kernel"

# The shipped check-in bundle installed as a user would and loaded by an Engine
# that runs real turns (its plugin alone: lib/samagotchi/bundles/check-in/spec/).
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
