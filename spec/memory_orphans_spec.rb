# frozen_string_literal: true

require "samagotchi/memory_orphans"
require "samagotchi/engine"
require "samagotchi/session"
require "support/test_kernel"
require "digest"
require "fileutils"
require "tmpdir"

RSpec.describe Samagotchi::MemoryOrphans do
  let(:tmp) { File.realpath(Dir.mktmpdir) }
  let(:env) { { "XDG_CONFIG_HOME" => File.join(tmp, "xdg") } }
  let(:projects) { File.join(tmp, "xdg", "samagotchi", "memories", "projects") }

  after { FileUtils.rm_rf(tmp) }

  # A git checkout named +name+ (a .git dir is all MemoryPaths reads).
  def repo(name)
    root = File.join(tmp, "src", name)
    FileUtils.mkdir_p(File.join(root, ".git"))
    root
  end

  def key(root) = "#{File.basename(root)}_#{Digest::MD5.hexdigest(root)[0..7]}"

  def folder(name, memory: "notes.md")
    dir = File.join(projects, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, memory), "x") if memory
    dir
  end

  describe ".find" do
    it "is nil with no folder of the project's name" do
      root = repo("app")
      folder("other_0123abcd")
      expect(described_class.find(env: env, cwd: root)).to be_nil
    end

    it "is nil when the projects dir doesn't exist" do
      expect(described_class.find(env: env, cwd: repo("app"))).to be_nil
    end

    it "names one candidate when the computed folder is missing" do
      root = repo("app")
      orphan = folder("app_0123abcd")
      expect(described_class.find(env: env, cwd: root))
        .to eq(described_class::Found.new(computed: File.join(projects, key(root)), candidates: [orphan], computed_exists: false))
    end

    it "names several, sorted" do
      root = repo("app")
      second = folder("app_ffff0000")
      first = folder("app_0123abcd")
      folder("app_notahash")
      expect(described_class.find(env: env, cwd: root).candidates).to eq([first, second])
    end

    it "is nil once the computed folder holds a memory" do
      root = repo("app")
      folder("app_0123abcd")
      folder(key(root))
      expect(described_class.find(env: env, cwd: root)).to be_nil
    end

    it "still warns when the computed folder exists with no *.md in it" do
      root = repo("app")
      orphan = folder("app_0123abcd")
      folder(key(root), memory: nil)
      found = described_class.find(env: env, cwd: root)
      expect([found.candidates, found.computed_exists]).to eq([[orphan], true])
    end

    it "is nil outside a git repository" do
      cwd = File.join(tmp, "plain", "app")
      FileUtils.mkdir_p(cwd)
      folder("app_0123abcd")
      expect(described_class.find(env: env, cwd: cwd)).to be_nil
    end

    it "matches a basename with _ in it whole, not a shorter prefix" do
      root = repo("my_app")
      orphan = folder("my_app_0123abcd")
      folder("my_0123abcd")
      expect(described_class.find(env: env, cwd: root).candidates).to eq([orphan])
    end
  end

  describe ".message" do
    it "names the computed folder, the candidate, the mv and the caveat" do
      root = repo("app")
      orphan = folder("app_0123abcd")
      computed = File.join(projects, key(root))
      text = described_class.message(env: env, cwd: root)
      expect(text).to start_with("no project memories in #{computed}, but #{orphan} ")
      expect(text).to include("`mv #{orphan} #{computed}`", "can't prove")
    end

    it "says to move the files when the computed folder exists" do
      root = repo("app")
      orphan = folder("app_0123abcd")
      computed = folder(key(root), memory: nil)
      expect(described_class.message(env: env, cwd: root)).to include("move its files into #{computed}")
                                                              .and include("`mv #{orphan}/* #{computed}/`")
    end

    it "lists several candidates" do
      root = repo("app")
      a = folder("app_0123abcd")
      b = folder("app_ffff0000")
      expect(described_class.message(env: env, cwd: root)).to include("#{a}, #{b}", "`mv <that folder> ")
    end

    it "is nil with nothing orphaned" do
      expect(described_class.message(env: env, cwd: repo("app"))).to be_nil
    end
  end

  describe "the session-start warning (Engine)" do
    around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

    let(:client) { test_client }
    let(:kernel) { test_kernel(client: client) }
    let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel, profile: "gemma4") }

    it "is announced once per Engine, label memory" do
      allow(described_class).to receive(:message).and_return("no project memories in /x, but /y …")
      events = []
      engine.subscribe(observer: ->(e) { events << e })

      engine.announce_load_events!
      engine.announce_load_events!

      warnings = events.select { |e| e[:type] == :guardrail_warning }
      expect(warnings.map { |e| e.slice(:label, :message) }).to eq([{ label: "memory", message: "no project memories in /x, but /y …" }])
    end

    it "goes to the first turn's events without the load announcement (--non-interactive)" do
      allow(described_class).to receive(:message).and_return("no project memories in /x")
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(kernel).to receive(:run).and_return(
        Samagotchi::LLM::ModelResult.new(text: "ok", conversation: [], exhausted: false, pending_tool_calls: false, tool_activity: [])
      )
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
      allow(session).to receive(:save)
      events = []

      engine.run_turn(session, "hi", on_event: ->(e) { events << e })
      engine.run_turn(session, "again", on_event: ->(e) { events << e })

      warnings = events.select { |e| e[:type] == :guardrail_warning }
      expect(warnings.map { |e| e.slice(:label, :message) }).to eq([{ label: "memory", message: "no project memories in /x" }])
    end

    it "says nothing with no orphan" do
      allow(described_class).to receive(:message).and_return(nil)
      events = []
      engine.subscribe(observer: ->(e) { events << e })

      engine.announce_load_events!

      expect(events.select { |e| e[:type] == :guardrail_warning }).to be_empty
    end
  end
end
