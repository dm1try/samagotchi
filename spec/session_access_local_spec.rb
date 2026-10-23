# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_access/local"
require "samagotchi/session_manager"
require "samagotchi/reply_wait"

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
