# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/session_inbox"
require "samagotchi/owner_lock"
require "samagotchi/pending_question"
require "samagotchi/session_access/local"
require "samagotchi/tools/ask_session"

# ask_session on a real Local backend over a temp state dir; the worker is
# a double of its delivery (#deliver_turn), as the MCP tools' spec's.
RSpec.describe Samagotchi::Tools::AskSession do
  let(:tmpdir) { Dir.mktmpdir("ask-session") }
  let(:access) { Samagotchi::SessionAccess::Local.new(state_dir: tmpdir) }
  let(:asker) { make }
  let(:cancelled) { [false] }
  let(:peers) do
    Samagotchi::Tools::Peers.new(session_id: asker.id, cwd: tmpdir, state_dir: tmpdir, cancelled: -> { cancelled[0] })
  end
  let(:deliveries) { [] }
  let(:locks) { [] }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(status: "idle", pending_question: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap do |s|
      s.status = status
      s.pending_question = pending_question
      s.save(state_dir: tmpdir)
      FileUtils.mkdir_p(dir_of(s))
    end
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
  def own(session) = locks << Samagotchi::OwnerLock.acquire(dir_of(session), kind: "worker")

  def worker(turn: "t1", reply: nil, result: nil)
    allow(access).to receive(:deliver_turn) do |id, **options|
      deliveries << [id, options]
      Samagotchi::SessionInbox.write_output(dir_of(Samagotchi::Session.load(id, state_dir: tmpdir)), reply, enqueued_id: turn) if reply
      result || Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge, ack: { "enqueued_id" => turn })
    end
  end

  def ask(question = "What did you find?", session: nil, token: nil)
    described_class.call(question, session: session, token: token, peers: peers, access: access, slice: 0.3, cap: 2)
  end

  it "asks as session:<this id8>, queued as its own turn, and answers with the reply" do
    asked = make
    worker(reply: "the parser is fixed")

    expect(ask(session: asked.id[0, 8])).to eq("Session #{asked.id[0, 8]} answered:\nthe parser is fixed")
    expect(deliveries.first.last).to include(client_id: "session:#{asker.id[0, 8]}", prompt: "What did you find?",
                                             delivery: Samagotchi::Delivery::QUEUE)
    # A request id: a retried call in the same turn waits on the first one's turn.
    expect(deliveries.first.last[:enqueued_id]).to match(Samagotchi::SessionInbox::ENQUEUED_ID_NAME)
  end

  # A worker that answers each question under the id it was sent with.
  def answering(*replies)
    allow(access).to receive(:deliver_turn) do |id, **options|
      deliveries << [id, options]
      Samagotchi::SessionInbox.write_output(dir_of(Samagotchi::Session.load(id, state_dir: tmpdir)), replies.shift,
                                            enqueued_id: options[:enqueued_id])
      Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge, ack: { "enqueued_id" => options[:enqueued_id] })
    end
  end

  it "asks the same question again once its first turn ended in this turn, never replaying the old answer" do
    asked = make
    answering("not yet", "done now")

    expect(ask("Are you done?", session: asked.id)).to end_with("not yet")
    expect(ask("Are you done?", session: asked.id)).to end_with("done now")
    expect(deliveries.size).to eq(2)
    expect(deliveries.map { |_id, options| options[:enqueued_id] }.uniq.size).to eq(2)
  end

  it "waits on the first turn of a question asked again while that turn still runs (a retry asks once)" do
    asked = make(status: "running")
    own(asked)
    # A busy worker: the question waits queued as an input file under its id.
    allow(access).to receive(:deliver_turn) do |id, **options|
      deliveries << [id, options]
      Samagotchi::SessionInbox.write_input(dir_of(asked), prompt: options[:prompt], client_id: options[:client_id],
                                                          enqueued_id: options[:enqueued_id], delivery: options[:delivery])
      Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge, ack: { "enqueued_id" => options[:enqueued_id] })
    end

    expect(ask("Slow?", session: asked.id)).to include("still answering")
    expect(ask("Slow?", session: asked.id)).to include("still answering")
    expect(deliveries.size).to eq(1)
  end

  it "gives a token while the turn still runs, which a second call (token only) waits on to the answer" do
    asked = make(status: "running")
    own(asked)
    worker(turn: "t2")

    running = ask(session: asked.id)
    token = running[/token: (\S+)/, 1]
    expect(running).to start_with("Session #{asked.id[0, 8]} is still answering. Call ask_session again with token: ")
    Samagotchi::SessionInbox.write_output(dir_of(asked), "later", enqueued_id: "t2")
    expect(ask(nil, token: token)).to eq("Session #{asked.id[0, 8]} answered:\nlater")
  end

  it "says a session that waits on its user's question is not answered" do
    pending = Samagotchi::PendingQuestion.new(id: "q1", question: "Which file?", options: %w[a b], multi_select: false)
    asked = make(status: "running", pending_question: pending)
    own(asked)
    worker

    expect(ask(session: asked.id)).to eq("Session #{asked.id[0, 8]} waits on a question for its user: not answered. " \
                                         "Tell your user; it waits in chi web (or chi --attach #{asked.id[0, 8]})")
    expect(deliveries).to be_empty
  end

  it "says so when a question for its user appears while it waits" do
    asked = make(status: "running")
    own(asked)
    worker(turn: "t4")
    pending = Samagotchi::PendingQuestion.new(id: "q2", question: "Which?", options: %w[a b], multi_select: false)
    allow(access).to receive(:wait_reply).and_return(Samagotchi::ReplyWait::Result.new(status: :waiting_for_answer, question: pending))
    expect(ask(session: asked.id)).to eq("Session #{asked.id[0, 8]} waits on a question for its user: not answered. " \
                                         "Tell your user; it waits in chi web (or chi --attach #{asked.id[0, 8]})")
  end

  it "refuses before sending: no session, itself, a link continued into it, a command line, a question too big" do
    worker
    expect(ask(session: nil)).to start_with("Error: give the session to ask")
    expect(ask(session: asker.id)).to eq("Error: #{asker.id[0, 8]} is this session; ask_session is for other sessions")
    continued = make
    allow(Samagotchi::SessionInbox::Head).to receive(:resolve).and_call_original
    allow(Samagotchi::SessionInbox::Head).to receive(:resolve).with(:send, continued.id, state_dir: tmpdir)
                                                             .and_return(Struct.new(:id).new(asker.id))
    expect(ask(session: continued.id)).to eq("Error: #{continued.id[0, 8]} was continued into this session; " \
                                             "ask_session is for other sessions")
    other = make
    expect(ask("/model x", session: other.id)).to eq("Error: a question can't start with ! or /: ask it in words")
    expect(ask("!ls", session: other.id)).to eq("Error: a question can't start with ! or /: ask it in words")
    expect(ask("x" * (Samagotchi::SessionInbox::NOTE_MAX_BYTES + 1), session: other.id)).to start_with("Error: the question is")
    expect(ask(session: "nope")).to end_with("(list_sessions shows them)")
    expect(deliveries).to be_empty
  end

  it "says the worker's refusal in its own words: an older worker, a stopped session, the visitor cap" do
    asked = make
    worker(result: Samagotchi::SessionManager::DeliverResult.new(status: :refused, code: 409,
                                                                 ack: Samagotchi::Delivery::ASK_UNAVAILABLE))
    expect(ask(session: asked.id)).to eq("Error: session #{asked.id[0, 8]}: failed: " \
                                         "#{Samagotchi::Delivery::ASK_UNAVAILABLE["detail"]}")

    capped = make
    worker(turn: "t3")
    allow(access).to receive(:wait_reply).and_return(
      Samagotchi::ReplyWait::Result.new(status: :no_reply, outcome: "canceled", cancel_reason: "max_wakes")
    )
    expect(ask(session: capped.id)).to eq("Error: session #{capped.id[0, 8]}: the turn was refused " \
                                          "(#{Samagotchi::ParentReport::REFUSED_LINES.fetch("max_wakes")}); no turn ran for it")
  end

  it "asks nothing once this turn is canceled, and turns a one-turn run's hold or a scratch session into its error" do
    asked = make
    worker
    cancelled[0] = true
    expect(ask(session: asked.id)).to eq("Error: the question was not asked (this turn was canceled)")
    cancelled[0] = false
    allow(access).to receive(:deliver_turn).and_raise(Samagotchi::SessionManager::ScratchSession.new(asked.id))
    expect(ask(session: asked.id)).to eq("Error: #{Samagotchi::Session::SCRATCH_REFUSED}")
    allow(access).to receive(:deliver_turn).and_raise(Samagotchi::SessionManager::OwnedByTUI.new(asked.id))
    expect(ask(session: asked.id)).to eq("Error: a one-turn chi run holds that session now; it can't take a question")
  end

  it "never delivers to itself, also when a continue moved the target onto it" do
    exchange = described_class::NotSelf.new(instance_double(Samagotchi::SessionAccess::Exchange), asker.id)
    target = Struct.new(:id).new(asker.id)
    attempted = exchange.attempt(target, "q", client_id: "session:x")
    expect(attempted.result).to have_attributes(status: :refused)
    expect(attempted.result.refusal_text).to eq("failed: #{asker.id[0, 8]} is this session now (continued into it)")
  end
end
