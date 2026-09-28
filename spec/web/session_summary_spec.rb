# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

require "samagotchi/web/session_summary"
require "samagotchi/session"

# The session card's fields, built the same way for GET /api/sessions, the
# session view and the session hub: from the saved session and its owner.
RSpec.describe Samagotchi::Web::SessionSummary do
  let(:state_dir) { Dir.mktmpdir("session-summary-spec") }

  after { FileUtils.rm_rf(state_dir) }

  def session(status: "idle", working_directory: "/tmp/proj")
    Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: working_directory).tap do |s|
      s.status = status
    end
  end

  def session_dir(s)
    Samagotchi::Session.session_dir(s.id, state_dir: state_dir)
  end

  describe "the notification fields" do
    it "reduces the pending question to its id and kind, and passes last_turn through" do
      s = session
      s.pending_question = { id: "q1", question: "Which?", header: "Pick" }
      s.last_turn = { "outcome" => "completed", "ended_at" => "t", "seconds" => 11.0, "origin" => "client" }

      json = described_class.build(s, owner: nil, session_dir: session_dir(s))

      expect(json[:pending_question]).to eq(id: "q1", kind: "question")
      expect(json[:last_turn]).to eq(s.last_turn)
      s.pending_question = { id: "q2", kind: "approval" }
      expect(described_class.build(s, owner: nil, session_dir: session_dir(s))[:pending_question]).to eq(id: "q2", kind: "approval")
    end

    it "is nil for a session with neither" do
      s = session
      expect(described_class.build(s, owner: nil, session_dir: session_dir(s))).to include(pending_question: nil, last_turn: nil)
    end
  end

  describe ".displayed_status" do
    it "shows a 'running' with no live owner as idle (a worker died mid-turn)" do
      expect(described_class.displayed_status(session(status: "running"), owner: nil)).to eq("idle")
    end

    it "trusts 'running' while an owner holds the session" do
      expect(described_class.displayed_status(session(status: "running"), owner: { "kind" => "worker" })).to eq("running")
    end

    it "leaves every other status alone, owner or not" do
      expect(described_class.displayed_status(session(status: "idle"), owner: nil)).to eq("idle")
      expect(described_class.displayed_status(session(status: "stopped"), owner: { "kind" => "tui" })).to eq("stopped")
    end

    it "takes the live worker's snapshot status over the file" do
      expect(described_class.displayed_status(session(status: "idle"), { "status" => "running" }, owner: { "kind" => "worker" }))
        .to eq("running")
    end
  end

  describe ".build" do
    it "has today's card fields plus project_root and bridge_up" do
      s = session
      s.project_root = "/tmp/proj"
      s.first_preview = "cached preview"
      s.last_prompt = "original prompt"

      json = described_class.build(s, owner: nil, session_dir: session_dir(s))

      expect(json).to include(id: s.id, status: "idle", mode: "assist", model_name: "TestModel",
                              working_directory: "/tmp/proj", short_id: s.id[0, 8], test_run: s.test_run,
                              first_preview: "cached preview", last_prompt: "original prompt", owner: nil,
                              recap: nil, project_root: "/tmp/proj", bridge_up: false)
      expect(json.keys).to include(:created_at, :updated_at, :used_memory_names)
    end

    it "carries the session's --memory and --mute lists" do
      s = session
      s.preloaded_memory_names = ["cli_usage"]
      s.muted_memory_names = ["gh-helper"]

      expect(described_class.build(s, owner: nil, session_dir: session_dir(s)))
        .to include(preloaded_memory_names: ["cli_usage"], muted_memory_names: ["gh-helper"])
      expect(described_class.build(session, owner: nil, session_dir: session_dir(s)))
        .to include(preloaded_memory_names: [], muted_memory_names: [])
    end

    it "carries the parent link of a delegated session" do
      s = session
      expect(described_class.build(s, owner: nil, session_dir: session_dir(s))).to include(parent_id: nil)
      s.parent_id = "parent-1234"
      expect(described_class.build(s, owner: nil, session_dir: session_dir(s))).to include(parent_id: "parent-1234")
    end

    it "applies the owner to the status and names its kind" do
      s = session(status: "running")

      expect(described_class.build(s, owner: nil, session_dir: session_dir(s))).to include(status: "idle", owner: nil)
      expect(described_class.build(s, owner: { "kind" => "tui", "pid" => 1 }, session_dir: session_dir(s)))
        .to include(status: "running", owner: "tui")
    end

    it "takes an explicit status as given (the session view has the worker's snapshot)" do
      s = session(status: "running")

      expect(described_class.build(s, status: "idle", owner: { "kind" => "worker" }, session_dir: session_dir(s)))
        .to include(status: "idle", owner: "worker")
    end

    it "is bridge_up only with a sidecar and a live owner (a sidecar a dead worker left is not up)" do
      s = session
      FileUtils.mkdir_p(session_dir(s))
      File.write(File.join(session_dir(s), "bridge.json"), JSON.generate("port" => 1234))

      expect(described_class.build(s, owner: nil, session_dir: session_dir(s))).to include(bridge_up: false)
      expect(described_class.build(s, owner: { "kind" => "worker" }, session_dir: session_dir(s))).to include(bridge_up: true)
    end

    it "gives the recap's preview from the session folder" do
      s = session
      FileUtils.mkdir_p(session_dir(s))
      File.write(File.join(session_dir(s), "recap.json"), JSON.generate(text: "We fixed the login. Then the tests.", covered: 2))

      expect(described_class.build(s, owner: nil, session_dir: session_dir(s))).to include(recap: "We fixed the login.")
    end

    it "falls back to the working directory's project for a session saved before project_root" do
      s = session(working_directory: File.expand_path("..", __dir__))
      s.project_root = nil
      cache = {}

      json = described_class.build(s, owner: nil, session_dir: session_dir(s), root_cache: cache)

      expect(json[:project_root]).to eq(s.project_root)
      expect(cache).not_to be_empty
    end
  end

  describe ".first_preview_for" do
    it "collapses whitespace and cuts at 80 characters, preferring the cached preview" do
      s = session
      s.first_preview = "  a   b\n c  "
      expect(described_class.first_preview_for(s)).to eq("a b c")

      s.first_preview = nil
      s.last_prompt = "x" * 100
      expect(described_class.first_preview_for(s)).to eq("#{"x" * 80}…")
    end
  end
end
