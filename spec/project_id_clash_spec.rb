# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "samagotchi/project_id_clash"
require "samagotchi/engine"
require "support/test_kernel"

RSpec.describe Samagotchi::ProjectIdClash do
  let(:tmp) { File.realpath(Dir.mktmpdir("id-clash")) }
  let(:home) { File.join(tmp, "home") }
  let(:env) { { "XDG_CONFIG_HOME" => File.join(tmp, "xdg") } }
  let(:id) { "notes-0a1b2c3d" }
  let(:memories) { File.join(tmp, "xdg", "samagotchi", "memories", "projects", id) }
  let(:claim) { File.join(memories, ".root") }

  after { FileUtils.rm_rf(tmp) }

  def marked(name, marker_id = id)
    dir = File.join(tmp, name)
    FileUtils.mkdir_p(File.join(dir, ".chi"))
    File.write(File.join(dir, Samagotchi::MemoryPaths::MARKER), "# chi project marker\nid: #{marker_id}\n")
    dir
  end

  def check(cwd) = described_class.check(env: env, cwd: cwd, home: home)

  it "claims the id folder for this root at session start, only once the folder exists" do
    notes = marked("notes")
    expect(check(notes)).to be_nil
    expect(File.exist?(memories)).to be(false)

    FileUtils.mkdir_p(memories)
    expect(check(File.join(notes))).to be_nil
    expect(File.read(claim)).to eq("#{notes}\n")
    mtime = File.mtime(claim)
    expect(check(notes)).to be_nil
    expect(File.mtime(claim)).to eq(mtime)
  end

  it "tells a copy it shares the original's id, every session start, keeping the original's claim" do
    notes = marked("notes")
    FileUtils.mkdir_p(memories)
    check(notes)
    copy = File.join(tmp, "copy")
    FileUtils.cp_r(notes, copy)

    clash = check(copy)
    expect(clash).to eq(described_class.new(root: copy, other: notes, id: id))
    expect(clash.message).to eq("#{copy} and #{notes} share chi project id #{id} (a copied folder?): they share " \
                                "memories; `chi project init --new-id` gives this one its own.")
    expect(check(copy)).to eq(clash)
    expect(check(notes)).to be_nil
    expect(File.read(claim)).to eq("#{notes}\n")
  end

  it "takes the claim over without a word after a move, or when the other folder has another id now" do
    notes = marked("notes")
    FileUtils.mkdir_p(memories)
    check(notes)
    moved = File.join(tmp, "moved")
    File.rename(notes, moved)

    expect(check(moved)).to be_nil
    expect(File.read(claim)).to eq("#{moved}\n")

    copy = File.join(tmp, "copy")
    FileUtils.cp_r(moved, copy)
    File.write(File.join(moved, Samagotchi::MemoryPaths::MARKER), "id: notes-99999999\n")
    expect(check(copy)).to be_nil
    expect(File.read(claim)).to eq("#{copy}\n")
  end

  it "has nothing to say for a project keyed by its path" do
    notes = File.join(tmp, "plain").tap { |dir| FileUtils.mkdir_p(File.join(dir, ".chi")) }
    File.write(File.join(notes, Samagotchi::MemoryPaths::MARKER), "")

    expect(check(notes)).to be_nil
  end

  describe "the session-start warning (Engine)" do
    around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

    let(:client) { test_client }
    let(:kernel) { test_kernel(client: client) }
    let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel, profile: "gemma4") }

    it "is announced once per Engine, label memory" do
      clash = described_class.new(root: "/a/copy", other: "/a/notes", id: id)
      allow(described_class).to receive(:check).and_return(clash)
      allow(Samagotchi::MemoryOrphans).to receive(:message).and_return(nil)
      events = []
      engine.subscribe(observer: ->(e) { events << e })

      engine.announce_load_events!
      engine.announce_load_events!

      warnings = events.select { |e| e[:type] == :guardrail_warning }
      expect(warnings.map { |e| e.slice(:label, :message) }).to eq([{ label: "memory", message: clash.message }])
    end

    it "goes to the first turn's events without the load announcement (--non-interactive)" do
      clash = described_class.new(root: "/a/copy", other: "/a/notes", id: id)
      allow(described_class).to receive(:check).and_return(clash)
      allow(Samagotchi::MemoryOrphans).to receive(:message).and_return(nil)
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(kernel).to receive(:run).and_return(
        Samagotchi::LLM::ModelResult.new(text: "ok", conversation: [], exhausted: false, pending_tool_calls: false,
                                         tool_activity: [])
      )
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
      allow(session).to receive(:save)
      events = []

      engine.run_turn(session, "hi", on_event: ->(e) { events << e })
      engine.run_turn(session, "again", on_event: ->(e) { events << e })

      warnings = events.select { |e| e[:type] == :guardrail_warning }
      expect(warnings.map { |e| e.slice(:label, :message) }).to eq([{ label: "memory", message: clash.message }])
    end
  end
end
