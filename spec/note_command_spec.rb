# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/note_command"
require "samagotchi/owner_lock"

RSpec.describe Samagotchi::NoteCommand do
  let(:tmpdir) { Dir.mktmpdir("note-command") }
  let(:locks) { [] }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(owner: nil, status: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app").tap do |s|
      s.last_prompt = "hi"
      s.status = status if status
      s.save(state_dir: tmpdir)
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(s.id, state_dir: tmpdir), kind: owner) if owner
    end
  end

  def run(*argv, stdin: StringIO.new(""))
    described_class.new(argv, stdin: stdin, stdout: out, stderr: err, state_dir: tmpdir).run
  end

  def notes_of(session)
    dir = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), Samagotchi::SessionManager::NOTES_DIR)
    Dir.glob(File.join(dir, "*.json")).map { |path| JSON.parse(File.read(path)) }
  end

  it "queues stdin as a note for each session given by id or prefix, with its source" do
    a = make(owner: "worker")
    b = make(owner: "worker")

    code = run("--source", "slack", a.id[0, 8], b.id, stdin: StringIO.new("deploy frozen\n"))

    expect(code).to eq(0), err.string
    expect(notes_of(a)).to contain_exactly(include("text" => "deploy frozen", "source" => "slack"))
    expect(notes_of(b).size).to eq(1)
    expect(out.string.lines).to eq(["#{a.id[0, 8]}  queued: its worker adds it within a few seconds\n",
                                    "#{b.id[0, 8]}  queued: its worker adds it within a few seconds\n"])
  end

  it "takes the text from -m, and the source defaults to cli" do
    a = make(owner: "worker")

    expect(run("-m", "api moved", a.id)).to eq(0)
    expect(notes_of(a).first).to include("text" => "api moved", "source" => "cli")
  end

  it "says a note for a session with no worker waits for its next start, with the queue count" do
    a = make
    run("-m", "one", a.id)

    run("-m", "two", a.id)

    expect(out.string.lines.last).to eq("#{a.id[0, 8]}  waits for the session's next start (2 notes queued)\n")
  end

  it "refuses a session open in a chi REPL and exits 1, still queueing the others" do
    repl = make(owner: "tui")
    live = make(owner: "worker")

    code = run("-m", "x", repl.id, live.id)

    expect(code).to eq(1)
    expect(notes_of(repl)).to be_empty
    expect(notes_of(live).size).to eq(1)
    expect(out.string).to include("#{repl.id[0, 8]}  refused: it is open in a chi REPL; notes need attached mode")
  end

  it "reports an unknown or ambiguous id and exits 1" do
    live = make(owner: "worker")

    expect(run("-m", "x", "nope", live.id)).to eq(1)
    expect(err.string).to include("nope")
    expect(notes_of(live).size).to eq(1)
  end

  it "--all: every session a worker runs now" do
    a = make(owner: "worker")
    b = make(owner: "worker")
    idle = make
    repl = make(owner: "tui")

    expect(run("--all", "-m", "heads up")).to eq(0)
    expect([a, b].map { |s| notes_of(s).size }).to eq([1, 1])
    expect([idle, repl].map { |s| notes_of(s).size }).to eq([0, 0])
  end

  it "--all with no live session says so and exits 1" do
    make

    expect(run("--all", "-m", "x")).to eq(1)
    expect(err.string).to include("no live sessions")
  end

  describe "without a locale (Finder, launchd: stdin and ARGV aren't UTF-8)" do
    it "keeps non-ASCII text from stdin read as US-ASCII" do
      a = make(owner: "worker")

      expect(run(a.id, stdin: StringIO.new("h\xC3\xA9llo".dup.force_encoding("US-ASCII")))).to eq(0), err.string
      expect(notes_of(a).first["text"]).to eq("héllo")
    end

    it "keeps non-ASCII text from -m given as binary" do
      a = make(owner: "worker")

      expect(run("-m", "héllo".b, a.id)).to eq(0), err.string
      expect(notes_of(a).first["text"]).to eq("héllo")
    end

    it "replaces invalid bytes instead of crashing" do
      a = make(owner: "worker")

      expect(run(a.id, stdin: StringIO.new("bad\xFF\xFE".b))).to eq(0), err.string
      expect(notes_of(a).first["text"]).to eq("bad\uFFFD\uFFFD")
    end
  end

  it "refuses an empty or oversized note before writing any" do
    a = make(owner: "worker")

    expect(run(a.id, stdin: StringIO.new("  \n"))).to eq(1)
    expect(err.string).to include("empty")
    expect(run("-m", "x" * (16 * 1024 + 1), a.id)).to eq(1)
    expect(err.string).to include("16 KiB")
    expect(notes_of(a)).to be_empty
  end

  it "doesn't wait on a terminal: no -m and stdin a TTY is a usage error" do
    a = make(owner: "worker")
    tty = StringIO.new("")
    def tty.tty? = true

    expect(run(a.id, stdin: tty)).to eq(2)
    expect(err.string).to include("Usage: chi note")
  end

  it "asks for targets" do
    expect(run("-m", "x")).to eq(2)
    expect(err.string).to include("Usage: chi note")
  end

  it "prints help" do
    expect(run("--help")).to eq(0)
    expect(out.string).to include("Usage: chi note", "--source NAME", "--all", "chi sessions list --live")
  end

  describe "bin/chi note" do
    let(:chi) { File.expand_path("../bin/chi", __dir__) }

    it "keeps the order of the ids given when stdout and stderr share a pipe" do
      xdg = Dir.mktmpdir("chi-note")
      state_dir = Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg })
      a, b = Array.new(2) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/w").tap { |s| s.save(state_dir: state_dir) }
      end

      output, _status = Open3.capture2e({ "XDG_STATE_HOME" => xdg }, RbConfig.ruby, chi, "note", "-m", "x",
                                        a.id[0, 8], "nope1", b.id[0, 8], "nope2", stdin_data: "")

      expect(output.lines.map { |line| line[/waits|nope\d/] }).to eq(%w[waits nope1 waits nope2])
    ensure
      FileUtils.rm_rf(xdg)
    end

    it "is wired before the main option parser and reads stdin" do
      xdg = Dir.mktmpdir("chi-note")
      state_dir = Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg })
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/w")
      session.save(state_dir: state_dir)

      stdout, stderr, status = Open3.capture3({ "XDG_STATE_HOME" => xdg }, RbConfig.ruby, chi, "note",
                                              "--source", "slack", session.id[0, 6], stdin_data: "from a pipe")

      expect(status.exitstatus).to eq(0), stderr
      expect(stdout).to include("waits for the session's next start (1 note queued)")

      # No locale at all, as an app started from Finder or launchd has it.
      bare = { "XDG_STATE_HOME" => xdg, "HOME" => Dir.home, "PATH" => "#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin" }
      _out, stderr, status = Open3.capture3(bare, RbConfig.ruby, chi, "note", session.id, stdin_data: "h\u00E9llo",
                                            unsetenv_others: true)
      expect(status.exitstatus).to eq(0), stderr
      _out, stderr, status = Open3.capture3(bare, RbConfig.ruby, chi, "note", "-m", "h\u00E9llo", session.id,
                                            stdin_data: "", unsetenv_others: true)
      expect(status.exitstatus).to eq(0), stderr
      expect(stderr).not_to include("warning")
      dir = File.join(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), "notes")
      texts = Dir.glob(File.join(dir, "*.json")).map { |path| JSON.parse(File.read(path))["text"] }
      expect(texts.count("héllo")).to eq(2)
    ensure
      FileUtils.rm_rf(xdg)
    end
  end
end
