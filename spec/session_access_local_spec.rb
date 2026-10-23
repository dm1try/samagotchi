# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_access/local"
require "samagotchi/session_manager"
require "samagotchi/reply_wait"
require "socket"

# SessionAccess::Local: this machine's sessions, the calls the session
# commands made before the seam (their own specs cover the behaviour).
RSpec.describe Samagotchi::SessionAccess::Local do
  let(:tmpdir) { Dir.mktmpdir("session-access") }
  let(:access) { described_class.new(state_dir: tmpdir) }

  after { FileUtils.rm_rf(tmpdir) }

  def saved_session(**attrs)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap do |session|
      attrs.each { |key, value| session.public_send(:"#{key}=", value) }
      session.save(state_dir: tmpdir)
    end
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
      Samagotchi::WorkerSidecar.new(port: server.local_address.ip_port, session_id: session.id, epoch: epoch)
                               .write(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir))
    end

    it "wakes nothing for a live worker, else resumes and waits; a Bridge that doesn't come is no sidecar" do
      session = saved_session
      allow(Samagotchi::SessionManager).to receive(:resume_session)
      allow(Samagotchi::BridgeClient).to receive(:wait_for).and_return(nil)

      expect(access.wake(session.id, wait: 0.1)).to eq(Samagotchi::SessionAccess::Woken.new(woke: true, sidecar: nil))

      sidecar_for(session)
      expect(access.wake(session.id, wait: 0.1)).to have_attributes(woke: false, sidecar: have_attributes(epoch: "ab12cd34"))
      expect(Samagotchi::SessionManager).to have_received(:resume_session).once
    end

    it "refuses a leftover scratch session and an unknown one" do
      scratch = saved_session(scratch: true)

      expect { access.wake(scratch.id, wait: 0.1) }
        .to raise_error(Samagotchi::SessionAccess::Refused, Samagotchi::LaunchMode::SCRATCH_LEFTOVER) { |e| expect(e.code).to eq("scratch") }
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
    allow(Samagotchi::BridgeClient).to receive(:discover).and_return(client)
    allow(client).to receive(:dismiss_question).and_return(timeout, ok)

    expect(access.dismiss(session.id, question_id: "q").status).to eq(200)
    expect(client).to have_received(:dismiss_question).twice
  end
end
