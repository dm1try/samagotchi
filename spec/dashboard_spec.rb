# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "securerandom"
require "samagotchi/dashboard"
require "samagotchi/session_manager"

RSpec.describe Samagotchi::Dashboard do
  # A fake manager + session so specs never fork a process. The dashboard only
  # needs a duck-typed object responding to list_sessions / spawn_session.
  FakeSession = Struct.new(:id, :status, :last_prompt)

  class FakeManager
    attr_reader :spawned

    def initialize(sessions:)
      @sessions = sessions
      @spawned = []
    end

    def list_sessions
      @sessions
    end

    def spawn_session(prompt:)
      @spawned << prompt
      # Simulate the new session appearing in the refreshed list.
      FakeSession.new("spawned-#{@spawned.size}", "running", prompt)
    end
  end

  # Build a dashboard with a fake manager and a scripted input sequence (ending
  # with nil for EOF), run the loop, and capture everything it prints. Records
  # attach routing.
  def with_dashboard(sessions:, script:)
    manager = FakeManager.new(sessions: sessions)
    dashboard = described_class.new(manager: manager)
    attached = []

    output = +""
    original_stdout = $stdout
    $stdout = StringIO.new(output)
    allow(dashboard).to receive(:read_input).and_return(*script)
    allow(dashboard).to receive(:attach_to) { |id| attached << id }

    dashboard.run

    yield manager, output, attached
  ensure
    $stdout = original_stdout
  end

  def session(id:, status:, last_prompt: "")
    FakeSession.new(id, status, last_prompt)
  end

  describe "#run" do
    it "renders the banner and a numbered list, with short ids and status labels" do
      a = session(id: "a1b2c3d4-1111-4222-8333-111111111111", status: "running", last_prompt: "hello there")
      b = session(id: "b2c3d4e5-2222-4333-9444-222222222222", status: "idle", last_prompt: "")

      with_dashboard(sessions: [a, b], script: [nil]) do |_mgr, output, _attached|
        expect(output).to include("Chi Dashboard")
        expect(output).to include("a1b2c3d4")
        expect(output).to include("b2c3d4e5")
        expect(output).to include("running")
        expect(output).to include("idle")
      end
    end

    it "shows a '—' placeholder for an empty last_prompt" do
      s = session(id: "c3d4e5f6-3333-4444-a555-333333333333", status: "completed", last_prompt: "")

      with_dashboard(sessions: [s], script: [nil]) do |_mgr, output, _attached|
        expect(output).to include("—")
      end
    end

    it "caps a long last_prompt preview with an ellipsis" do
      long = "x" * 200
      s = session(id: "dddd-4444", status: "idle", last_prompt: long)

      with_dashboard(sessions: [s], script: [nil]) do |_mgr, output, _attached|
        expect(output).to include("#{long[0, 40]}…")
        expect(output).not_to include(long)
      end
    end

    it "renders the help hint with no sessions (empty list), no session rows" do
      with_dashboard(sessions: [], script: [nil]) do |_mgr, output, _attached|
        expect(output).to include("Chi Dashboard")
        expect(output).to include(/no sessions/i)
        expect(output).not_to include("—")
      end
    end

    it "spawns a session from a text line, prints its id, and refreshes the list" do
      with_dashboard(sessions: [], script: ["hello there, start a session", nil]) do |_mgr, output, _attached|
        expect(output).to match(/Started session/)
        expect(output).to include("spawned-1")
      end
    end

    it "spawns with exactly the typed prompt" do
      with_dashboard(sessions: [], script: ["hello there, start a session", nil]) do |mgr, _output, _attached|
        expect(mgr.spawned).to eq(["hello there, start a session"])
      end
    end

    it "ends the loop on /quit and never spawns" do
      with_dashboard(sessions: [], script: ["/quit", nil]) do |_mgr, output, _attached|
        expect(output).to include("Chi Dashboard")
        expect(output).not_to match(/Started session/)
      end
    end

    it "ends the loop on /QUIT (uppercase) the same way, without spawning" do
      with_dashboard(sessions: [], script: ["/QUIT", nil]) do |_mgr, output, _attached|
        expect(output).not_to match(/Started session/)
      end
    end

    it "ends the loop on EOF (nil input) cleanly, without spawning" do
      with_dashboard(sessions: [], script: [nil]) do |_mgr, output, _attached|
        expect(output).not_to match(/Started session/)
      end
    end

    it "routes a numeric line to attach_to with the correct session id" do
      one = session(id: "id-one", status: "running", last_prompt: "one")
      two = session(id: "id-two", status: "idle", last_prompt: "two")
      three = session(id: "id-three", status: "completed", last_prompt: "three")

      with_dashboard(sessions: [one, two, three], script: ["2", nil]) do |_mgr, _output, attached|
        expect(attached).to eq(["id-two"])
      end
    end

    it "prints an out-of-range error for a number beyond the list and stays in the loop" do
      one = session(id: "id-one", status: "running", last_prompt: "")
      two = session(id: "id-two", status: "idle", last_prompt: "")
      three = session(id: "id-three", status: "completed", last_prompt: "")

      with_dashboard(sessions: [one, two, three], script: ["99", "1", nil]) do |_mgr, output, attached|
        expect(output).to include("No session at #99")
        # After the error, the next line (1) still routes to attach.
        expect(attached).to eq(["id-one"])
      end
    end

    it "treats an empty line as a no-op, then processes the next line" do
      with_dashboard(sessions: [], script: ["", "spawn me", nil]) do |_mgr, output, attached|
        expect(output).not_to match(/Started session 0/)
        expect(attached).to be_empty
      end
    end
  end

  describe "defaults" do
    it "uses the real SessionManager class when no manager is given" do
      dashboard = described_class.new
      expect(dashboard.instance_variable_get(:@manager)).to be(Samagotchi::SessionManager)
      expect(Samagotchi::SessionManager).to respond_to(:list_sessions)
      expect(Samagotchi::SessionManager).to respond_to(:spawn_session)
    end
  end
end
