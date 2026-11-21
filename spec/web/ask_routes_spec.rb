# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/owner_lock"
require "samagotchi/bridge_client"

# The thin-client routes (Web::AskRoutes): POST …/ask's answers (its values
# are SessionAccess::Ask's, ask_spec), the wait token on POST …/wait, wait on
# POST …/answer and a create's token. The worker is a double of
# SessionManager.deliver_turn that writes the turn's reply when asked to.
RSpec.describe Samagotchi::Web::App, "ask routes" do
  around do |example|
    Dir.mktmpdir("web-ask") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    ensure
      @locks&.each(&:release)
    end
  end

  let(:state_dir) { File.join(@tmp, "state").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:folder) { File.join(@tmp, "proj").tap { |dir| FileUtils.mkdir_p(File.join(dir, ".git")) } }
  let(:app) do
    described_class.new(manager: Samagotchi::SessionManager, state_dir: state_dir, bridge_wait_timeout: 0,
                        wait_poll_interval: 0.01)
  end
  let(:deliveries) { [] }
  let(:token_module) { Samagotchi::SessionAccess::Exchange::Token }

  before { allow(Process).to receive(:spawn).and_return(12_345) }

  def call(path, method: "POST", body: nil)
    env = Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", method: method,
                                          input: body.nil? ? nil : JSON.generate(body))
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.to_a.join)]
  end

  def ask(session_or_id, body) = call("/api/sessions/#{session_or_id.is_a?(String) ? session_or_id : session_or_id.id}/ask", body: body)
  def wait(id, body) = call("/api/sessions/#{id}/wait", body: body)

  def make(status: "idle", pending_question: nil, parent_answers: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: folder).tap do |s|
      s.status = status
      s.pending_question = pending_question
      s.parent_answers = parent_answers
      s.save(state_dir: state_dir)
      FileUtils.mkdir_p(dir_of(s))
    end
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)

  def own(session, kind: "worker")
    (@locks ||= []) << Samagotchi::OwnerLock.acquire(dir_of(session), kind: kind)
  end

  def accepted(turn, ack = {})
    Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge, ack: { "enqueued_id" => turn, **ack })
  end

  def worker(result, reply: nil)
    allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |id, **options|
      deliveries << [id, options]
      if reply && result.accepted? && result.enqueued_id
        Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(id, state_dir: state_dir), reply,
                                              enqueued_id: result.enqueued_id)
      end
      result
    end
  end

  def parent_answers_config(name)
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return(name)
  end

  describe "POST /api/sessions/:id/ask" do
    it "answers the reply with the wait's fields and session_id, delivered through chi web's manager and Bridge" do
      session = make
      worker(accepted("t1"), reply: "the answer")

      status, body = ask(session.id[0, 8], { prompt: "what changed?" })

      expect(status).to eq(200), body.inspect
      expect(body).to include("status" => "done", "text" => "the answer", "turn_id" => "t1", "session_id" => session.id,
                              "parent_strategy" => be_a(Hash))
      expect(body).not_to include("asked", "token", "session")
      id, options = deliveries.first
      expect(id).to eq(session.id)
      expect(options).to include(prompt: "what changed?", client_id: "web:unnamed", delivery: "queue", follow: true,
                                 manager: Samagotchi::SessionManager, bridge: be_a(Proc), state_dir: state_dir)
    end

    it "names the id asked when the chain's newest link ran it" do
      old = make
      Samagotchi::ArchiveStore.archive(old.id, state_dir: state_dir)
      newer = make.tap do |s|
        s.continues = old.id
        s.save(state_dir: state_dir)
      end
      worker(accepted("t1"), reply: "new link")

      expect(ask(old, { prompt: "hi" })).to match([200, include("session_id" => newer.id, "asked" => old.id)])
    end

    it "answers a turn still running with status timeout and a token; the token's wait then answers it" do
      session = make(status: "running")
      own(session)
      worker(accepted("held"))

      status, body = ask(session, { prompt: "slow one", timeout: 0.2 })
      expect([status, body["status"]]).to eq([200, "timeout"])
      token = body.fetch("token")
      expect(token).to start_with("w1.")

      expect(wait(session.id, { token: token, timeout: 0.2 })).to match([200, include("status" => "timeout", "token" => token,
                                                                                      "session_id" => session.id)])
      Samagotchi::SessionInbox.write_output(dir_of(session), "done now", enqueued_id: "held")
      status, body = wait(session.id, { token: token, timeout: 1 })
      expect(status).to eq(200)
      expect(body).to include("status" => "done", "text" => "done now", "turn_id" => "held", "session_id" => session.id)
      expect(body).not_to have_key("token")
    end

    it "answers status command for a line the worker ran as a session command" do
      session = make
      worker(accepted(nil, "command_id" => "c1"))

      expect(ask(session, { prompt: "/model x" })).to eq([200, { "status" => "command", "session_id" => session.id }])
    end

    it "answers 404 not_found, and 400 ambiguous_id with the ids" do
      a = make
      b = make
      b_id = "#{a.id[0, 4]}#{b.id[4..]}"
      File.rename(Samagotchi::Session.session_file(b.id, state_dir: state_dir), Samagotchi::Session.session_file(b_id, state_dir: state_dir))

      expect(ask("feedbeef", { prompt: "hi" })).to match([404, include("error" => "not_found")])
      expect(ask(a.id[0, 4], { prompt: "hi" })).to match([400, include("error" => "ambiguous_id", "ids" => [a.id, b_id].sort)])
    end

    it "answers 409 busy (queue: false) and waiting in neutral words, with the busy fields; nothing sent" do
      running = make(status: "running")
      own(running)
      waiting = make(status: "running", pending_question: { id: "q1", question: "Go?", options: %w[Yes No] })
      own(waiting)
      worker(accepted("t1"))

      expect(ask(running, { prompt: "hi", queue: false }))
        .to eq([409, { "error" => "busy", "detail" => "a turn is running: ask with queue, or wait for it",
                       "message" => "a turn is running: ask with queue, or wait for it", "session_id" => running.id }])
      status, body = ask(waiting, { prompt: "hi" })
      expect(status).to eq(409)
      expect(body).to include("error" => "waiting", "detail" => "a question waits for an answer", "session_id" => waiting.id,
                              "question" => include("id" => "q1"), "parent_strategy" => be_a(Hash))
      expect(deliveries).to be_empty
    end

    it "answers 409 continuing for a continue still in flight past the cap" do
      stub_const("Samagotchi::Web::AskRoutes::ASK_MAX_SECONDS", 0.2)
      session = make
      allow(Samagotchi::SessionInbox::Head).to receive(:resolve)
        .and_return(Samagotchi::SessionInbox::Resolved.new(id: "7b2d41aa-0000-4000-8000-000000000000", asked: session.id,
                                                           via: :continuing))

      expect(ask(session, { prompt: "hi" })).to match([409, include("error" => "continuing", "session_id" => session.id,
                                                                    "detail" => include("being continued"))])
    end

    it "answers the turn route's delivery refusals: an older worker's queue_unavailable, a timeout, a one-turn run's" do
      session = make
      worker(Samagotchi::SessionManager::DeliverResult.new(status: :refused, code: 409,
                                                           ack: Samagotchi::Delivery::QUEUE_UNAVAILABLE))
      expect(ask(session, { prompt: "hi" })).to eq([409, Samagotchi::Delivery::QUEUE_UNAVAILABLE.transform_keys(&:to_s)])

      worker(Samagotchi::SessionManager::DeliverResult.new(status: :timeout, ack: { "detail" => "slow" }))
      expect(ask(session, { prompt: "hi" })).to match([504, include("error" => "worker_timeout")])

      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_raise(Samagotchi::SessionManager::OwnedByTUI.new(session.id))
      expect(ask(session, { prompt: "hi" })).to match([409, include("error" => "owned_by_tui", "session_id" => session.id)])
    end

    it "answers 503 server_stopping when chi web stops mid-wait" do
      session = make(status: "running")
      own(session)
      worker(accepted("t1"))
      app.server_running = -> { false }

      expect(ask(session, { prompt: "hi", timeout: 5 })).to match([503, include("error" => "server_stopping")])
    end

    it "answers within ASK_MAX_SECONDS whatever the timeout asked" do
      stub_const("Samagotchi::Web::AskRoutes::ASK_MAX_SECONDS", 1.2)
      session = make(status: "running")
      own(session)
      worker(accepted("t1"))

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(ask(session, { prompt: "hi", timeout: 30 })).to match([200, include("status" => "timeout")])
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(3, below: 10)
      expect(described_class::ASK_MAX_SECONDS).to eq(1.2)
    end

    it "refuses a bad body: no prompt, an empty or too long one, a UI-only command, a bad timeout, queue or client_id" do
      session = make
      worker(accepted("t1"))

      expect(ask(session, {})).to match([400, include("error" => "missing_fields")])
      expect(ask(session, { prompt: "  " })).to match([400, include("error" => "invalid_prompt", "detail" => "the message is empty")])
      expect(ask(session, { prompt: "x" * 17_000 })).to match([400, include("error" => "invalid_prompt", "detail" => include("16 KiB"))])
      expect(ask(session, { prompt: "/stats" })).to match([400, include("error" => "local_command", "detail" => include("chi sessions stats"))])
      expect(ask(session, { prompt: "hi", timeout: 0 })).to match([400, include("error" => "invalid_ask")])
      expect(ask(session, { prompt: "hi", queue: "yes" })).to match([400, include("error" => "invalid_ask")])
      expect(ask(session, { prompt: "hi", client_id: 3 })).to match([400, include("error" => "invalid_ask")])
      expect(call("/api/sessions/#{session.id}/ask", body: [1])).to match([400, include("error" => "invalid_json")])
      expect(deliveries).to be_empty
    end

    it "holds a parent's /continue yes (cli:send) to parent_answers as the turn route does, and sends it as cli:answer" do
      parent_answers_config("soft")
      hard = make(parent_answers: "hard")
      worker(accepted(nil, "command_id" => "c1"))

      expect(ask(hard, { prompt: "/continue yes", client_id: "cli:send" }))
        .to match([403, include("error" => "parent_continue_refused")])
      expect(ask(hard, { prompt: "/parent-answers soft", client_id: "cli:send" }))
        .to match([403, include("error" => "parent_answers_refused")])
      expect(deliveries).to be_empty

      expect(ask(make, { prompt: "/continue yes", client_id: "cli:send" }).first).to eq(200)
      expect(deliveries.last.last).to include(client_id: "cli:answer")
    end
  end

  describe "POST /api/sessions/:id/wait with a token" do
    let(:session) { make }
    let(:target) { Samagotchi::ReplyWait::Target.new(turn: "t9", report_turn_id: "t9", queued: true) }

    it "refuses another session's token, a tampered one, and a token beside the wait's own fields" do
      other = token_module.dump(make.id, target)
      expect(wait(session.id, { token: other })).to match([400, include("error" => "invalid_wait", "detail" => include("another session"))])
      token = token_module.dump(session.id, target)
      expect(wait(session.id, { token: "#{token[0..-3]}!!" })).to match([400, include("error" => "invalid_wait")])
      expect(wait(session.id, { token: "w1.e30" })).to match([400, include("error" => "invalid_wait")])
      expect(wait(session.id, { token: token, cursor: "x" }))
        .to match([400, include("error" => "invalid_wait", "detail" => "token or the wait's fields, not both")])
      expect(wait(session.id, { token: token, queued: false, cursor: nil, timeout: 0.1 }).first).to eq(200)
    end

    it "answers without a token exactly as before (its keys pinned)" do
      Samagotchi::SessionInbox.write_output(dir_of(session), "the answer")
      status, body = wait(session.id, { cursor: nil, timeout: 1 })

      expect(status).to eq(200)
      expect(body.keys).to eq(%w[status text file outcome limit error_kind retryable cancel_reason stopped_by kept_steps
                                 turn_id origin question parent_strategy])
    end
  end

  describe "POST /api/sessions/:id/answer with wait" do
    let(:session) { make(status: "running", pending_question: { id: "q1", question: "Go?", options: %w[Yes No] }) }
    let(:client) { instance_double(Samagotchi::BridgeClient) }

    before do
      own(session)
      allow(app).to receive(:bridge_client).with(session.id).and_return(client)
    end

    def answered(status, json = {})
      allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: status, body: JSON.generate(json)))
    end

    def answer(body) = call("/api/sessions/#{session.id}/answer", body: { id: "q1", selected: ["Yes"], **body })

    it "relays the answer, then waits for what comes next: the reply, or a token while it runs" do
      answered(200)
      status, body = answer(wait: 0.2)
      expect(status).to eq(200)
      expect(body).to include("status" => "answered", "session_id" => session.id, "id" => "q1")
      expect(body["reply"]).to include("status" => "timeout", "token" => start_with("w1."))

      Samagotchi::SessionInbox.write_output(dir_of(session), "went on")
      expect(wait(session.id, { token: body["reply"]["token"], timeout: 1 }))
        .to match([200, include("status" => "done", "text" => "went on")])
    end

    it "still waits when the question was answered elsewhere first (409), as chi answer does" do
      allow(client).to receive(:answer) do
        # Another client's answer went in first; its turn replied.
        Samagotchi::SessionInbox.write_output(dir_of(session), "already on")
        Samagotchi::BridgeClient::Response.new(status: 409, body: JSON.generate(error: "question_not_pending"))
      end

      status, body = answer(wait: 1)
      expect(status).to eq(200)
      expect(body).to include("status" => "not_pending", "answered_here" => false, "id" => "q1")
      expect(body["reply"]).to include("status" => "done", "text" => "already on")
    end

    it "answers as before without wait, and 400 for a bad one" do
      answered(200)
      expect(answer({})).to eq([200, { "status" => "answered", "session_id" => session.id, "id" => "q1" }])
      answered(409, { error: "question_not_pending" })
      expect(answer({}).first).to eq(409)
      expect(answer(wait: -1)).to match([400, include("error" => "invalid_wait")])
    end
  end

  describe "POST /api/sessions: a token for the first turn" do
    it "answers a create with a first turn with a token whose wait is that turn's; an idle create with none" do
      status, body = call("/api/sessions", body: { prompt: "start here", dir: folder })
      expect(status).to eq(201), body.inspect
      turn = body.fetch("first_turn_id")
      session_id, target = token_module.load(body.fetch("token"))
      expect(session_id).to eq(body["id"])
      expect(target).to have_attributes(turn: turn, report_turn_id: turn, queued: true)

      Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(body["id"], state_dir: state_dir), "hello",
                                            enqueued_id: turn)
      expect(wait(body["id"], { token: body["token"], timeout: 1 })).to match([200, include("status" => "done", "text" => "hello")])

      expect(call("/api/sessions", body: { idle: true, dir: folder }).last).not_to have_key("token")
    end
  end

  it "lists the ask feature in GET /api/info" do
    expect(call("/api/info", method: "GET").last["features"]).to include("ask")
    expect(described_class::ASK_FEATURE).to eq("ask")
  end
end
