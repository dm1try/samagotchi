# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/session_archive_command"
require "samagotchi/owner_lock"

# `chi sessions archive|unarchive ID...` and `chi sessions list --archived`.
RSpec.describe "chi sessions archive" do
  let(:xdg_state) { Dir.mktmpdir("chi-sessions-archive") }
  let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }
  let(:locks) { [] }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(xdg_state)
  end

  # Not test runs, so the list lines don't gain [test] when CI is set.
  def make(prompt, id: nil, owner: nil, parent: nil, scratch: false)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app",
                                    parent_id: parent&.id, scratch: scratch, test_run: false).tap do |s|
      s.id = id if id
      s.last_prompt = prompt
      s.save(state_dir: state_dir)
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(s.id, state_dir: state_dir), kind: owner) if owner
      sleep(0.01) # distinct updated_at
    end
  end

  def archived?(session) = Samagotchi::ArchiveStore.archived?(Samagotchi::Session.session_dir(session.id, state_dir: state_dir))

  def run(action, *argv)
    Samagotchi::SessionArchiveCommand.new(action, argv, stdout: out, stderr: err, state_dir: state_dir).run
  end

  it "archives each session by id or prefix, one line each, delegates with it" do
    parent = make("parent", id: "aaaa1111-0000")
    make("child", parent: parent)
    plain = make("plain", id: "bbbb2222-0000")

    expect(run("archive", "aaaa", plain.id)).to eq(0)

    expect(out.string).to eq("aaaa1111  archived (and 1 delegate)\nbbbb2222  archived\n")
    expect(archived?(parent) && archived?(plain)).to be(true)
  end

  it "refuses a busy session, a REPL's and a scratch one, archives the rest, and exits 1" do
    busy = make("busy", id: "aaaa1111-0000", owner: "worker")
    Samagotchi::Session.mark_running(busy.id, state_dir: state_dir)
    make("open", id: "bbbb2222-0000", owner: "tui")
    make("scratch", id: "cccc3333-0000", scratch: true)
    fine = make("fine", id: "dddd4444-0000")

    expect(run("archive", "aaaa", "bbbb", "cccc", "dddd")).to eq(1)

    expect(out.string).to eq(<<~TEXT)
      aaaa1111  refused: a turn is running; wait for it or cancel it first
      bbbb2222  refused: it is open in a chi REPL; close it there first
      cccc3333  refused: a scratch session is deleted when you leave; nothing to archive
      dddd4444  archived
    TEXT
    expect(archived?(fine)).to be(true)
    expect(archived?(busy)).to be(false)
  end

  it "tells a REPL on a delegate from one on the session itself" do
    parent = make("parent", id: "aaaa1111-0000")
    make("child", parent: parent, owner: "tui")

    expect(run("archive", "aaaa")).to eq(1)
    expect(out.string).to eq("aaaa1111  refused: a delegate of it is open in a chi REPL; close it there first\n")
  end

  it "unarchives, says so for one that isn't archived, and names an unknown id" do
    session = make("back", id: "aaaa1111-0000")
    Samagotchi::ArchiveStore.archive(session.id, state_dir: state_dir)

    expect(run("unarchive", "aaaa", "aaaa1111-0000", "nope")).to eq(1)

    expect(out.string).to eq("aaaa1111  unarchived\naaaa1111  not archived\n")
    expect(err.string).to include("chi sessions unarchive: no session nope")
    expect(archived?(session)).to be(false)
  end

  it "prints its usage for no ids" do
    expect(run("archive")).to eq(2)
    expect(err.string).to include("Usage: chi sessions archive (ID|PREFIX)...")
  end

  describe "bin/chi" do
    let(:chi) { File.expand_path("../bin/chi", __dir__) }
    let(:outside) { Dir.mktmpdir("chi-sessions-archive-cwd") }

    after { FileUtils.rm_rf(outside) }

    def run_chi(*args)
      Open3.capture3({ "XDG_STATE_HOME" => xdg_state }, RbConfig.ruby, chi, "sessions", *args, stdin_data: "", chdir: outside)
    end

    it "archives, hides from list, and list --archived shows it marked (text and json)" do
      kept = make("kept")
      hidden = make("hidden one")

      out, err, status = run_chi("archive", hidden.id)
      expect(status.exitstatus).to eq(0), err
      expect(out).to eq("#{hidden.id[0, 8]}  archived\n")

      listed, = run_chi("list")
      expect(listed).to include(kept.id)
      expect(listed).not_to include(hidden.id)

      all, = run_chi("list", "--archived")
      expect(all).to include(kept.id)
      expect(all).to match(/#{hidden.id} .*hidden one \[archived\]$/)

      json, = run_chi("list", "--archived", "--format", "json")
      rows = JSON.parse(json).to_h { |row| [row["id"], row["archived"]] }
      expect(rows).to eq(kept.id => false, hidden.id => true)
    end

    it "keeps an archived session through a prune, and doesn't count it against --keep" do
      gone = make("gone")
      hidden = make("hidden")
      Samagotchi::ArchiveStore.archive(hidden.id, state_dir: state_dir)
      newest = make("newest")

      out, err, status = run_chi("prune", "--dry-run", "--days", "0", "--keep", "1")
      expect(status.exitstatus).to eq(0), err
      expect(out).to start_with("Would delete 1 sessions (kept 1, skipped 0)\n  #{gone.id}\n")
      expect(out).not_to include(hidden.id)
      expect(out).not_to include(newest.id)
    end

    it "names archive and unarchive in its usage and for an unknown subcommand" do
      help, = run_chi("--help")
      expect(help).to include("<list|stop|archive|unarchive|delete|prune|clean>")
      _, err, = run_chi("nope")
      expect(err).to include("Use: list, stop, archive, unarchive, delete, prune, clean")
    end
  end
end
