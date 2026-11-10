# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/session_access/local"
require "samagotchi/session_manager"
require "samagotchi/reply_wait"
require "samagotchi/context_command"
require "samagotchi/context_sources"
require "socket"
require_relative "support/worker_links"
require_relative "support/worker_fixtures"

# SessionAccess::Local: this machine's sessions, the calls the session
# commands made before the seam (their own specs cover the behaviour).
RSpec.describe Samagotchi::SessionAccess::Local do
  include WorkerLinks
  include WorkerFixtures

  let(:tmpdir) { Dir.mktmpdir("session-access") }
  let(:access) { described_class.new(state_dir: tmpdir) }

  after { FileUtils.rm_rf(tmpdir) }

  def saved_session(**attrs)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap do |session|
      attrs.each { |key, value| session.public_send(:"#{key}=", value) }
      session.save(state_dir: tmpdir)
    end
  end

  def context_target(session_id)
    Samagotchi::ContextCommand::Target.new(session_id: session_id, project_root: tmpdir, cwd: tmpdir, label: "session")
  end

  def push_source(location, name, scope: "session")
    location.add(Samagotchi::ContextSources::Source.new(name: name, cmd: nil, every_seconds: nil, why: nil, hint: nil,
                                                        scope: scope, added_by: "spec", created_at: nil))
  end

  def fetched(text, wake: true)
    Samagotchi::ContextSources::Fetched.new(text: text, summary: nil, wake: wake, hint: nil)
  end

  describe "#head" do
    it "is SessionInbox::Head's send walk: a continued link's newest one, else the id" do
      old = saved_session
      Samagotchi::ArchiveStore.archive(old.id, state_dir: tmpdir)
      newer = saved_session(continues: old.id)

      expect(access.head(old.id).to_h).to eq(id: newer.id, asked: old.id, via: :head)
      expect(access.head(newer.id).to_h).to eq(id: newer.id, asked: newer.id, via: :same)
    end
  end

  describe "#context_push" do
    before do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("context.wake").and_return(true)
    end

    it "wakes for a changed session-scoped push that asks" do
      session = saved_session
      location = Samagotchi::ContextSources.session_location(session.id, state_dir: tmpdir)
      push_source(location, "notes")
      allow(Samagotchi::SessionManager).to receive(:start_for_inbox).and_return(:woken)

      pushed = access.context_push(context_target(session.id), "notes", fetched("new answer"))

      expect(pushed).to have_attributes(status: :pushed, before: nil, revision: Samagotchi::ContextSources.revision_of("new answer"))
      expect(Samagotchi::SessionManager).to have_received(:start_for_inbox).with(session.id, state_dir: tmpdir, event: :context_woke_session).once
    end

    it "does not wake for an unchanged revision or a push without wake" do
      session = saved_session
      location = Samagotchi::ContextSources.session_location(session.id, state_dir: tmpdir)
      push_source(location, "notes")
      location.record_text("notes", fetched("same"))
      allow(Samagotchi::SessionManager).to receive(:start_for_inbox)

      access.context_push(context_target(session.id), "notes", fetched("same"))
      access.context_push(context_target(session.id), "notes", fetched("another", wake: false))

      expect(Samagotchi::SessionManager).not_to have_received(:start_for_inbox)
    end

    it "does not wake project sources or when context.wake is off" do
      session = saved_session
      project = Samagotchi::ContextSources.project_location_for(tmpdir, state_dir: tmpdir)
      push_source(project, "project-notes", scope: "project")
      push_source(Samagotchi::ContextSources.session_location(session.id, state_dir: tmpdir), "session-notes")
      allow(Samagotchi::SessionManager).to receive(:start_for_inbox)

      project_target = Samagotchi::ContextCommand::Target.new(session_id: nil, project_root: tmpdir, cwd: tmpdir,
                                                              label: "project")
      access.context_push(project_target, "project-notes", fetched("project text"))
      allow(Samagotchi::Config).to receive(:get).with("context.wake").and_return(false)
      access.context_push(context_target(session.id), "session-notes", fetched("session text"))

      expect(Samagotchi::SessionManager).not_to have_received(:start_for_inbox)
    end

    it "respects the session source's wake window" do
      session = saved_session
      location = Samagotchi::ContextSources.session_location(session.id, state_dir: tmpdir)
      push_source(location, "notes")
      location.update_subscription("notes") { |sub| sub.with(wakes_at: Time.now.iso8601) }
      allow(Samagotchi::SessionManager).to receive(:start_for_inbox)

      access.context_push(context_target(session.id), "notes", fetched("new answer"))

      expect(Samagotchi::SessionManager).not_to have_received(:start_for_inbox)
    end

    # Research probe step 1: a wake push into a session with no worker.
    it "starts no worker for a wake push into a stopped session, keeps the stop, and says so" do
      session = saved_session
      push_source(Samagotchi::ContextSources.session_location(session.id, state_dir: tmpdir), "notes")
      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
      allow(Samagotchi::SessionManager).to receive(:resume_session)

      pushed = access.context_push(context_target(session.id), "notes", fetched("new answer"))

      expect(pushed).to have_attributes(status: :pushed, wake: :stopped)
      expect(Samagotchi::SessionManager).not_to have_received(:resume_session)
      expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: tmpdir)).to be(true)
      expect(Samagotchi::OwnerLock.owner(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir))).to be_nil
    end

    it "starts a worker for a wake push into an idle-exited session, and says so; nothing for a push that asks none" do
      session = saved_session
      push_source(Samagotchi::ContextSources.session_location(session.id, state_dir: tmpdir), "notes")
      allow(Samagotchi::SessionManager).to receive(:resume_session)

      expect(access.context_push(context_target(session.id), "notes", fetched("new answer")).wake).to eq(:woken)
      expect(Samagotchi::SessionManager).to have_received(:resume_session).with(session.id, state_dir: tmpdir).once
      expect(access.context_push(context_target(session.id), "notes", fetched("again", wake: false)).wake).to be_nil
    end

    it "logs a failed wake without changing the successful push result" do
      session = saved_session
      push_source(Samagotchi::ContextSources.session_location(session.id, state_dir: tmpdir), "notes")
      failure = RuntimeError.new("spawn failed")
      allow(Samagotchi::SessionManager).to receive(:start_for_inbox).and_raise(failure)
      expect(Samagotchi::Log).to receive(:exception).with(:context, "context_push_wake_failed", failure,
                                                          sid: session.id, source: "notes")

      expect(access.context_push(context_target(session.id), "notes", fetched("new answer"))).to have_attributes(status: :pushed)
    end
  end

  it "creates a session with the setup's toolkit origin" do
    allow(Process).to receive(:spawn).and_return(12_345)
    setup = Samagotchi::SessionSetup.new(toolkit: Samagotchi::Toolkit.new(name: "lean"))
    spec = Samagotchi::SessionAccess::NewSession.new(prompt: "hi", working_directory: tmpdir, model_name: "m", setup: setup)

    created = access.create(spec)

    expect(Samagotchi::Session.load(created.id, state_dir: tmpdir).toolkit_origin).to eq("chosen")
  end

  it "passes no state_dir: on when it has none (the callees' default)" do
    allow(Samagotchi::SessionManager).to receive(:restart_session)
    described_class.new.restart("abc")
    expect(Samagotchi::SessionManager).to have_received(:restart_session).with("abc")

    access.restart("abc")
    expect(Samagotchi::SessionManager).to have_received(:restart_session).with("abc", state_dir: tmpdir)
  end

  it "resolves a prefix to a session that exists, and refuses one that doesn't" do
    session = saved_session
    expect(access.resolve(session.id[0, 8])).to eq(session.id)
    expect { access.resolve("0000dead") }.to raise_error(ArgumentError)
  end

  describe "#wake and #worker (a remote attach, through chi web)" do
    let(:server) { TCPServer.new("127.0.0.1", 0) }

    after { server.close }

    def sidecar_for(session, epoch: "ab12cd34")
      live_sidecar_fixture(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir),
                           port: server.local_address.ip_port, session_id: session.id, epoch: epoch)
    end

    it "wakes nothing for a live worker, else resumes and waits; a Bridge that doesn't come is no sidecar" do
      session = saved_session
      allow(Samagotchi::SessionManager).to receive(:resume_session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(none_link)

      expect(access.wake(session.id, wait: 0.1)).to eq(Samagotchi::SessionAccess::Woken.new(woke: true, sidecar: nil))

      sidecar_for(session)
      expect(access.wake(session.id, wait: 0.1)).to have_attributes(woke: false, sidecar: have_attributes(epoch: "ab12cd34"))
      expect(Samagotchi::SessionManager).to have_received(:resume_session).once
    end

    it "reads stale files (a sidecar under a free lock) as no worker, and wakes by resuming" do
      session = saved_session
      dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      Samagotchi::WorkerSidecar.new(port: server.local_address.ip_port, session_id: session.id, pid: Process.pid + 1).write(dir)
      allow(Samagotchi::SessionManager).to receive(:resume_session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(none_link)

      expect(access.worker(session.id)).to have_attributes(live?: false, owner: nil)
      expect(access.wake(session.id, wait: 0.1)).to eq(Samagotchi::SessionAccess::Woken.new(woke: true, sidecar: nil))
      expect(Samagotchi::SessionManager).to have_received(:resume_session).once
    end

    it "resumes when a starting worker lets go of the lock without publishing its Bridge" do
      session = saved_session
      owner = Samagotchi::OwnerLock::Owner.new(pid: Process.pid + 1, kind: "worker")
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(Samagotchi::WorkerLink::Starting.new(owner: owner))
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(none_link)
      allow(Samagotchi::SessionManager).to receive(:resume_session)

      expect(access.wake(session.id, wait: 0.1)).to eq(Samagotchi::SessionAccess::Woken.new(woke: true, sidecar: nil))
      expect(Samagotchi::SessionManager).to have_received(:resume_session).once
      expect(Samagotchi::WorkerLink).to have_received(:await).with(session.id, hash_including(:give_up)).once
    end

    it "refuses a wake of a worker on a newer protocol (worker_newer), and resumes nothing" do
      session = saved_session
      dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      live_sidecar_fixture(dir, port: server.local_address.ip_port, session_id: session.id, protocol: Samagotchi::WorkerLink::PROTOCOL + 1)
      allow(Samagotchi::SessionManager).to receive(:resume_session)

      expect(access.worker(session.id)).to have_attributes(live?: false, skew?: true)
      expect { access.wake(session.id, wait: 0.1) }
        .to raise_error(Samagotchi::SessionAccess::Refused) { |e| expect(e.code).to eq("worker_newer") }
      expect(Samagotchi::SessionManager).not_to have_received(:resume_session)
    end

    it "refuses a leftover scratch session and an unknown one" do
      scratch = saved_session(scratch: true)

      expect { access.wake(scratch.id, wait: 0.1) }
        .to raise_error(Samagotchi::SessionAccess::Refused, Samagotchi::Session::SCRATCH_REFUSED) { |e| expect(e.code).to eq("scratch") }
      expect { access.wake("0000dead", wait: 0.1) }.to raise_error(ArgumentError)
    end

    it "reads the worker: its sidecar while live, the stop marker, the owner" do
      session = saved_session
      expect(access.worker(session.id)).to have_attributes(live?: false, stopped: false, owner: nil)

      sidecar_for(session)
      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
      expect(access.worker(session.id)).to have_attributes(live?: true, stopped: true, sidecar: have_attributes(epoch: "ab12cd34"))
    end
  end

  describe "#prepare_wait" do
    it "reads the newest reply, the baseline and the session's state before a send" do
      session = saved_session
      replies = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), Samagotchi::SessionInbox::OUTPUT_DIR)
      FileUtils.mkdir_p(replies)
      File.write(File.join(replies, "20261023T100000.txt"), "old")

      start = access.prepare_wait(session.id)
      expect(start).to have_attributes(cursor: "20261023T100000.txt", own_turn: nil, known_turn: nil, live: false,
                                       baseline: Samagotchi::ReplyWait.baseline_of(session))
    end

    it "says whether a turn asked for can be waited for" do
      session = saved_session
      expect(access.prepare_wait(session.id, turn: "t-1").known_turn).to be(false)
    end

    it "takes the baseline of a question answered now, and of a just-created session with no cursor" do
      session = saved_session
      expect(access.prepare_wait(session.id, session: session, question_id: "q1").baseline.question_id).to eq("q1")

      created = access.prepare_wait(session.id, session: session, created: true)
      expect(created).to have_attributes(cursor: nil, own_turn: nil, live: false)
      expect(created.baseline).to eq(Samagotchi::ReplyWait.baseline_of(session, question_id: nil))
    end

    # Read after the create (chi web's prepare route for a remote --new), the
    # first turn may have ended already: its end is the answer, not the
    # baseline's.
    it "takes no ended turn into a just-created session's baseline" do
      session = saved_session
      session.last_turn = Samagotchi::LastTurn.new(outcome: "failed", ended_at: "2026-10-23T10:00:00Z")
      session.save(state_dir: tmpdir)

      expect(access.prepare_wait(session.id, created: true).baseline.last_turn).to be_nil
    end
  end

  it "answers nil when no worker runs the session" do
    session = saved_session
    expect(access.answer(session.id, question_id: "q", selected: [], freeform: nil, client_id: "cli")).to be_nil
    expect(access.dismiss(session.id, question_id: "q")).to be_nil
  end

  it "posts an answer again after a 408" do
    session = saved_session
    client = instance_double(Samagotchi::BridgeClient)
    timeout = Struct.new(:status).new(408)
    ok = Struct.new(:status).new(200)
    allow(Samagotchi::WorkerLink).to receive(:client).and_return(client)
    allow(client).to receive(:dismiss_question).and_return(timeout, ok)

    expect(access.dismiss(session.id, question_id: "q").status).to eq(200)
    expect(client).to have_received(:dismiss_question).twice
  end
end
