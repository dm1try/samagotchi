# frozen_string_literal: true

require "timeout"
require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/tools/delegate"
require "samagotchi/tools/delegate_result"
require "samagotchi/owner_lock"
require "samagotchi/session_manager"

# delegate / delegate_result: a child session as a visible peer; only its
# final reply (an output/ file) comes back to the parent.
RSpec.describe "delegate tools" do
  let(:tmpdir) { Dir.mktmpdir("delegate-tools") }
  let(:locks) { [] }
  let(:threads) { [] }
  let(:parent) { make(cwd: "/work/app", prompt: "the plan", model: "big-model") }
  let(:cancelled) { [false] }
  let(:peers) do
    Samagotchi::Tools::Peers.new(session_id: parent.id, cwd: parent.working_directory, state_dir: tmpdir,
                                 cancelled: -> { cancelled[0] })
  end

  before do
    stub_const("Samagotchi::Tools::DelegateWait::POLL_INTERVAL", 0.05)
    allow(Process).to receive(:spawn).and_return(12_345)
    allow(Process).to receive(:detach)
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("session.max_children").and_return(4)
  end

  after do
    # A wait can return on the reply before its child thread's last step
    # (set_status idle); unjoined, that step's Session.load landed in a later
    # example and broke its `not_to receive(:load)`.
    threads.each { |t| t.join(5) || t.kill }
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(cwd: "/work/app", prompt: "hello", model: "gemma4", parent_id: nil, status: nil, owner: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: cwd, parent_id: parent_id).tap do |s|
      s.last_prompt = prompt
      s.status = status if status
      s.save(state_dir: tmpdir)
      own(s, kind: owner) if owner
      sleep(0.01)
    end
  end

  def own(session, kind: "worker")
    locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), kind: kind)
  end

  def set_status(session, status, pending_question: :keep)
    s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
    s.status = status
    s.pending_question = pending_question unless pending_question == :keep
    s.save(state_dir: tmpdir)
  end

  def write_reply(session, text)
    Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), text)
    sleep(0.002)
  end

  # A turn that failed as its worker records it: idle, no reply, last_turn moved on.
  def fail_turn(session, at:)
    s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
    s.status = "idle"
    s.last_turn = { "outcome" => "failed", "ended_at" => at }
    s.save(state_dir: tmpdir)
  end

  def session_files = Dir.glob(File.join(tmpdir, "*.json")).map { |p| File.basename(p, ".json") }

  # A host's saved model list, as `chi models` leaves it (ModelListStore).
  def saved_models(ids, host: "default", at: Time.now.to_i)
    require "samagotchi/model_list_store"
    Samagotchi::ModelListStore.save(host, ids, at: at)
  end

  # The child's turn as its worker plays it, on another thread.
  def later(delay = 0.15, &)
    Thread.new do
      sleep(delay)
      yield
    end.tap { |t| threads << t }
  end

  describe Samagotchi::Tools::Delegate do
    it "needs the asking session and a task" do
      expect(described_class.call("look", peers: nil)).to eq("Error: this session's id is not known here")
      expect(described_class.call("  ", peers: peers)).to eq("Error: give the task, the child's first message")
    end

    it "starts a child in the parent's folder, on its model, with the delegated memory and the task as its first message" do
      parent
      out = described_class.call("count the specs", wait: false, peers: peers)

      ids = session_files - [parent.id]
      expect(ids.size).to eq(1)
      child = Samagotchi::Session.load(ids.first, state_dir: tmpdir)
      expect(child.parent_id).to eq(parent.id)
      expect(child.working_directory).to eq("/work/app")
      expect(child.model_name).to eq("big-model")
      expect(child.preloaded_memory_names).to eq(["system/delegated"])
      expect(child.status).to eq("running")
      expect(child.last_prompt).to eq("count the specs")
      expect(out).to eq("session: #{child.id}\nstatus: running\nStarted a delegate session; delegate_result waits for its reply. " \
                        "It shows in chi sessions list and the web as a child of this session; the user can attach to it.")
      expect(Process).to have_received(:spawn)
    end

    it "stores the child's model alias resolved, a host prefix kept, and the alias as typed" do
      allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return("tiny" => "box:gemma-small")

      described_class.call("quick look", model: "tiny", wait: "false", peers: peers)

      child = Samagotchi::Session.load((session_files - [parent.id]).first, state_dir: tmpdir)
      expect([child.model_name, child.model_typed]).to eq(%w[box:gemma-small tiny])
    end

    it "refuses a model whose host isn't configured, creating nothing" do
      out = described_class.call("quick look", model: "nosuch:org/model", wait: "false", peers: peers)

      expect(out).to match(%r{\AError: unknown host 'nosuch' in model 'nosuch:org/model'; the configured hosts are })
      expect(session_files).to contain_exactly(parent.id)
    end

    it "starts the child for an id the host's saved list doesn't have, with the hint as a warning" do
      saved_models(%w[gemma-small qwen3])

      out = described_class.call("quick look", model: "default:gemma-smal", wait: "false", peers: peers)

      expect(out).to start_with("Warning: host 'default' doesn't list model 'gemma-smal' (did you mean: gemma-small?); " \
                                "started it anyway; `chi models` lists what the hosts serve\nsession: ")
      expect(session_files.size).to eq(2)
    end

    it "starts the child for an id the host's saved list has" do
      saved_models(%w[gemma-small])

      out = described_class.call("quick look", model: "default:gemma-small", wait: "false", peers: peers)

      expect(out).to start_with("session: ")
      child = Samagotchi::Session.load((session_files - [parent.id]).first, state_dir: tmpdir)
      expect(child.model_name).to eq("default:gemma-small")
    end

    it "starts the child for an unknown id when the list is stale (a week old)" do
      saved_models(%w[gemma-small], at: Time.now.to_i - Samagotchi::ModelListStore::TTL_SECONDS - 60)

      described_class.call("quick look", model: "default:nosuch", wait: "false", peers: peers)

      expect(session_files.size).to eq(2)
    end

    it "starts the child for a bare id the saved list doesn't have (routing picks the host)" do
      saved_models(%w[gemma-small])

      described_class.call("quick look", model: "nosuch", wait: "false", peers: peers)

      expect(session_files.size).to eq(2)
    end

    it "refuses in a session that is itself a delegate, creating nothing" do
      grand = make(parent_id: "root-session-1234")
      mine = Samagotchi::Tools::Peers.new(session_id: grand.id, cwd: "/work/app", state_dir: tmpdir)

      out = described_class.call("go deeper", peers: mine)

      expect(out).to eq("Error: this session is a delegate of root-session-1234; delegated sessions don't delegate further")
      expect(session_files).to contain_exactly(grand.id)
    end

    it "refuses past session.max_children running children, naming them; finished ones don't count" do
      allow(Samagotchi::Config).to receive(:get).with("session.max_children").and_return(1)
      make(parent_id: parent.id, status: "idle", owner: "worker")
      busy = make(parent_id: parent.id, status: "running", owner: "worker")
      before = session_files

      out = described_class.call("one more", peers: peers)

      expect(out).to eq("Error: 1 delegate of this session is running (the most is 1, session.max_children): #{busy.id[0, 8]}. " \
                        "delegate_result waits for one; `chi sessions stop ID` stops one.")
      expect(session_files).to match_array(before)
      expect(Process).not_to have_received(:spawn)
    end

    it "counts a child whose worker is still starting (running, no owner yet), not a stale running one" do
      allow(Samagotchi::Config).to receive(:get).with("session.max_children").and_return(1)
      starting = make(parent_id: parent.id, status: "running")
      expect(described_class.call("one more", peers: peers)).to start_with("Error: 1 delegate of this session is running")
      expect(Process).not_to have_received(:spawn)

      path = File.join(tmpdir, "#{starting.id}.json")
      data = JSON.parse(File.read(path))
      File.write(path, JSON.generate(data.merge("updated_at" => (Time.now - 60).iso8601(3))))
      expect(described_class.call("one more", peers: peers, wait: false)).to include("status: running\nStarted a delegate session")
    end

    it "waits for the child's reply and returns only that" do
      parent
      later do
        child = Samagotchi::Session.load((session_files - [parent.id]).first, state_dir: tmpdir)
        write_reply(child, "42 specs\n")
        set_status(child, "idle")
      end

      out = described_class.call("count the specs", peers: peers)

      child_id = (session_files - [parent.id]).first
      expect(out).to eq("session: #{child_id}\nstatus: answered\n---\n42 specs\n")
    end

    it "reports a turn that ended with no reply once the child was seen running and is idle again" do
      parent
      later do
        child_id = (session_files - [parent.id]).first
        set_status(Samagotchi::Session.load(child_id, state_dir: tmpdir), "idle")
      end

      out = described_class.call("count the specs", peers: peers)

      expect(out).to end_with("status: no_answer\nthe child's turn ended without a reply (canceled, failed or empty); its session shows what happened")
    end

    it "reports a first turn that failed before the wait's first look, not a timeout" do
      parent
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap { |child| fail_turn(child, at: "2026-09-30T10:00:01.000+02:00") }
      end

      out = described_class.call("count the specs", timeout: 2, peers: peers)

      expect(out).to end_with("status: failed\nthe child's turn failed; its session shows what happened")
    end

    describe "a follow-up (session:)" do
      let(:child) { make(parent_id: parent.id, prompt: "first task", status: "idle") }

      it "only reaches this session's children" do
        stranger = make(prompt: "someone else's")
        expect(described_class.call("and?", session: stranger.id[0, 8], peers: peers))
          .to eq("Error: #{stranger.id[0, 8]} is not a delegate of this session; send_note reaches any session")
        expect(described_class.call("and?", session: "nope", peers: peers))
          .to eq("Error: no session nope (list_sessions shows them)")
      end

      it "delivers the message as delegate:<parent> and returns the reply after it, not the earlier one" do
        write_reply(child, "the first answer")
        allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |id, prompt:, client_id:, state_dir:|
          expect([id, prompt, client_id, state_dir]).to eq([child.id, "and the second?", "delegate:#{parent.id[0, 8]}", tmpdir])
          later do
            set_status(child, "running")
            sleep(0.1)
            write_reply(child, "the second answer")
            set_status(child, "idle")
          end
          { status: :accepted, ack: {} }
        end

        out = described_class.call("and the second?", session: child.id[0, 8], peers: peers)

        expect(out).to eq("session: #{child.id}\nstatus: answered\n---\nthe second answer")
      end

      it "reports a follow-up that failed fast after an earlier failure, not a timeout" do
        fail_turn(child, at: "2026-09-30T10:00:01.000+02:00")
        allow(Samagotchi::SessionManager).to receive(:deliver_turn) do
          fail_turn(child, at: "2026-09-30T10:00:05.000+02:00")
          { status: :accepted, ack: {} }
        end

        out = described_class.call("try again", session: child.id, timeout: 2, peers: peers)

        expect(out).to end_with("status: failed\nthe child's turn failed; its session shows what happened")
        # Handed over once: the next wait looks for a later turn.
        expect(Samagotchi::Tools::DelegateResult.call(session: child.id, timeout: 1, peers: peers)).to include("status: running")
      end

      it "names a delivery that did not go through" do
        allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return({ status: :refused, ack: { "error" => "bad_images" } })
        expect(described_class.call("x", session: child.id, peers: peers)).to eq("Error: session #{child.id[0, 8]} refused the message (bad_images)")
        allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return({ status: :timeout, ack: {} })
        expect(described_class.call("x", session: child.id, peers: peers))
          .to eq("Error: the worker of session #{child.id[0, 8]} did not answer in time, so the message was not sent")
        allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return({ status: :failed })
        expect(described_class.call("x", session: child.id, peers: peers)).to eq("Error: the message to session #{child.id[0, 8]} could not be written")
        allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_raise(Samagotchi::SessionManager::OwnedByTUI.new(child.id))
        expect(described_class.call("x", session: child.id, peers: peers))
          .to eq("Error: session #{child.id[0, 8]} is open in a chi REPL, which can't take a delegated message")
      end

      it "returns at once without waiting" do
        allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return({ status: :accepted, ack: {} })
        out = described_class.call("more", session: child.id, wait: false, peers: peers)
        expect(out).to start_with("session: #{child.id}\nstatus: running\nSent the follow-up to delegate #{child.id[0, 8]}; delegate_result waits")
      end
    end
  end

  describe Samagotchi::Tools::DelegateWait do
    let(:child) { make(parent_id: parent.id, prompt: "task", status: "running", owner: "worker") }

    def wait(timeout: 5) = described_class.call(child.id, peers: peers, timeout: timeout)

    it "returns a reply already on disk at once, also from a child whose worker is gone" do
      idle = make(parent_id: parent.id, prompt: "done long ago", status: "idle")
      write_reply(idle, "saved reply")

      expect(described_class.call(idle.id, peers: peers, timeout: 5)).to eq("session: #{idle.id}\nstatus: answered\n---\nsaved reply")
      # Given once: the next wait does not repeat it.
      expect(described_class.call(idle.id, peers: peers, timeout: 0)).to include("status: running\nno reply yet after 0 s")
    end

    it "returns early while the child waits for an approval or a question, with the whole question" do
      set_status(child, "running", pending_question: { id: "q1", kind: "approval", question: "Run rm?" })
      expect(wait).to eq("session: #{child.id}\nstatus: question\nChild #{child.id} is waiting for an answer (approval): Run rm?\n  " \
                         "allowing it is up to your user: deny it, and tell your user\n  " \
                         "deny: chi answer #{child.id} --question q1 --option Deny --text WHY\n  " \
                         "or leave it open: tell your user it waits in chi web (session #{child.id[0, 8]}); " \
                         "chi send --wait --format json #{child.id} waits until they answer\n" \
                         "delegate_result #{child.id} waits again once it is answered.")

      set_status(child, "running", pending_question: { id: "q2", question: "Which one?", options: %w[A B] })
      expect(wait).to include("status: question\nChild #{child.id} is waiting for an answer (question): Which one?\n    " \
                              "1. A\n    2. B\n  answer: chi answer #{child.id} --question q2 --option N\n")
    end

    it "hands a child's step-limit question back to the parent model (not relayed): continue, follow up or report" do
      set_status(child, "idle", pending_question: { id: "c1", kind: "continue", header: "Step limit",
                                                    question: "The turn ran out of iterations (100 steps) before it answered. Continue it?",
                                                    options: %w[Continue Stop], allow_freeform: true, limit: 100 })
      out = wait
      expect(out).to start_with("session: #{child.id}\nstatus: question\nChild #{child.id} is waiting for an answer (continue): Step limit\n")
      expect(out).to include("  continue: chi answer #{child.id} --question c1 --option Continue\n")
      expect(out).to include("  stop: chi answer #{child.id} --question c1 --option Stop --text WHY")
      expect(out).to include("send it a narrower follow-up with delegate session: #{child.id} (that drops the question)")
      expect(out).to end_with("delegate_result #{child.id} waits again once it is answered.")
    end

    it "says the child's worker is gone, not that its question waits, when the worker died asking" do
      dead = make(parent_id: parent.id, prompt: "task", status: "running")
      set_status(dead, "running", pending_question: { id: "q1", question: "Which one?" })

      out = described_class.call(dead.id, peers: peers, timeout: 5, owner_grace: 0.1)
      expect(out).to eq("session: #{dead.id}\nstatus: worker_gone\nthe child's worker is gone (it stopped or crashed); " \
                        "delegate with session: #{dead.id} starts it again with a message")
    end

    it "returns when the parent's turn is canceled; the child keeps running" do
      child
      later { cancelled[0] = true }

      expect(wait).to eq("session: #{child.id}\nstatus: running\nwait canceled; the child keeps running; delegate_result #{child.id} waits again")
      expect(Samagotchi::Session.load(child.id, state_dir: tmpdir).status).to eq("running")
    end

    it "returns a crashed or stopped child at once" do
      set_status(child, "error")
      s = Samagotchi::Session.load(child.id, state_dir: tmpdir)
      s.last_prompt = "boom"
      s.save(state_dir: tmpdir)
      expect(wait).to eq("session: #{child.id}\nstatus: error\nthe child's worker failed: boom; its session shows what happened")

      set_status(child, "stopped")
      expect(wait).to include("status: stopped\nthe child was stopped (chi sessions stop)")
    end

    it "times out with the attach hint while the child still runs" do
      child
      expect(wait(timeout: 0)).to eq("session: #{child.id}\nstatus: running\nno reply yet after 0 s; the child keeps running. " \
                                     "delegate_result #{child.id} waits again; chi --attach #{child.id} shows it.")
    end

    it "keeps waiting on an idle child it never saw running (a follow-up not picked up yet)" do
      set_status(child, "idle")
      later do
        set_status(child, "running")
        sleep(0.1)
        write_reply(child, "late reply")
        set_status(child, "idle")
      end

      expect(wait).to end_with("status: answered\n---\nlate reply")
    end

    it "cuts a long reply head and tail, like an execute result" do
      write_reply(child, ("a" * 40_000) + "MIDDLE" + ("z" * 40_000))

      out = wait
      expect(out).to include("status: answered\n---\ntruncated=true\npreview_strategy=head_tail\nreply_bytes=80006")
      expect(out).to include("[TRUNCATED_PREVIEW_HEAD]\n" + ("a" * 100))
      expect(out).to include("[TRUNCATED_PREVIEW_TAIL]")
      expect(out).not_to include("MIDDLE")
      expect(out.bytesize).to be < 14_000
    end

    it "says so when the child's session is gone" do
      expect(described_class.call("no-such-id", peers: peers, timeout: 1)).to eq("Error: Session not found: no-such-id")
    end

    describe "the cursor on disk (DelegateCursors)" do
      let(:idle) { make(parent_id: parent.id, prompt: "task", status: "idle") }

      it "keeps it in the parent's delegates.json, so a respawned parent doesn't repeat a reply" do
        write_reply(idle, "the reply")
        expect(described_class.call(idle.id, peers: peers, timeout: 0)).to end_with("---\nthe reply")

        data = JSON.parse(File.read(File.join(Samagotchi::Session.session_dir(parent.id, state_dir: tmpdir), "delegates.json")))
        expect(data[idle.id]).to include("reply_file" => end_with(".txt"), "messages" => 0)

        # Nothing is kept in memory: a new worker reads the same file.
        expect(described_class.call(idle.id, peers: peers, timeout: 0)).to include("status: running\nno reply yet")
      end

      it "re-baselines after a reply, so a later turn that fails reports no_reply, not the old reply" do
        write_reply(idle, "first")
        expect(described_class.call(idle.id, peers: peers, timeout: 0)).to end_with("---\nfirst")

        fail_turn(idle, at: "2026-10-05T10:00:00.000Z")
        expect(described_class.call(idle.id, peers: peers, timeout: 0)).to include("status: failed")
        expect(described_class.call(idle.id, peers: peers, timeout: 0)).to include("status: running\nno reply yet")
      end

      it "reports a question once; the next wait waits for its answer" do
        set_status(idle, "idle", pending_question: { id: "q9", question: "Which one?", options: %w[A B] })
        own(idle)
        expect(described_class.call(idle.id, peers: peers, timeout: 0)).to include("status: question")
        expect(described_class.call(idle.id, peers: peers, timeout: 0)).to include("status: running\nno reply yet")
      end

      it "moves nothing on a timeout" do
        idle
        expect(described_class.call(idle.id, peers: peers, timeout: 0)).to include("no reply yet")
        expect(Samagotchi::Tools::DelegateCursors.get(parent.id, idle.id, state_dir: tmpdir).baseline).to be_nil
      end
    end
  end

  describe Samagotchi::Tools::DelegateResult do
    it "waits for the newest running child when none is named" do
      make(parent_id: parent.id, prompt: "older", status: "running", owner: "worker")
      newest = make(parent_id: parent.id, prompt: "newest", status: "running", owner: "worker")
      write_reply(newest, "newest reply")

      expect(described_class.call(peers: peers, timeout: 1)).to eq("session: #{newest.id}\nstatus: answered\n---\nnewest reply")
    end

    it "says when no child runs" do
      make(parent_id: parent.id, prompt: "finished", status: "idle")
      expect(described_class.call(peers: peers)).to eq("No running delegate; list_sessions shows finished ones.")
      expect(described_class.call(peers: nil)).to eq("Error: this session's id is not known here")
    end

    it "takes a child's id or prefix, and only a child's" do
      child = make(parent_id: parent.id, prompt: "task", status: "idle")
      write_reply(child, "its reply")
      stranger = make(prompt: "other")

      expect(described_class.call(session: child.id[0, 8], peers: peers, timeout: 1)).to eq("session: #{child.id}\nstatus: answered\n---\nits reply")
      expect(described_class.call(session: stranger.id, peers: peers))
        .to eq("Error: #{stranger.id[0, 8]} is not a delegate of this session (list_sessions marks them child)")
      expect(described_class.call(session: "zzz", peers: peers)).to eq("Error: no session zzz (list_sessions shows them)")
    end

    it "checks once and returns at once with timeout 0 or less, not after the 600 s default" do
      child = make(parent_id: parent.id, prompt: "task", status: "running", owner: "worker")

      [0, "0", -5].each do |timeout|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        out = Timeout.timeout(3) { described_class.call(session: child.id, peers: peers, timeout: timeout) }
        expect(out).to include("status: running\nno reply yet after 0 s")
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      end
      write_reply(child, "its reply")
      expect(described_class.call(session: child.id, peers: peers, timeout: 0)).to eq("session: #{child.id}\nstatus: answered\n---\nits reply")
    end
  end

  describe ".parse_timeout" do
    it "keeps 0 (check now) and makes a negative 0; only a missing or unreadable value takes the default" do
      parse = ->(v) { Samagotchi::Tools::Delegate.parse_timeout(v) }
      expect([parse.call(0), parse.call("0"), parse.call(-3), parse.call(" 12 ")]).to eq([0, 0, 0, 12])
      default = Samagotchi::Tools::DelegateWait::TIMEOUT_DEFAULT
      expect([parse.call(nil), parse.call(""), parse.call("soon")]).to eq([default, default, default])
    end
  end
end
