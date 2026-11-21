# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/session_inbox"
require "samagotchi/owner_lock"
require "samagotchi/archive_store"
require "samagotchi/session_access/local"
require "samagotchi/session_access/ask"

# SessionAccess::Ask: one message in, its answer out (POST …/ask, the MCP
# server's ask), as values. A real Local backend over a temp state dir; the
# worker is a double of its delivery (#deliver_turn), which writes the turn's
# reply file when the spec says so.
RSpec.describe Samagotchi::SessionAccess::Ask do
  let(:tmpdir) { Dir.mktmpdir("ask") }
  let(:access) { Samagotchi::SessionAccess::Local.new(state_dir: tmpdir) }
  let(:clock) { [100.0] }
  let(:exchange) do
    Samagotchi::SessionAccess::Exchange.new(access, pause: ->(s) { clock[0] += s }, continuing_wait: 2.0,
                                                    continuing_poll: 0.5, clock: -> { clock[0] })
  end
  let(:ask) { described_class.new(access, exchange: exchange) }
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

  def accepted(turn, ack = {})
    Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge, ack: { "enqueued_id" => turn, **ack })
  end

  # The worker double: each delivery answers the next of +results+ (the
  # last one again after), and writes its turn's reply when +reply+ is set.
  def worker(*results, reply: nil)
    allow(access).to receive(:deliver_turn) do |id, **options|
      deliveries << [id, options]
      result = results.size > 1 ? results.shift : results.first
      if reply && result.accepted? && result.enqueued_id
        Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(id, state_dir: tmpdir), reply,
                                              enqueued_id: result.enqueued_id)
      end
      result
    end
  end

  def call(given, prompt: "hi", queue: true, timeout: 1, cap: 35, client_id: "web:unnamed", **more)
    ask.call(given, prompt: prompt, client_id: client_id, queue: queue, timeout: timeout, cap: cap, **more)
  end

  it "answers an idle session's reply to the message, queued as its own turn (the default), following the head" do
    session = make
    worker(accepted("t1"), reply: "the answer")

    reply = call(session.id[0, 8])

    expect(reply).to be_a(described_class::Reply)
    expect(reply).to have_attributes(session_id: session.id, asked: session.id, token: nil)
    expect(reply.result).to have_attributes(status: :done, text: "the answer", turn_id: "t1")
    expect(deliveries).to eq([[session.id, { prompt: "hi", client_id: "web:unnamed", images: [],
                                             delivery: Samagotchi::Delivery::QUEUE, follow: true }]])
  end

  it "sends a plain message with queue: false" do
    session = make
    worker(accepted("t1"), reply: "ok")

    expect(call(session.id, queue: false).result.status).to eq(:done)
    expect(deliveries.first.last).to include(delivery: nil)
  end

  it "refuses a running turn with queue: false (busy), and a question that waits either way (waiting); nothing sent" do
    running = make(status: "running")
    own(running)
    waiting = make(status: "running", pending_question: { id: "q1", question: "Go?", options: %w[Yes No] })
    own(waiting)
    worker(accepted("t1"))

    busy = call(running.id, queue: false)
    expect(busy).to have_attributes(kind: :busy, session_id: running.id)
    expect(busy.busy.error).to eq("busy")
    expect(call(waiting.id).busy).to have_attributes(error: "waiting", question: have_attributes(id: "q1"))
    expect(deliveries).to be_empty
  end

  it "is unknown for no such session, and for an ambiguous prefix with the AmbiguousId" do
    missing = call("feedbeef")
    expect(missing).to have_attributes(kind: :unknown)
    expect(missing.error).to be_a(Samagotchi::Session::NotFound)

    a = make
    b = make
    b_id = "#{a.id[0, 4]}#{b.id[4..]}"
    File.rename(Samagotchi::Session.session_file(b.id, state_dir: tmpdir), Samagotchi::Session.session_file(b_id, state_dir: tmpdir))
    expect(call(a.id[0, 4]).error).to be_a(Samagotchi::Session::AmbiguousId)
  end

  it "goes to a continued chain's newest link, naming the id asked" do
    old = make
    Samagotchi::ArchiveStore.archive(old.id, state_dir: tmpdir)
    newer = make.tap do |s|
      s.continues = old.id
      s.save(state_dir: tmpdir)
    end
    worker(accepted("t2"), reply: "from the new link")

    reply = call(old.id)
    expect(reply).to have_attributes(session_id: newer.id, asked: old.id)
    expect(reply.result.text).to eq("from the new link")
  end

  it "refuses a continue still in flight past the continue wait" do
    session = make
    continuing = Samagotchi::SessionInbox::Resolved.new(id: "7b2d41aa-0000-4000-8000-000000000000", asked: session.id,
                                                        via: :continuing)
    allow(access).to receive(:head).and_return(continuing)

    expect(call(session.id)).to have_attributes(kind: :continuing, session_id: session.id,
                                                message: continuing.continuing_refusal)
    expect(clock[0]).to be >= 102.0
  end

  describe "when a continue takes the link after it was located" do
    let(:continued) do
      Samagotchi::SessionManager::DeliverResult.new(
        status: :refused, code: 409, ack: { "error" => Samagotchi::SessionManager::DeliverResult::CONTINUED,
                                            "detail" => "continued meanwhile" }
      )
    end

    it "locates it again and sends to the new link" do
      old = make
      newer = make
      heads = [old.id, old.id, newer.id].map { |id| Samagotchi::SessionInbox::Resolved.new(id: id, asked: old.id, via: :same) }
      allow(access).to receive(:head) { heads.size > 1 ? heads.shift : heads.first }
      worker(continued, accepted("t3"), reply: "there")

      reply = call(old.id)
      expect(reply).to have_attributes(session_id: newer.id, asked: old.id)
      expect(deliveries.map(&:first)).to eq([old.id, newer.id])
    end

    it "refuses with the delivery's words once the continue wait is over" do
      old = make
      worker(continued)

      expect(call(old.id)).to have_attributes(kind: :continuing, session_id: old.id, message: "refused: continued meanwhile")
      expect(deliveries.size).to eq(1)
    end
  end

  it "answers a refused delivery as is (an older worker without the queue)" do
    session = make
    refused = Samagotchi::SessionManager::DeliverResult.new(status: :refused, code: 409,
                                                            ack: Samagotchi::Delivery::QUEUE_UNAVAILABLE)
    worker(refused)

    expect(call(session.id)).to have_attributes(kind: :undelivered, result: refused)
  end

  it "answers Ran for a line the worker ran as a session command" do
    session = make
    worker(accepted(nil, "command_id" => "c1"))

    expect(call(session.id, prompt: "/model x")).to eq(described_class::Ran.new(session_id: session.id))
  end

  it "answers a still-running turn with status timeout and a token for the next wait" do
    session = make(status: "running")
    own(session)
    worker(accepted("t4"))

    reply = call(session.id, timeout: 0.2, cap: 0.2)
    expect(reply.result.status).to eq(:timeout)
    token_session, target = Samagotchi::SessionAccess::Exchange::Token.load(reply.token)
    expect(token_session).to eq(session.id)
    expect(target).to have_attributes(turn: "t4", queued: true)
  end

  it "keeps a continue in flight and the wait's slice within one cap (the slice never under a second)" do
    session = make
    continuing = Samagotchi::SessionInbox::Resolved.new(id: session.id, asked: session.id, via: :continuing)
    done = Samagotchi::SessionInbox::Resolved.new(id: session.id, asked: session.id, via: :same)
    looks = [continuing, continuing, continuing, done]
    allow(access).to receive(:head) { looks.size > 1 ? looks.shift : looks.first }
    worker(accepted("t5"))
    slices = []
    allow(access).to receive(:wait_reply) do |_id, **options|
      slices << options[:timeout]
      Samagotchi::ReplyWait::Result.new(status: :timeout)
    end

    call(session.id, timeout: 30, cap: 5)
    expect(slices).to eq([5 - 1.5])

    looks.replace([continuing, continuing, continuing, done])
    call(session.id, timeout: 30, cap: 1.8)
    expect(slices.last).to eq(described_class::MIN_SLICE)
  end

  it "lets the backend's refusal raise (a one-turn chi run owns it)" do
    session = make
    allow(access).to receive(:deliver_turn).and_raise(Samagotchi::SessionManager::OwnedByTUI.new(session.id))

    expect { call(session.id) }.to raise_error(Samagotchi::SessionManager::OwnedByTUI)
  end

  it "passes cancelled: to the wait" do
    session = make(status: "running")
    own(session)
    worker(accepted("t6"))

    expect(call(session.id, timeout: 5, cancelled: -> { true }).result.status).to eq(:canceled)
  end
end
