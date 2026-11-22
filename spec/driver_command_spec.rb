# frozen_string_literal: true

require "tmpdir"
require "samagotchi/driver_command"
require "samagotchi/session_manager"
require "samagotchi/parent_report"
require "samagotchi/visitor"
require "support/session_manager_spawn"

RSpec.describe Samagotchi::DriverCommand do
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd) }
  let(:saved) { [] }
  let(:command) { described_class.new(engine: Struct.new(:session).new(session), save: ->(s) { saved << s.driver }) }

  it "shows the driver, names one or none from a user at a UI, and saves it" do
    expect(command.run("", user_ui: false)).to match([start_with("driver: none"), false, :ok])
    expect(command.run(" Claude", user_ui: true)).to match([start_with("driver: agent claude"), true, :ok])
    expect(session.driver).to eq("agent:claude")
    expect(command.run("claude", user_ui: true)).to match([end_with("(no change)"), false, :ok])
    expect(command.run("none", user_ui: true)).to match([start_with("driver: none"), true, :ok])
    expect(saved).to eq(["agent:claude", nil])
  end

  it "refuses chi send's and an agent's (no user at a UI), and a word that is no name" do
    expect(command.run("claude", user_ui: false)).to eq([described_class::REFUSED, false, :error])
    expect(command.run("two words", user_ui: true)).to eq([described_class::USAGE, false, :error])
    expect(command.run("x]", user_ui: true)).to eq([described_class::USAGE, false, :error])
    expect(session.driver).to be_nil
  end
end

RSpec.describe "Visitor" do
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd) }

  it "is an agent that doesn't drive the session; the driver is not one, nor any other sender" do
    session.driver = "agent:claude"
    expect([Samagotchi::Visitor.of?("agent:codex", session), Samagotchi::Visitor.of?("agent:claude", session)]).to eq([true, false])
    expect([Samagotchi::Visitor.driver?("agent:claude", session), Samagotchi::Visitor.driver?("cli:send", session)]).to eq([true, false])
    expect(%w[cli:send web:ab delegate:1234abcd].map { |id| Samagotchi::Visitor.of?(id, session) }).to all(be(false))
    session.driver = nil
    expect(Samagotchi::Visitor.of?("agent:claude", session)).to be(true)
  end

  it "has its refusal's sentence in ParentReport (a --wait prints it, not 'the turn was canceled')" do
    result = Samagotchi::ReplyWait::Result.new(status: :no_reply, outcome: "canceled", cancel_reason: Samagotchi::Visitor::CAP_REASON)
    expect(Samagotchi::ParentReport.refused?(result)).to be(true)
    expect(Samagotchi::ParentReport.no_reply_line(result))
      .to eq("the turn was refused (session.max_wakes turns ran in a row with no message from this session's owner; " \
             "it runs again after their next message); no turn ran for it")
  end
end

RSpec.describe Samagotchi::SessionManager, "spawn_session's driver" do
  include SpecSessionManagerSpawn

  let(:tmpdir) { Dir.mktmpdir("driver-spawn") }

  before { allow(Process).to receive(:spawn).and_return(12_345) }
  after { FileUtils.rm_rf(tmpdir) }

  def spawned(**options)
    session = spawn_session_for_spec(working_directory: tmpdir, model_name: "Gemma-4B-it", state_dir: tmpdir, **options)
    Samagotchi::Session.load(session.id, state_dir: tmpdir)
  end

  it "is its creator when an agent, with a prompt or idle; a person's, a delegate's or a plugin's has none" do
    expect(spawned(prompt: "go", client_id: "agent:claude").driver).to eq("agent:claude")
    expect(spawned(prompt: nil, client_id: "agent:claude").driver).to eq("agent:claude")
    expect(spawned(prompt: "go", client_id: "cli:send").driver).to be_nil
    expect(spawned(prompt: "go", client_id: "delegate:1234abcd").driver).to be_nil
    expect(spawned(prompt: "go", client_id: Samagotchi::ClientId::PLUGIN).driver).to be_nil
  end

  it "is the one named (chi send --new --driver), over its creator" do
    expect(spawned(prompt: "go", client_id: "cli:send", driver: "agent:claude").driver).to eq("agent:claude")
    expect(spawned(prompt: "go", client_id: "agent:codex", driver: "agent:claude").driver).to eq("agent:claude")
  end
end
