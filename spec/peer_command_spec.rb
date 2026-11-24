# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "stringio"
require "json"
require "samagotchi/peer_command"
require "samagotchi/session_access/local"
require "samagotchi/session_manager"
require "samagotchi/archive_store"
require "samagotchi/owner_lock"
require "samagotchi/worker_link"

# chi peer pair|unpair|say|ls over this machine's files (SessionAccess::Local).
RSpec.describe Samagotchi::PeerCommand do
  let(:root) { Dir.mktmpdir("peer-command") }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:access) { Samagotchi::SessionAccess::Local.new(state_dir: state_dir) }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:worker) { Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker", started_at: nil) }
  let(:session) { saved_session }
  let(:owner) { nil }
  let(:features) { nil }

  before do
    FileUtils.mkdir_p(state_dir)
    allow(Samagotchi::SessionManager).to receive(:session_owner) { owner }
    allow(Samagotchi::SessionManager).to receive(:start_for_inbox).and_return(:woken)
    allow(Samagotchi::WorkerLink).to receive(:live_features) { features }
  end

  after do
    FileUtils.chmod_R("u+w", root)
    FileUtils.remove_entry(root)
  end

  def saved_session(started: true, continues: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root, continues: continues).tap do |s|
      s.messages = [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }] if started
      s.save(state_dir: state_dir)
    end
  end

  def run(*argv, stdin: "")
    described_class.new(argv, stdin: StringIO.new(stdin), stdout: stdout, stderr: stderr, state_dir: state_dir,
                              access: access, sleeper: ->(_) {}).run
  end

  def pair(id = session.id, peer = "claude") = Samagotchi::PeerMailbox.pair(id, peer, address: nil, from: nil, state_dir: state_dir)

  def mailbox_files = Dir.glob(File.join(Samagotchi::PeerMailbox.root(state_dir: state_dir), "**", "*")).select { |f| File.file?(f) }

  def in_files(id = session.id, peer = "claude") = Samagotchi::PeerMailbox.serials(id, peer, state_dir: state_dir)

  def write_receipts(id, peer, taken:, receipts:)
    FileUtils.mkdir_p(File.dirname(Samagotchi::PeerReceipts.path(id, state_dir: state_dir)))
    File.write(Samagotchi::PeerReceipts.path(id, state_dir: state_dir),
               JSON.generate("peers" => { peer => { "box" => "a1b2c3", "taken" => taken, "receipts" => receipts } }))
  end

  describe "say: the refusals of P4, nothing written" do
    it "refuses a session that isn't paired (exit 1)" do
      expect(run("say", "claude", session.id, "--wake", "-m", "hi")).to eq(1)
      expect(stderr.string).to eq("chi peer say: not paired: run the pair script\n")
      expect(mailbox_files).to eq([])
    end

    it "refuses a continued session with the next id" do
      pair
      Samagotchi::ArchiveStore.archive(session.id, state_dir: state_dir)
      successor = saved_session(continues: session.id)
      expect(run("say", "claude", session.id, "--wake", "-m", "hi")).to eq(1)
      expect(stderr.string).to eq("chi peer say: this session was continued as #{successor.id}: say it there\n")
      expect(in_files).to eq([])
    end

    context "with a live worker from before the peer mail" do
      let(:owner) { worker }
      let(:features) { %w[restart task_stop] }

      it "refuses the say and the pairing alike: restart the session" do
        expect(run("pair", "claude", session.id)).to eq(1)
        expect(stderr.string).to include("chi peer pair: ", "restart the session")
        pair
        expect(run("say", "claude", session.id, "--wake", "-m", "hi")).to eq(1)
        expect(stderr.string).to include("chi peer say: ", "restart the session")
        expect(in_files).to eq([])
      end
    end

    it "refuses the 201st unread message" do
      pair
      200.times { |n| Samagotchi::PeerMailbox.post(session.id, "claude", text: "m#{n}", summary: nil, wake: false, re: nil, state_dir: state_dir) }
      expect(run("say", "claude", session.id, "--nowake", "-m", "hi")).to eq(1)
      expect(stderr.string).to eq("chi peer say: chi has 200 unread messages from claude\n")
      expect(in_files.size).to eq(200)
    end

    it "refuses a gone session: no such session" do
      expect(access.peer_say(SecureRandom.uuid, "claude", text: "hi", summary: nil, wake: true, re: nil).status).to eq(:gone)
      expect(run("say", "claude", "nosuchid", "--wake", "-m", "hi")).to eq(1)
      expect(stderr.string).to eq("chi peer say: no such session\n")
      expect(mailbox_files).to eq([])
    end

    context "with a session being deleted" do
      let(:owner) { Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "deleting", started_at: nil) }

      it "writes nothing" do
        pair
        expect(run("say", "claude", session.id, "--wake", "-m", "hi")).to eq(1)
        expect(stderr.string).to eq("chi peer say: this session is being deleted\n")
        expect(in_files).to eq([])
      end
    end

    it "refuses a bad name and a missing --wake/--nowake as usage (exit 2)" do
      expect(run("say", "Claude", session.id, "--wake", "-m", "hi")).to eq(2)
      expect(run("say", "claude", session.id, "-m", "hi")).to eq(2)
      expect(stderr.string).to include("--wake or --nowake")
      expect(mailbox_files).to eq([])
    end
  end

  describe "say: the line, at once" do
    before { pair }

    it "says chi is stopped" do
      Samagotchi::Session.mark_stopped(session.id, state_dir: state_dir)
      expect(run("say", "claude", session.id, "--wake", "-m", "hi", "--wait", "8")).to eq(0)
      expect(stdout.string).to eq("#1 received · chi is stopped: it reads this at its next start\n")
    end

    it "says the session is archived" do
      Samagotchi::ArchiveStore.archive(session.id, state_dir: state_dir)
      run("say", "claude", session.id, "--wake", "-m", "hi", "--wait", "8")
      expect(stdout.string).to eq("#1 received · this session is archived: it reads this if you reopen it\n")
    end

    context "with a one-turn chi run holding it" do
      let(:owner) { Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "tui", started_at: nil) }

      it "says it reads this at its next start" do
        run("say", "claude", session.id, "--wake", "-m", "hi", "--wait", "8")
        expect(stdout.string).to eq("#1 received · a one-turn chi run has this session: it reads this at its next start\n")
      end
    end

    it "says the worker couldn't be started from here (a failed start; Codex's sandbox)" do
      allow(Samagotchi::SessionManager).to receive(:start_for_inbox).and_raise(Errno::EPERM)
      expect(run("say", "claude", session.id, "--wake", "-m", "hi", "--wait", "8")).to eq(0), stderr.string
      expect(stdout.string).to eq("#1 received · chi's worker isn't running and couldn't be started from here: " \
                                  "it reads this at its next start\n")
      expect(in_files).to eq([1])
    end

    it "says chi is starting" do
      allow(Samagotchi::SessionManager).to receive(:start_for_inbox).and_return(:starting)
      run("say", "claude", session.id, "--wake", "-m", "hi", "--wait", "8")
      expect(stdout.string).to eq("#1 received · chi is starting\n")
    end

    it "says chi's worker isn't running for a message that doesn't wake" do
      run("say", "claude", session.id, "--nowake", "-m", "hi", "--wait", "8")
      expect(stdout.string).to eq("#1 received · chi's worker isn't running: it reads this at its next start\n")
      expect(Samagotchi::SessionManager).not_to have_received(:start_for_inbox)
    end

    context "with a live worker" do
      let(:owner) { worker }
      let(:features) { [Samagotchi::PeerMailbox::FEATURE] }

      it "says chi is in a turn when the saved status is running" do
        session.status = Samagotchi::Session::STATUS_RUNNING
        session.save(state_dir: state_dir)
        run("say", "claude", session.id, "--wake", "-m", "hi", "--wait", "8")
        expect(stdout.string).to eq("#1 received · chi is in a turn: it reads this when the turn ends\n")
      end

      it "says chi hasn't had a turn yet" do
        fresh = saved_session(started: false)
        pair(fresh.id)
        run("say", "claude", fresh.id, "--wake", "-m", "hi", "--wait", "8")
        expect(stdout.string).to eq("#1 received · chi hasn't had a turn yet: it reads this with its first\n")
      end
    end
  end

  describe "say --wait" do
    let(:owner) { worker }
    let(:features) { [Samagotchi::PeerMailbox::FEATURE] }

    before { pair }

    it "returns on the receipt, with the peer's other held messages" do
      polls = 0
      sleeper = lambda do |_seconds|
        polls += 1
        next unless polls == 2

        write_receipts(session.id, "claude", taken: 3, receipts: [
          { "serial" => 1, "state" => "held", "reason" => "paused", "at" => "x" },
          { "serial" => 2, "state" => "held", "reason" => "paused", "at" => "x" },
          { "serial" => 3, "state" => "woke", "turn" => "t1", "at" => "x" }
        ])
      end
      2.times { |n| Samagotchi::PeerMailbox.post(session.id, "claude", text: "m#{n}", summary: nil, wake: false, re: nil, state_dir: state_dir) }
      said = access.peer_say(session.id, "claude", text: "third", summary: nil, wake: true, re: nil, wait: 8, sleeper: sleeper)
      expect(said.line("claude")).to eq("#3 received · woke chi · also held: #1, #2 (paused)")
      expect(polls).to eq(2)
    end

    it "returns on the deadline with no answer from chi yet" do
      now = 100.0
      slept = []
      said = access.peer_say(session.id, "claude", text: "hi", summary: nil, wake: true, re: nil, wait: 8,
                                                   sleeper: ->(s) { (slept << s) && (now += s) }, clock: -> { now })
      expect(said.line("claude")).to eq("#1 received · no answer from chi yet")
      expect(slept.sum).to be_within(0.3).of(8)
      expect(slept).to all(be <= 0.25)
    end

    it "names the turns a peer_turns hold counts, as configured" do
      write_receipts(session.id, "claude", taken: 0, receipts: [{ "serial" => 1, "state" => "held", "reason" => "peer_turns", "at" => "x" }])
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("context.peer_turns").and_return(1)
      said = access.peer_say(session.id, "claude", text: "hi", summary: nil, wake: true, re: nil, wait: 1, sleeper: ->(_) {})
      expect(said.line("claude")).to eq("#1 received · held: 1 peer turn in a row (context.peer_turns) · waits for the user's next message")
    end
  end

  it "starts an idle-exited session for a waking say two minutes after the previous one: no window" do
    pair
    t0 = Time.now
    allow(Time).to receive(:now).and_return(t0)
    run("say", "claude", session.id, "--wake", "-m", "one")
    allow(Time).to receive(:now).and_return(t0 + 120)
    run("say", "claude", session.id, "--wake", "-m", "two")
    expect(Samagotchi::SessionManager).to have_received(:start_for_inbox)
      .with(session.id, state_dir: state_dir, event: :peer_woke_session).twice
    expect(in_files).to eq([1, 2])
  end

  it "asks for a worker by the message's own wake alone: context.wake off changes nothing" do
    pair
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("context.wake").and_return(false)
    run("say", "claude", session.id, "--wake", "-m", "one")
    expect(Samagotchi::SessionManager).to have_received(:start_for_inbox).once
  end

  it "reads the text from stdin and keeps --summary and --re" do
    pair
    expect(run("say", "claude", session.id, "--nowake", "--summary", "my take", "--re", "s-1", stdin: "from stdin")).to eq(0)
    message = Samagotchi::PeerMailbox.message(session.id, "claude", 1, state_dir: state_dir)
    expect([message.text, message.summary, message.re, message.wake]).to eq(["from stdin", "my take", "s-1", false])
  end

  describe "the door" do
    let(:owner) { worker }
    let(:features) { [Samagotchi::PeerMailbox::FEATURE] }

    it "pairs and says to a live session with the sessions folder read-only, writing only under mailbox/" do
      session
      FileUtils.mkdir_p(Samagotchi::PeerMailbox.root(state_dir: state_dir))
      before = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).to_h { |f| [f, File.mtime(f)] }
      FileUtils.chmod_R("a-w", state_dir)

      expect(run("pair", "claude", session.id, "--address", "/tmp/sock")).to eq(0)
      expect(run("say", "claude", session.id, "--wake", "-m", "hi", "--wait", "1")).to eq(0)

      after = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).to_h { |f| [f, File.mtime(f)] }
      changed = after.reject { |f, mtime| before[f] == mtime }.keys.select { |f| File.file?(f) }
      mailbox = Samagotchi::PeerMailbox.root(state_dir: state_dir)
      expect(changed).not_to be_empty
      expect(changed).to all(start_with("#{mailbox}/"))
    end
  end

  describe "pair, unpair, ls" do
    it "pairs, lists and unpairs, keeping the messages" do
      expect(run("pair", "claude", session.id, "--address", "/tmp/c.sock", "--from", "claude-code")).to eq(0)
      expect(stdout.string).to eq("#{session.id[0, 8]}  paired with Claude\n")
      link = Samagotchi::PeerMailbox.link(session.id, "claude", state_dir: state_dir)
      expect([link.address, link.from]).to eq(["/tmp/c.sock", "claude-code"])
      run("say", "claude", session.id, "--nowake", "--summary", "first", "-m", "x")

      stdout.truncate(0)
      stdout.rewind
      expect(run("ls", session.id, "--format", "json")).to eq(0)
      listed = JSON.parse(stdout.string)
      expect(listed).to match([include("name" => "claude", "label" => "Claude", "address" => "/tmp/c.sock",
                                       "messages" => [include("serial" => 1, "summary" => "first", "receipt" => nil)])])

      expect(run("unpair", "claude", session.id)).to eq(0)
      expect(Samagotchi::PeerMailbox.link(session.id, "claude", state_dir: state_dir)).to be_nil
      expect(in_files).to eq([1])
      expect(run("unpair", "claude", session.id)).to eq(1)
    end

    it "lists in words" do
      pair
      run("say", "claude", session.id, "--nowake", "--summary", "first", "-m", "x")
      write_receipts(session.id, "claude", taken: 1, receipts: [{ "serial" => 1, "state" => "held", "reason" => "peer_turns", "at" => "x" }])
      stdout.truncate(0)
      stdout.rewind
      run("ls", session.id)
      expect(stdout.string).to include("claude  paired", "#1 held · peer turns  first")
    end

    it "refuses pairing a continued session with the next id" do
      Samagotchi::ArchiveStore.archive(session.id, state_dir: state_dir)
      successor = saved_session(continues: session.id)
      expect(run("pair", "claude", session.id)).to eq(1)
      expect(stderr.string).to eq("chi peer pair: this session was continued as #{successor.id}: pair with it\n")
    end
  end
end
