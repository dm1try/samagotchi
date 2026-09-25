# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/session_delete_command"
require "samagotchi/owner_lock"

RSpec.describe Samagotchi::SessionDeleteCommand do
  let(:tmpdir) { Dir.mktmpdir("session-delete-command") }
  let(:locks) { [] }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(owner: nil, id: nil, prompt: "fix the bug in the parser")
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app").tap do |s|
      s.id = id if id
      s.first_preview = prompt
      s.save(state_dir: tmpdir)
      locks << Samagotchi::OwnerLock.acquire(dir_of(s), kind: owner) if owner
    end
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)

  def gone?(session) = !File.exist?(File.join(tmpdir, "#{session.id}.json")) && !Dir.exist?(dir_of(session))

  def run(*argv)
    described_class.new(argv, stdout: out, stderr: err, state_dir: tmpdir).run
  end

  it "deletes each session by id or prefix, one line each, and exits 0" do
    first = make(id: "aaaa1111-0000")
    second = make(id: "bbbb2222-0000", prompt: "second")
    FileUtils.mkdir_p(File.join(dir_of(first), "notes"))

    expect(run("aaaa", second.id)).to eq(0)

    expect(out.string).to eq("aaaa1111  deleted  fix the bug in the parser\nbbbb2222  deleted  second\n")
    expect(gone?(first) && gone?(second)).to be true
  end

  it "refuses a live worker without --force, deletes the others, and exits 1" do
    live = make(owner: "worker", id: "aaaa1111-0000")
    idle = make(id: "bbbb2222-0000")

    expect(run(live.id, idle.id)).to eq(1)

    expect(out.string).to include("aaaa1111  refused: its worker is running (--force stops it first)")
    expect(out.string).to include("bbbb2222  deleted")
    expect(gone?(live)).to be false
    expect(gone?(idle)).to be true
  end

  it "with --force stops a live worker first" do
    live = make(owner: "worker", id: "aaaa1111-0000")
    allow(Samagotchi::SessionManager).to receive(:stop_session) do
      locks.each(&:release)
      true
    end

    expect(run("--force", "aaaa")).to eq(0)

    expect(out.string).to eq("aaaa1111  deleted (stopped its worker)  fix the bug in the parser\n")
    expect(gone?(live)).to be true
  end

  it "says so when the worker is still shutting down after --force" do
    live = make(owner: "worker", id: "aaaa1111-0000")
    allow(Samagotchi::SessionManager).to receive(:stop_session).and_return(false)

    expect(run(live.id, "-f")).to eq(1)

    expect(out.string).to include("aaaa1111  refused: its worker is still shutting down; try again in a moment")
    expect(gone?(live)).to be false
  end

  it "never deletes a session a chi REPL has open, --force or not" do
    open = make(owner: "tui", id: "aaaa1111-0000")

    expect(run("--force", open.id)).to eq(1)

    expect(out.string).to include("aaaa1111  refused: it is open in a chi REPL; close it there first")
    expect(gone?(open)).to be false
  end

  it "reports an unknown id and an ambiguous prefix on stderr and exits 1" do
    make(id: "aaaa1111-0000")
    make(id: "aaaa2222-0000")

    expect(run("nope", "aaaa")).to eq(1)

    expect(err.string).to include("chi sessions delete: no session nope")
    expect(err.string).to include("session id aaaa matches 2 sessions")
    expect(out.string).to eq("")
  end

  it "exits 2 on usage errors" do
    expect(run).to eq(2)
    expect(err.string).to include("give session ids")
    expect(run("--everything", "x")).to eq(2)
    expect(err.string).to include("unknown option --everything")
  end

  it "prints its usage for --help and exits 0" do
    expect(run("--help")).to eq(0)
    expect(out.string).to include("Usage: chi sessions delete [--force] (ID|PREFIX)...")
  end

  describe "bin/chi sessions delete" do
    let(:chi) { File.expand_path("../bin/chi", __dir__) }
    let(:xdg_state) { Dir.mktmpdir("chi-sessions-delete") }
    let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }

    after { FileUtils.rm_rf(xdg_state) }

    def run_chi(*args)
      Open3.capture3({ "XDG_STATE_HOME" => xdg_state }, RbConfig.ruby, chi, "sessions", *args, stdin_data: "")
    end

    it "keeps the order of the ids given when stdout and stderr share a pipe" do
      a, b = Array.new(2) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap { |s| s.save(state_dir: state_dir) }
      end

      output, _status = Open3.capture2e({ "XDG_STATE_HOME" => xdg_state }, RbConfig.ruby, chi, "sessions", "delete",
                                        a.id[0, 8], "nope1", b.id[0, 8], "nope2", stdin_data: "")

      expect(output.lines.map { |line| line[/deleted|nope\d/] }).to eq(%w[deleted nope1 deleted nope2])
    end

    it "deletes a session and lists delete in the help" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: state_dir)

      out, err, status = run_chi("delete", session.id[0, 8])

      expect(status.exitstatus).to eq(0), err
      expect(out).to start_with("#{session.id[0, 8]}  deleted")
      expect(File.exist?(File.join(state_dir, "#{session.id}.json"))).to be false
      expect(run_chi("--help").first).to include("delete [--force] ID...")
    end

    it "exits 2 with no ids" do
      _out, err, status = run_chi("delete")

      expect(status.exitstatus).to eq(2)
      expect(err).to include("give session ids")
    end
  end
end
