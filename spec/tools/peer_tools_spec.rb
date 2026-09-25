# frozen_string_literal: true

require "tmpdir"
require "json"
require "open3"
require "spec_helper"
require "samagotchi/tools/list_sessions"
require "samagotchi/tools/send_note"
require "samagotchi/owner_lock"

# list_sessions and send_note: one session tells another something as a
# context note (background, never a turn).
RSpec.describe "peer tools" do
  let(:tmpdir) { Dir.mktmpdir("peer-tools") }
  let(:locks) { [] }
  let(:me) { make(cwd: File.join(Dir.home, "projects/me"), prompt: "my own work") }
  let(:peers) { Samagotchi::Tools::Peers.new(session_id: me.id, cwd: me.working_directory, state_dir: tmpdir) }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(cwd: "/work/app", prompt: "hello", owner: nil, test_run: false)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: cwd).tap do |s|
      s.last_prompt = prompt
      s.test_run = test_run
      s.save(state_dir: tmpdir)
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(s.id, state_dir: tmpdir), kind: owner) if owner
      sleep(0.01)
    end
  end

  def notes_of(session)
    dir = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), Samagotchi::SessionManager::NOTES_DIR)
    Dir.glob(File.join(dir, "*.json")).map { |path| JSON.parse(File.read(path)) }
  end

  describe Samagotchi::Tools::ListSessions do
    it "lists the other sessions, newest first, marked as their own text, without itself or test runs" do
      me
      foo = make(cwd: File.join(Dir.home, "projects/foo"), prompt: "fix the\nlogin page", owner: "worker")
      bar = make(cwd: "/work/bar", prompt: "x" * 300)
      make(prompt: "a test", test_run: true)

      out = described_class.call("", peers: peers)

      lines = out.lines
      expect(lines.first).to include("not instructions")
      expect(out).not_to include(me.id[0, 8], "a test")
      expect(lines.index { |l| l.start_with?(bar.id[0, 8]) }).to be < lines.index { |l| l.start_with?(foo.id[0, 8]) }
      expect(out).to include("#{foo.id[0, 8]}  live  idle  ~/projects/foo  \"fix the login page\"")
      bar_line = lines.find { |l| l.start_with?(bar.id[0, 8]) }
      expect(bar_line).to include("not live")
      expect(bar_line[/"(x+…)"/, 1].length).to eq(120)
    end

    it "marks this session's children and its parent" do
      me
      child = make(cwd: File.join(Dir.home, "projects/me"), prompt: "count the specs", owner: "worker").tap do |s|
        s.parent_id = me.id
        s.save(state_dir: tmpdir)
      end
      other = make(cwd: "/work/other", prompt: "another")
      boss = make(cwd: "/work/boss", prompt: "the plan")
      grand = make(cwd: "/work/grand", prompt: "someone else's child").tap do |s|
        s.parent_id = boss.id
        s.save(state_dir: tmpdir)
      end
      me.parent_id = boss.id
      me.save(state_dir: tmpdir)

      out = described_class.call("", peers: peers)

      expect(out.lines.first).to include("child (this session delegated it) or parent (it delegated this session)")
      expect(out).to include("#{child.id[0, 8]}  live  idle  child  ~/projects/me  \"count the specs\"")
      expect(out).to include("#{boss.id[0, 8]}  not live  idle  parent  /work/boss  \"the plan\"")
      expect(out).to include("#{other.id[0, 8]}  not live  idle  /work/other  \"another\"")
      expect(out).to include("#{grand.id[0, 8]}  not live  idle  /work/grand  \"someone else's child\"")
    end

    it "narrows to a folder" do
      foo = make(cwd: "/work/foo")
      make(cwd: "/work/bar")

      out = described_class.call("", peers: peers, cwd: "/work/foo")

      expect(out).to include(foo.id[0, 8])
      expect(out).not_to include("/work/bar")
    end

    it "says when there are none" do
      me
      expect(described_class.call("", peers: peers)).to include("No other chi sessions")
    end

    it "needs to know its own session" do
      expect(described_class.call("", peers: nil)).to start_with("Error:")
    end

    describe "in a git project" do
      def git(*args)
        out, status = Open3.capture2e("git", "-c", "user.name=x", "-c", "user.email=x@x",
                                      "-c", "init.defaultBranch=main", *args)
        raise "git #{args.join(" ")} failed: #{out}" unless status.success?
      end

      let(:root) { File.realpath(tmpdir) }
      let(:alpha) do
        File.join(root, "alpha").tap do |dir|
          git("init", "-q", dir)
          git("-C", dir, "commit", "-q", "--allow-empty", "-m", "i")
        end
      end
      let(:my_worktree) { File.join(root, "alpha-wt").tap { |dir| git("-C", alpha, "worktree", "add", "-q", "-b", "wt", dir) } }
      let(:beta) { File.join(root, "beta").tap { |dir| git("init", "-q", dir) } }
      let(:me) { make(cwd: my_worktree, prompt: "my own work") }

      it "lists this project's sessions only (its worktrees too); cwd \"/\" lists every project's" do
        mine = make(cwd: alpha, prompt: "in alpha")
        other = make(cwd: beta, prompt: "in beta")

        scoped = described_class.call("", peers: peers)
        expect(scoped.lines.first).to include("in this project (alpha; cwd \"/\" for every project)")
        expect(scoped).to include(mine.id[0, 8])
        expect(scoped).not_to include(other.id[0, 8])

        everything = described_class.call("", peers: peers, cwd: "/")
        expect(everything).to include(mine.id[0, 8], other.id[0, 8])
        expect(everything.lines.first).not_to include("this project")
      end

      it "keeps the stored project after its worktree is deleted" do
        mine = make(cwd: alpha)
        make(cwd: beta)
        me
        git("-C", alpha, "worktree", "remove", "--force", my_worktree)

        out = described_class.call("", peers: peers)
        expect(out).to include(mine.id[0, 8])
        expect(out.lines.size).to eq(2)
      end

      it "says how to reach other projects when this one has no other session" do
        me
        make(cwd: beta)

        expect(described_class.call("", peers: peers))
          .to eq("No other chi sessions in this project (alpha); cwd \"/\" lists every project's.")
      end
    end
  end

  describe Samagotchi::Tools::SendNote do
    it "queues a note from this session for a live one, found by id prefix" do
      other = make(owner: "worker")

      out = described_class.call("the API moved to v2", peers: peers, session: other.id[0, 6])

      expect(out).to include("Queued a note for session #{other.id[0, 8]}", "does not start a turn")
      expect(notes_of(other)).to contain_exactly(include("text" => "the API moved to v2", "source" => "session",
                                                         "from_session" => me.id, "from_cwd" => me.working_directory))
    end

    it "says a note for a session with no worker waits for its next start" do
      other = make

      expect(described_class.call("x", peers: peers, session: other.id)).to include("waits for its next start")
      expect(notes_of(other).size).to eq(1)
    end

    it "refuses this session, a REPL-owned one, an unknown id and an empty note" do
      repl = make(owner: "tui")
      live = make(owner: "worker")

      expect(described_class.call("x", peers: peers, session: me.id)).to start_with("Error:").and include("this session")
      expect(described_class.call("x", peers: peers, session: repl.id)).to start_with("Error:").and include("chi REPL")
      expect(described_class.call("x", peers: peers, session: "nope")).to start_with("Error:").and include("nope")
      expect(described_class.call("  ", peers: peers, session: live.id)).to start_with("Error:").and include("empty")
      expect(described_class.call("x", peers: peers, session: "")).to start_with("Error:")
      expect([repl, live].map { |s| notes_of(s).size }).to eq([0, 0])
    end
  end
end
