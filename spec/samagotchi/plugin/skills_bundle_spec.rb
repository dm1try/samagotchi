# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/session_commands"
require "samagotchi/turn_flow"
require "samagotchi/memory_bundle/installer"
require "samagotchi/guardrails"
require "support/test_kernel"

# The shipped skills bundle (lib/samagotchi/bundles/skills) installed as a user
# would and loaded by an Engine (its plugin alone: lib/samagotchi/bundles/skills/spec/).
RSpec.describe "The skills bundle, installed" do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/skills", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("skills-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:state_dir) { File.join(tmpdir, "sessions") }
  let(:client) { test_client }
  let(:engine) { Samagotchi::Engine.new(client: client).tap { |e| e.session_state_dir = state_dir } }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir) }
  let(:events) { [] }

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
    @installer = Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "skills", scope: "system", strict: true)
    @installer.run
    engine.session = session
    engine.subscribe(observer: ->(e) { events << e })
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def tool_call(name, **args)
    body = args.map { |key, value| %(#{key}: <|"|>#{value}<|"|>) }.join(", ")
    %(<|tool_call>call:#{name}{#{body}}<tool_call|>)
  end

  def notices = events.select { |e| e[:type] == :hook_notice }.map { |e| e[:text] }

  it "keeps the old version and shows the change when the model rewrites a skill in a real turn" do
    replies = [tool_call("memory_write", name: "skill_release", scope: "system", content: "# Skill: release\n1. check\n",
                         description: "Release this repo"),
               tool_call("memory_write", name: "skill_release", scope: "system", content: "# Skill: release\n1. verify\n"),
               "done"]
    allow(client).to receive(:complete) { replies.shift || "done" }

    engine.run_turn(session, "save it, then fix it")

    expect(File.read(File.join(system_dir, "skill_release.md"))).to eq("# Skill: release\n1. verify\n")
    expect(notices).to eq(["skill release saved (system, 2 lines)",
                           "skill release updated (+1 −1): 1. verify · /skill diff release"])
    kept = Dir.glob(File.join(tmpdir, "state", "samagotchi", "plugins", "skills", "history", "system", "release", "*.md"))
    expect(kept.map { |f| File.read(f) }).to eq(["# Skill: release\n1. check\n"])
  end

  it "nudges the model when a step of a skill it read fails in a real turn" do
    File.write(File.join(system_dir, "skill_release.md"), "# Skill: release\n1. Run `false`; stop if it fails.\n")
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_call_original
    replies = [tool_call("memory_read", name: "skill_release"), tool_call("execute", command: "false"), "skipped it"]
    allow(client).to receive(:complete) { replies.shift || "done" }

    engine.run_turn(session, "release please")

    expect(session.messages).to include(role: "user", kind: "steer", source: "skills",
                                        content: a_string_starting_with("A step of skill release failed."))
    expect(notices).to eq(["skill release was followed, a step failed, the skill wasn't updated"])
  end

  it "doesn't nudge when a step of a skill it read is a grep that found nothing" do
    File.write(File.join(system_dir, "skill_release.md"), "# Skill: release\n1. Check `grep zzz /dev/null` finds nothing.\n")
    replies = [tool_call("memory_read", name: "skill_release"), tool_call("execute", command: "grep zzz_nothing /dev/null"),
               "nothing there"]
    allow(client).to receive(:complete) { replies.shift || "done" }

    engine.run_turn(session, "release please")

    expect(session.messages).not_to include(a_hash_including(kind: "steer", source: "skills"))
    expect(notices).to eq([])
  end

  it "installs cleanly, with no memory, as an anytime command" do
    expect(@installer.warnings).to be_empty
    entry = engine.command_registry.lookup("/skill list")
    expect([entry.name, entry.anytime, entry.source]).to eq(["/skill", true, "skills"])
    index = File.join(system_dir, "index.md")
    expect(File.exist?(index) ? File.read(index) : "").not_to include("skills")
  end
end
