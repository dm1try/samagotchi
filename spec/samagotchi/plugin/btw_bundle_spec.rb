# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/session_commands"
require "samagotchi/session_manager"
require "samagotchi/turn_flow"
require "samagotchi/memory_bundle/installer"

# The shipped btw bundle (lib/samagotchi/bundles/btw): /btw <question> as a
# card, updated in place with the answer; /btw keep <id> forks a child.
RSpec.describe "The btw bundle" do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/btw", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("btw-") }
  let(:system_dir) { File.join(tmpdir, "mem") }
  let(:state_dir) { File.join(tmpdir, "sessions") }
  let(:client) { instance_double(Samagotchi::Client, complete: nil) }
  let(:settings) { {} }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  before do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = File.join(system_dir, ".bundles")
    Samagotchi::MemoryBundle::Installer.system_dir_override = system_dir
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = File.join(tmpdir, "proj")
    FileUtils.mkdir_p(system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow_any_instance_of(Samagotchi::Engine).to receive(:bundle_settings).and_return("btw" => settings)
    allow(Process).to receive(:spawn).and_return(12_345)
    @installer = Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "btw", scope: "system", strict: true)
    @installer.run
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
    FileUtils.rm_rf(tmpdir)
  end

  let(:engine) { Samagotchi::Engine.new(mode: :assist, client: client).tap { |e| e.session_state_dir = state_dir } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
      s.messages = [{ role: "user", content: "rename foo" }, { role: "model", content: "renamed to bar" }]
      s.save(state_dir: state_dir)
    end
  end
  let(:commands) do
    Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                    default_model: "Gemma-4B-it", registry: engine.command_registry)
  end
  let(:cards) { [] }
  let(:asked) { [] }
  let(:answer) { "It was renamed to bar." }

  before do
    engine.session = session
    engine.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
    allow(engine).to receive(:ask_side_model) do |request, **options|
      asked << [request, options]
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  def btw(line) = engine.running_anytime { commands.run(line) }

  it "installs cleanly, as an anytime command" do
    expect(@installer.warnings).to be_empty
    entry = engine.command_registry.lookup("/btw why?")
    expect([entry.name, entry.anytime, entry.source]).to eq(["/btw", true, "btw"])
  end

  it "shows thinking… at once, then the answer in the same card, and changes nothing in the session" do
    before = Marshal.load(Marshal.dump(session.messages))

    expect(btw("/btw what did we rename?").output).to be_nil

    expect(cards.size).to eq(2)
    thinking, done = cards
    expect(thinking).to include(title: "btw: what did we rename?", body: "thinking…", actions: [], anytime: true)
    expect(done[:id]).to eq(thinking[:id])
    expect(done[:body]).to eq("It was renamed to bar.")
    keep_id = thinking[:id].delete_prefix("btw-")
    expect(done[:actions]).to eq([{ label: "Keep as session", command: "/btw keep #{keep_id}" }])
    request, = asked.first
    expect(request.last[:content]).to include("User: rename foo", "Assistant: renamed to bar", "what did we rename?")
    expect(session.messages).to eq(before)
  end

  it "notes a REPL mid-turn question is about the conversation before the turn" do
    allow(engine).to receive(:turn_running?).and_return(true)
    btw("/btw q")
    expect(cards.map { |c| c[:body] }).to all(end_with("(About the conversation before the running turn.)"))
  end

  context "with settings" do
    let(:settings) { { "max_tokens" => 200, "timeout" => "30" } }

    it "passes max_tokens and timeout" do
      btw("/btw q")
      expect(asked.first.last).to include(max_tokens: 200, timeout: 30.0)
    end
  end

  context "when the model fails" do
    let(:answer) { Samagotchi::IdleClient::SummarizeError.new("connection refused") }

    it "says so on the card, with no action" do
      btw("/btw q")
      expect(cards.last).to include(level: :warn, body: "No answer: connection refused", actions: [])
    end
  end

  it "keeps an answer as a child session: the conversation, the question and the answer" do
    btw("/btw what did we rename?")
    keep = cards.last[:actions].first[:command]

    expect(btw(keep).output).to be_nil

    child = Samagotchi::SessionManager.children_of(session.id, state_dir: state_dir).first
    loaded = Samagotchi::Session.load(child[:id], state_dir: state_dir)
    expect(loaded.messages.map { |m| [m[:role], m[:content]] }).to eq(
      [%w[user rename\ foo], ["model", "renamed to bar"], ["user", "what did we rename?"], ["model", "It was renamed to bar."]]
    )
    expect(loaded).to have_attributes(parent_id: session.id, status: "idle", first_preview: "btw: what did we rename?")
    expect(cards[-2]).to include(actions: [], body: "It was renamed to bar.")
    expect(cards.last[:title]).to eq("kept as #{child[:id][0, 8]}")
    expect(btw(keep).output).to eq("btw keep #{keep.split.last}: already kept as session #{child[:id]}")
  end

  it "says expired for an answer it no longer holds, and keeps only the last 10" do
    expect(btw("/btw keep abcd1234").output).to start_with("btw keep abcd1234: expired")

    11.times { |i| btw("/btw q#{i}") }
    first = cards.find { |c| c[:title] == "btw: q0" && c[:actions].any? }[:actions].first[:command]
    second = cards.find { |c| c[:title] == "btw: q1" && c[:actions].any? }[:actions].first[:command]
    expect(btw(first).output).to include("expired")
    expect(btw(second).output).to be_nil
  end

  it "shows a usage line without a question" do
    expect(btw("/btw").output).to start_with("usage: /btw <question>")
  end
end
