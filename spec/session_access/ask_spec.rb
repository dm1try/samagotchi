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
  # last one again after), and writes its turn's reply when +reply+ is set;
  # each takes +takes+ seconds of the clock.
  def worker(*results, reply: nil, takes: 0)
    allow(access).to receive(:deliver_turn) do |id, **options|
      deliveries << [id, options]
      clock[0] += takes
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

  describe "with a request_id" do
    let(:key) { Samagotchi::SessionInbox.enqueued_id_for("ask:r1") }

    def known(known_turn, last_turn_id: nil)
      Samagotchi::SessionAccess::WaitStart.new(cursor: nil, baseline: nil, own_turn: nil, known_turn: known_turn,
                                               running: false, live: true, settled: false, last_turn_id: last_turn_id)
    end

    it "delivers with the key's enqueued id when the session doesn't know that turn" do
      session = make
      allow(access).to receive(:prepare_wait).and_return(known(false))
      worker(accepted(key), reply: "first")

      reply = call(session.id, request_id: "r1")
      expect(access).to have_received(:prepare_wait).with(session.id, session: anything, turn: key)
      expect(deliveries.map(&:last)).to contain_exactly(include(enqueued_id: key))
      expect(reply).to have_attributes(rebound: false)
      expect(reply.result.text).to eq("first")
    end

    it "sends nothing and waits on that turn, queued as the first copy was, when the session knows it (rebound)" do
      session = make
      allow(access).to receive(:prepare_wait).and_return(known(true, last_turn_id: key))
      waits = []
      allow(access).to receive(:wait_reply) do |_id, **options|
        waits << options
        Samagotchi::ReplyWait::Result.new(status: :done, text: "first")
      end
      worker(accepted("t9"))

      reply = call(session.id, request_id: "r1")
      expect(deliveries).to be_empty
      expect(reply).to have_attributes(rebound: true)
      expect(reply.result.text).to eq("first")
      expect(waits).to contain_exactly(include(turn: key, queued: true, ended_before: true))
    end

    it "keeps queued false on a rebind of a plain (queue: false) ask" do
      session = make
      allow(access).to receive(:prepare_wait).and_return(known(true))
      waits = []
      allow(access).to receive(:wait_reply) do |_id, **options|
        waits << options
        Samagotchi::ReplyWait::Result.new(status: :timeout)
      end

      worker(accepted("t9"))

      call(session.id, request_id: "r1", queue: false)
      expect(deliveries).to be_empty
      expect(waits).to contain_exactly(include(turn: key, queued: false, ended_before: false))
    end

    it "resends with the same enqueued id after a continue took the link" do
      old = make
      newer = make
      heads = [old.id, old.id, newer.id].map { |id| Samagotchi::SessionInbox::Resolved.new(id: id, asked: old.id, via: :same) }
      allow(access).to receive(:head) { heads.size > 1 ? heads.shift : heads.first }
      continued = Samagotchi::SessionManager::DeliverResult.new(
        status: :refused, code: 409, ack: { "error" => Samagotchi::SessionManager::DeliverResult::CONTINUED, "detail" => "c" }
      )
      worker(continued, accepted(key), reply: "there")

      expect(call(old.id, request_id: "r1").result.text).to eq("there")
      expect(deliveries.map { |id, options| [id, options[:enqueued_id]] }).to eq([[old.id, key], [newer.id, key]])
    end

    it "sends no enqueued_id without one" do
      session = make
      worker(accepted("t1"), reply: "ok")
      call(session.id)
      expect(deliveries.first.last).not_to have_key(:enqueued_id)
    end
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

  describe "/continue yes with a continue offer standing" do
    def start(own_turn:, live: true, running: false)
      Samagotchi::SessionAccess::WaitStart.new(cursor: nil, baseline: nil, own_turn: own_turn, known_turn: nil,
                                               running: running, live: live, settled: false, last_turn_id: nil)
    end

    def offer(own_turn:, live: true)
      allow(access).to receive(:prepare_wait).and_return(start(own_turn: own_turn, live: live))
      waits = []
      allow(access).to receive(:wait_reply) do |_id, **options|
        waits << options
        Samagotchi::ReplyWait::Result.new(status: :timeout)
      end
      worker(accepted(nil, "command_id" => "c1"))
      waits
    end

    it "waits on the continued turn (the offer's own_turn), not Ran, and its token binds that turn" do
      session = make
      waits = offer(own_turn: "t1")

      reply = call(session.id, prompt: "/continue yes", timeout: 0.2)
      expect(reply).to be_a(described_class::Reply)
      expect(reply.result.status).to eq(:timeout)
      expect(waits).to contain_exactly(include(turn: "t1"))
      token_session, target = Samagotchi::SessionAccess::Exchange::Token.load(reply.token)
      expect(token_session).to eq(session.id)
      expect(target).to have_attributes(turn: "t1")
    end

    it "is still Ran with no offer standing (no own_turn)" do
      session = make
      offer(own_turn: nil)
      expect(call(session.id, prompt: "/continue yes")).to eq(described_class::Ran.new(session_id: session.id))
    end

    it "is still Ran when no worker ran the session at the wait's start (the offer is the worker's memory)" do
      session = make
      offer(own_turn: "t1", live: false)
      expect(call(session.id, prompt: "/continue yes")).to eq(described_class::Ran.new(session_id: session.id))
    end

    it "is still Ran for another command" do
      session = make
      offer(own_turn: "t1")
      expect(call(session.id, prompt: "/model x")).to eq(described_class::Ran.new(session_id: session.id))
    end
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

    # The continue's wait ends MIN_SLICE before the cap: refused in time.
    looks.replace([continuing, continuing, continuing, done])
    started = clock[0]
    expect(call(session.id, timeout: 30, cap: 1.8)).to have_attributes(kind: :continuing)
    expect(clock[0] - started).to be <= 1.8 - described_class::MIN_SLICE
    expect(slices.size).to eq(1)
  end

  it "draws the delivery's own time from the cap: a slow one leaves a shorter slice (never under a second)" do
    session = make
    worker(accepted("t7"), takes: 3.0)
    slices = []
    allow(access).to receive(:wait_reply) do |_id, **options|
      slices << options[:timeout]
      Samagotchi::ReplyWait::Result.new(status: :timeout)
    end

    call(session.id, timeout: 30, cap: 5)
    expect(slices).to eq([2.0])
  end

  it "sends no second delivery when a continue takes the link after the first used up the cap" do
    old = make
    newer = make
    heads = [old.id, newer.id].map { |id| Samagotchi::SessionInbox::Resolved.new(id: id, asked: old.id, via: :same) }
    allow(access).to receive(:head) { heads.size > 1 ? heads.shift : heads.first }
    continued = Samagotchi::SessionManager::DeliverResult.new(
      status: :refused, code: 409, ack: { "error" => Samagotchi::SessionManager::DeliverResult::CONTINUED, "detail" => "continued" }
    )
    worker(continued, accepted("t8"), takes: 4.5)

    expect(call(old.id, cap: 5)).to have_attributes(kind: :continuing, session_id: old.id)
    expect(deliveries.size).to eq(1)
  end

  it "lets the backend's refusal raise (a one-turn chi run owns it)" do
    session = make
    allow(access).to receive(:deliver_turn).and_raise(Samagotchi::SessionManager::OwnedByTUI.new(session.id))

    expect { call(session.id) }.to raise_error(Samagotchi::SessionManager::OwnedByTUI)
  end

  it "is canceled, nothing sent, when cancelled: turns true during a continue's wait (a server stop cuts the pauses)" do
    session = make
    continuing = Samagotchi::SessionInbox::Resolved.new(id: session.id, asked: session.id, via: :continuing)
    allow(access).to receive(:head).and_return(continuing)
    worker(accepted("t9"))
    stopped = -> { clock[0] >= 100.5 }
    exchange = Samagotchi::SessionAccess::Exchange.new(access, pause: ->(s) { clock[0] += s }, continuing_wait: 2.0,
                                                               continuing_poll: 0.5, clock: -> { clock[0] }, cancelled: stopped)

    outcome = described_class.new(access, exchange: exchange)
                             .call(session.id, prompt: "hi", client_id: "web:unnamed", queue: true, timeout: 1, cap: 35,
                                               cancelled: stopped)
    expect(outcome).to have_attributes(kind: :canceled, session_id: session.id)
    expect(clock[0]).to eq(100.5)
    expect(deliveries).to be_empty
  end

  it "passes cancelled: to the wait (true once the message went in)" do
    session = make(status: "running")
    own(session)
    worker(accepted("t6"))

    expect(call(session.id, timeout: 5, cancelled: -> { deliveries.any? }).result.status).to eq(:canceled)
  end

  describe "#agent_line" do
    def with_parent_answers(value)
      make.tap do |s|
        s.parent_answers = value
        s.save(state_dir: tmpdir)
      end
    end

    it "sends a plain line as chi send's and a /continue yes as chi answer's" do
      session = make
      expect(ask.agent_line("hello", session: session)).to eq(Samagotchi::ClientId::CLI_SEND)
      expect(ask.agent_line("/continue yes", session: session)).to eq(Samagotchi::ClientId::CLI_ANSWER)
    end

    it "holds /continue yes to parent_answers with a tty stdin and no agent markers (no read of the process)" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow(ENV).to receive(:fetch).and_call_original
      Samagotchi::Guardrails::ParentApprovals::AGENT_MARKERS.each { |key| allow(ENV).to receive(:fetch).with(key, "").and_return("") }
      expect(Samagotchi::Guardrails::ParentApprovals.parent_process?).to be(false)
      hard = with_parent_answers("hard")

      refused = ask.agent_line("/continue yes", session: hard)
      expect(refused).to have_attributes(kind: :parent_refused, session_id: hard.id)
      expect(refused.message).to eq(Samagotchi::SendCommand::ParentGate.continue_refusal_for(["hard"]))
      # Any target refusing is enough (the asked session and its chain's newest link).
      expect(ask.agent_line("/continue yes", session: [make, hard])).to have_attributes(kind: :parent_refused)
    end

    it "refuses a /parent-answers line that loosens a target's own value, and lets one that tightens through" do
      hard = with_parent_answers("hard")
      expect(ask.agent_line("/parent-answers soft", session: hard))
        .to have_attributes(kind: :parent_refused, message: Samagotchi::ParentAnswersCommand::REFUSED)
      expect(ask.agent_line("/parent-answers hard", session: with_parent_answers("soft"))).to eq(Samagotchi::ClientId::CLI_SEND)
    end

    it "fails closed on config.yml's value when no target was read" do
      expect(ask.agent_line("hello", session: nil)).to eq(Samagotchi::ClientId::CLI_SEND)
      values = []
      allow(Samagotchi::SendCommand::ParentGate).to receive(:continue_refusal_for) { |v| values << v and nil }
      ask.agent_line("/continue yes", session: [])
      expect(values).to eq([[nil]])
    end
  end

  describe "#answer" do
    let(:question) { { id: "q1", question: "Go?", options: %w[Yes No] } }

    def bridge(status, json = nil)
      Samagotchi::BridgeClient::Response.new(status: status, body: json ? JSON.generate(json) : "")
    end

    def answer_with(reply = nil, raising: nil, session: nil, question_id: "q1", timeout: 0.2)
      session ||= make(status: "running", pending_question: question).tap { |s| own(s) }
      posted = []
      allow(access).to receive(:answer) do |id, **options|
        posted << [id, options]
        raise raising if raising

        reply
      end
      outcome = ask.answer(session.id, question_id: question_id, selected: ["Yes"], freeform: nil,
                                       client_id: Samagotchi::ClientId::CLI_ANSWER, timeout: timeout)
      [outcome, posted, session]
    end

    it "answers, then waits: done with the reply of the turn the question was about" do
      session = make(status: "running", pending_question: question)
      own(session)
      allow(access).to receive(:wait_reply).and_return(Samagotchi::ReplyWait::Result.new(status: :done, text: "after"))

      outcome, posted = answer_with(bridge(200, { "ok" => true }), session: session)
      expect(posted).to eq([[session.id, { question_id: "q1", selected: ["Yes"], freeform: nil,
                                           client_id: Samagotchi::ClientId::CLI_ANSWER }]])
      expect(outcome).to have_attributes(session_id: session.id, answered_here: true, token: nil)
      expect(outcome.result).to have_attributes(status: :done, text: "after")
    end

    it "answers, then hands a token when the turn still runs past the slice" do
      outcome, = answer_with(bridge(200))
      expect(outcome.result.status).to eq(:timeout)
      token_session, = Samagotchi::SessionAccess::Exchange::Token.load(outcome.token)
      expect(token_session).to eq(outcome.session_id)
    end

    it "still waits when the question is no longer open (409), answered_here false" do
      outcome, = answer_with(bridge(409, { "error" => "question_not_pending" }))
      expect(outcome).to have_attributes(answered_here: false)
      expect(outcome.result.status).to eq(:timeout)
    end

    it "draws the post and the wait from one cap: the post gets what's left but MIN_SLICE, the wait the rest" do
      session = make(status: "running", pending_question: question)
      own(session)
      slices = []
      allow(access).to receive(:wait_reply) do |_id, **options|
        slices << options[:timeout]
        Samagotchi::ReplyWait::Result.new(status: :timeout)
      end
      posted = []
      allow(access).to receive(:answer) do |id, **options|
        posted << [id, options]
        clock[0] += 20
        bridge(200)
      end
      ask.answer(session.id, question_id: "q1", selected: ["Yes"], freeform: nil,
                             client_id: Samagotchi::ClientId::CLI_ANSWER, timeout: 25, cap: 35)
      expect(posted.last.last[:within]).to eq(35 - described_class::MIN_SLICE)
      expect(slices).to eq([15.0])

      # A post that took it all still leaves the wait its MIN_SLICE.
      allow(access).to receive(:answer) do
        clock[0] += 40
        bridge(200)
      end
      ask.answer(session.id, question_id: "q1", selected: ["Yes"], freeform: nil,
                             client_id: Samagotchi::ClientId::CLI_ANSWER, timeout: 25, cap: 35)
      expect(slices.last).to eq(described_class::MIN_SLICE)
    end

    it "posts nothing and still waits for a running session whose question is another" do
      outcome, posted = answer_with(bridge(200), question_id: "q0")
      expect(posted).to be_empty
      expect(outcome).to have_attributes(answered_here: false)
    end

    it "refuses no_question for an idle session with no such question (no endless tokens)" do
      outcome, posted = answer_with(bridge(200), session: make, question_id: "q9")
      expect(outcome).to have_attributes(kind: :no_question)
      expect(outcome.message).to include("no question q9 waits", "nothing to answer")
      expect(posted).to be_empty
    end

    {
      "no worker (nil)" => [nil, :not_live, "no worker runs session"],
      "the Bridge's secret refusal" => [:secret, :bridge_secret, "didn't name its secret"],
      "409 not_dismissable" => [[409, { "error" => "not_dismissable", "detail" => "answer it" }], :not_dismissable, "answer it"],
      "400" => [[400, { "detail" => "no option Maybe" }], :invalid_answer, "no option Maybe"],
      "403" => [[403, { "detail" => "parent may not allow" }], :parent_refused, "parent may not allow"],
      "408" => [[408], :late, "the question is still open"],
      "404 unknown_session" => [[404, { "error" => "unknown_session" }], :not_live, "no worker runs session"],
      "404 otherwise" => [[404, { "error" => "not_found" }], :stale_worker, "runs an older chi"],
      "500" => [[500, { "detail" => "boom" }], :failed, "the worker answered 500: boom"]
    }.each do |name, (given, kind, words)|
      it "refuses #{kind} for #{name}" do
        reply = case given
                when nil then nil
                when :secret then bridge(403, { "error" => Samagotchi::BridgeSecret::ERROR })
                else bridge(*given)
                end
        outcome, = answer_with(reply)
        expect(outcome).to have_attributes(kind: kind)
        expect(outcome.message).to include(words)
      end
    end

    it "refuses late on a timeout and failed on a socket error" do
      expect(answer_with(raising: Errno::ETIMEDOUT).first).to have_attributes(kind: :late)
      failed = answer_with(raising: Errno::ECONNREFUSED).first
      expect(failed).to have_attributes(kind: :failed)
      expect(failed.message).to include("ECONNREFUSED")
    end
  end
end
