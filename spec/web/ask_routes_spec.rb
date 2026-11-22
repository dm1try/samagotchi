# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "rack/mock"
require_relative "../support/worker_fixtures"

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
  include WorkerFixtures

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
  let(:manager) { Samagotchi::SessionManager }
  let(:app) do
    described_class.new(manager: manager, state_dir: state_dir, bridge_wait_timeout: 0, wait_poll_interval: 0.01)
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

    describe "reply_for" do
      let(:voice) { { "formatting" => "plain", "room" => "short", "choices" => 3, "detail" => false } }

      it "delivers a name's values (or the values) as the turn's anchor" do
        session = make
        worker(accepted("t1"), reply: "ok")

        expect(ask(session, { prompt: "hi", reply_for: "voice" }).first).to eq(200)
        expect(ask(session, { prompt: "hi", reply_for: { room: "one_line" } }).first).to eq(200)
        expect(deliveries.map { |_, options| options[:anchors].reply_for.to_file }).to eq(
          [voice, { "formatting" => "markdown", "room" => "one_line", "choices" => "many", "detail" => true }]
        )
      end

      it "resolves a name from config.yml's surfaces: when the ask comes in" do
        session = make
        worker(accepted("t1"), reply: "ok")
        with_config_home(File.join(@tmp, "config")) do
          File.write(File.join(@tmp, "config", "samagotchi", "config.yml"),
                     YAML.dump("surfaces" => { "watch" => { "room" => "one_line", "choices" => 2 } }))
          expect(ask(session, { prompt: "hi", reply_for: "watch" }).first).to eq(200)
        end
        expect(deliveries.last.last[:anchors].reply_for).to have_attributes(room: "one_line", choices: 2)
      end

      it "refuses an unknown name, key or value with 400 invalid_ask, nothing sent" do
        session = make
        worker(accepted("t1"), reply: "ok")

        [["phone", /unknown name "phone"/], [{ colour: "red" }, /unknown key "colour"/], [{ room: "tiny" }, /room is/]].each do |value, words|
          status, body = ask(session, { prompt: "hi", reply_for: value })
          expect([status, body["error"]]).to eq([400, "invalid_ask"])
          expect(body["detail"]).to match(words)
        end
        expect(deliveries).to be_empty
      end

      it "makes a plain surface's answer plain, on the way out only: the reply file keeps the model's text" do
        session = make
        markdown = "## Status\n- **add** works: run `ruby t.rb add`\n1. next ✅"
        worker(accepted("t1"), reply: markdown)

        status, body = ask(session, { prompt: "status?", reply_for: "voice" })
        expect(status).to eq(200)
        expect(body["text"]).to eq("Status\nadd works: run ruby t.rb add\n1. next")
        # The session isn't saved yet (the worker writes the reply first): the request's value is used.
        expect(Samagotchi::Session.load(session.id, state_dir: state_dir).messages).to be_empty
        expect(Samagotchi::SessionInbox.read_outputs(dir_of(session))).to eq([markdown])
        expect(ask(session, { prompt: "status?", reply_for: { room: "short" } }).last["text"]).to eq(markdown)
        expect(ask(session, { prompt: "status?" }).last["text"]).to eq(markdown)
      end

      it "carries a plain surface in the timeout's token, so its wait is plain too; a token from before strips nothing" do
        session = make(status: "running")
        own(session)
        worker(accepted("held"))

        token = ask(session, { prompt: "slow one", timeout: 0.2, reply_for: "voice" }).last.fetch("token")
        expect(token_module.reply_for(token)).to have_attributes(formatting: "plain")
        Samagotchi::SessionInbox.write_output(dir_of(session), "- **done** now", enqueued_id: "held")
        expect(wait(session.id, { token: token, timeout: 1 }).last).to include("status" => "done", "text" => "done now")

        _id, target = token_module.load(token)
        expect(wait(session.id, { token: token_module.dump(session.id, target), timeout: 1 }).last["text"]).to eq("- **done** now")
      end

      describe "a question the turn stops on, asked without detail" do
        let(:approval) { { id: "q1", question: "Run rm -rf build?", options: %w[Allow Deny], kind: "approval", approval: {} } }

        # The worker takes the ask, then its turn asks +question+.
        def asking(session, question)
          own(session)
          allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |id, **options|
            deliveries << [id, options]
            Samagotchi::Session.load(id, state_dir: state_dir).tap do |s|
              s.status = "running"
              s.pending_question = question
            end.save(state_dir: state_dir)
            accepted("t1")
          end
        end

        it "says an approval (a relayed one's empty approval too), a hook's and a user-only one in words, no options" do
          [approval, approval.merge(kind: "hook", hook: "cost-cap"), approval.except(:kind, :approval).merge(user_only: true)]
            .each do |question|
            session = make
            asking(session, question)

            status, body = ask(session, { prompt: "clean up", reply_for: "voice", timeout: 1 })
            expect(status).to eq(200)
            expect(body).to include("status" => "waiting_for_answer", "needs" => "detail",
                                    "text" => end_with("open it on a full screen.").or(end_with("open it there.")))
            expect(body["question"]).to eq({ "id" => "q1", "kind" => question[:kind] }.compact)
          end
        end

        it "returns the model's question and the step-limit one as today, and every question with detail" do
          [approval.except(:kind, :approval), approval.merge(kind: "continue")].each do |question|
            session = make
            asking(session, question)

            body = ask(session, { prompt: "clean up", reply_for: "voice", timeout: 1 }).last
            expect(body).to include("status" => "waiting_for_answer", "question" => include("options" => %w[Allow Deny]))
            expect(body).not_to have_key("needs")
          end
          session = make
          asking(session, approval)
          expect(ask(session, { prompt: "x", reply_for: { formatting: "plain" }, timeout: 1 }).last).not_to have_key("needs")
        end

        it "makes a plain surface's question text and header plain, its options byte-exact, in the reply and the 409 waiting" do
          question = { id: "q2", header: "**Pick** a `file`", question: "Which file: `README.md` or **Gemfile**?",
                       options: ["`README.md`", "**Gemfile**"] }
          session = make
          asking(session, question)

          body = ask(session, { prompt: "which?", reply_for: "voice", timeout: 1 }).last
          expect(body["question"]).to include("header" => "Pick a file", "question" => "Which file: README.md or Gemfile?",
                                              "options" => ["`README.md`", "**Gemfile**"])
          status, refused = ask(session, { prompt: "and?", reply_for: "voice" })
          expect([status, refused["error"]]).to eq([409, "waiting"])
          expect(refused["question"]).to include("header" => "Pick a file", "question" => "Which file: README.md or Gemfile?",
                                                 "options" => ["`README.md`", "**Gemfile**"])
          expect(ask(session, { prompt: "and?" }).last["question"]).to include("question" => question[:question])
          saved = Samagotchi::Session.load(session.id, state_dir: state_dir).pending_question
          expect(saved).to have_attributes(question: question[:question], header: question[:header])
        end

        it "says it in words on the 409 waiting too" do
          session = make(status: "running", pending_question: approval)
          own(session)

          status, body = ask(session, { prompt: "and?", reply_for: "voice" })
          expect([status, body["error"], body["needs"]]).to eq([409, "waiting", "detail"])
          expect(body["question"]).to eq("id" => "q1", "kind" => "approval")
        end
      end

      it "sends no anchor for none, for values full everywhere, or for a command line (kept in hand only)" do
        session = make
        worker(accepted("t1"), reply: "ok")

        ask(session, { prompt: "hi" })
        ask(session, { prompt: "hi", reply_for: { formatting: "markdown", detail: true } })
        ask(session, { prompt: "/model x", reply_for: "voice" })
        expect(deliveries.map { |_, options| options.key?(:anchors) }).to eq([false, false, false])
      end
    end

    context "with a manager of chi web's own (not SessionManager, the delivery's default)" do
      let(:manager) { SimpleDelegator.new(Samagotchi::SessionManager) }

      it "delivers through that manager, the very object chi web holds" do
        session = make
        worker(accepted("t1"), reply: "ok")

        expect(ask(session, { prompt: "hi" }).first).to eq(200)
        expect(deliveries.first.last[:manager]).to be(manager)
      end
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

    it "follows a /continue yes on a session with its continue offer standing to the continued turn (a token)" do
      session = make(pending_question: { id: "cont", kind: "continue", question: "Continue?" })
      session.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: Time.now.iso8601(3), enqueued_id: "t1",
                                                   exhausted: true, limit: 30)
      session.save(state_dir: state_dir)
      # A live worker that ties a continue turn to its offer (turn_ids),
      # holding the session (live).
      live_sidecar_fixture(dir_of(session), port: 1, features: [Samagotchi::ReplyWait::TURN_IDS_FEATURE])
      worker(accepted(nil, "command_id" => "c1"))

      status, body = ask(session, { prompt: "/continue yes", timeout: 0.2 })
      expect([status, body["status"]]).to eq([200, "timeout"])
      expect(token_module.load(body["token"]).last.turn).to eq("t1")

      # The worker continues: the offer goes, and the continued turn (t1) answers.
      Samagotchi::Session.load(session.id, state_dir: state_dir).tap do |s|
        s.pending_question = nil
        s.save(state_dir: state_dir)
      end
      Samagotchi::SessionInbox.write_output(dir_of(session), "continued", enqueued_id: "t1")
      expect(wait(session.id, { token: body["token"] })).to match([200, include("status" => "done", "text" => "continued")])
    end

    describe "with a request_id" do
      let(:key) { Samagotchi::SessionInbox.enqueued_id_for("ask:r1") }
      let(:history) { [] }

      before { allow(Samagotchi::PromptHistory).to receive(:append) { |line| history << line } }

      # The worker ended turn +id+ (its last_turn) with +text+.
      def ended(session, id, text)
        Samagotchi::Session.load(session.id, state_dir: state_dir).tap do |s|
          s.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: Time.now.iso8601(3), enqueued_id: id)
          s.save(state_dir: state_dir)
        end
        Samagotchi::SessionInbox.write_output(dir_of(session), text, enqueued_id: id) if text
      end

      it "answers a retry with the first ask's turn: one delivery, one history line, the request_id echoed" do
        session = make
        worker(accepted(key))

        first = ask(session, { prompt: "hi", request_id: "r1", timeout: 0.2 })
        expect(first).to match([200, include("status" => "timeout", "request_id" => "r1")])
        ended(session, key, "the first answer")

        second = ask(session, { prompt: "hi", request_id: "r1", timeout: 0.2 })
        expect(second).to match([200, include("status" => "done", "text" => "the first answer", "request_id" => "r1")])
        expect(deliveries.size).to eq(1)
        expect(deliveries.first.last).to include(enqueued_id: key)
        expect(history).to eq(["hi"])
      end

      it "answers a retry of a queued ask with its own turn's reply, not the running one's" do
        session = make(status: "running")
        own(session)
        Samagotchi::Session.load(session.id, state_dir: state_dir).tap do |s|
          s.interrupted_turn = { "started_at" => Time.now.iso8601(3), "iteration" => 1, "enqueued_id" => "T" }
          s.save(state_dir: state_dir)
        end
        # The first ask's copy waits as a queued input file of id E.
        Samagotchi::SessionInbox.write_input(dir_of(session), prompt: "hi", client_id: "web:unnamed", enqueued_id: key,
                                                              delivery: "queue")
        worker(accepted("other"))
        Samagotchi::SessionInbox.write_output(dir_of(session), "the running turn's", enqueued_id: "T")
        Samagotchi::SessionInbox.write_output(dir_of(session), "its own", enqueued_id: key)

        expect(ask(session, { prompt: "hi", request_id: "r1", timeout: 0.5 }))
          .to match([200, include("status" => "done", "text" => "its own")])
        expect(deliveries).to be_empty
      end

      it "answers a retry of a turn that ended before another one with its reply: rebound, nothing sent, one history line" do
        session = make
        # E ended with its reply and another turn ran since: E's reply file
        # still names it (the worker's input_taken? reads the same).
        Samagotchi::SessionInbox.write_output(dir_of(session), "E's answer", enqueued_id: key)
        ended(session, "later", "a later one")
        worker(accepted(key, "duplicate" => true))

        expect(ask(session, { prompt: "hi", request_id: "r1", timeout: 0.5 }))
          .to match([200, include("status" => "done", "text" => "E's answer")])
        expect(deliveries).to be_empty
        expect(history).to be_empty
      end

      it "answers the same request_id with another prompt the known turn's reply while that turn is the last (no 409)" do
        session = make
        ended(session, key, "the first answer")
        worker(accepted("x"))

        expect(ask(session, { prompt: "another", request_id: "r1", timeout: 0.2 }))
          .to match([200, include("status" => "done", "text" => "the first answer")])
        expect(deliveries).to be_empty
      end

      it "answers a retry of a turn settled with no reply (a worker died in it) no_reply, sending nothing (no tokens)" do
        session = make
        ended(session, "later", "a later one")
        settled = File.join(dir_of(session), Samagotchi::SessionInbox::INPUT_DIR, Samagotchi::TurnCheckpoint::SETTLED_DIR)
        FileUtils.mkdir_p(settled)
        record = Samagotchi::LastTurn.new(outcome: "canceled", cancel_reason: "worker_stopped", ended_at: Time.now.iso8601(3),
                                          enqueued_id: key)
        File.write(File.join(settled, key), JSON.generate(record.to_file))
        worker(accepted("x"))

        expect(ask(session, { prompt: "hi", request_id: "r1", timeout: 0.5 }))
          .to match([200, include("status" => "no_reply", "outcome" => "canceled")])
        expect(deliveries).to be_empty
      end

      it "delivers a retry again, with its id, when its first copy waits as an input file and no worker runs" do
        session = make
        Samagotchi::SessionInbox.write_input(dir_of(session), prompt: "hi", client_id: "web:unnamed", enqueued_id: key,
                                                              delivery: "queue")
        worker(accepted(key))

        expect(ask(session, { prompt: "hi", request_id: "r1", timeout: 0.2 }).first).to eq(200)
        expect(deliveries.size).to eq(1)
        expect(deliveries.first.last).to include(enqueued_id: key)
      end

      # An owner's ask un-stops it (a person's send wakes a stopped session);
      # an unattended sender's is refused before anything is written.
      it "answers such a retry from an unattended sender to a stopped session with the delivery's 409, not a token" do
        session = make
        Samagotchi::SessionInbox.write_input(dir_of(session), prompt: "hi", client_id: "system:schedule:nightly", enqueued_id: key,
                                                              delivery: "queue")
        Samagotchi::Session.mark_stopped(session.id, state_dir: state_dir)

        expect(ask(session, { prompt: "hi", request_id: "r1", client_id: "system:schedule:nightly", timeout: 0.2 }))
          .to match([409, include("error" => "session_stopped")])
      end

      it "refuses a bad request_id, and one on a session command (/model x, !ls, /continue yes); nothing sent" do
        session = make
        worker(accepted("t1"))

        ["", "x" * 129, "a b", "é", 3].each do |bad|
          expect(ask(session, { prompt: "hi", request_id: bad }))
            .to match([400, include("error" => "invalid_ask", "detail" => "request_id is 1 to 128 printable ASCII characters")])
        end
        ["/model x", "!ls", "/continue yes", "  /model x"].each do |line|
          expect(ask(session, { prompt: line, request_id: "r1" }))
            .to match([400, include("error" => "invalid_ask", "detail" => "request_id is for messages, not session commands")])
        end
        expect(deliveries).to be_empty
      end

      it "takes a request_id on a message that starts with a path (not a command's shape)" do
        session = make
        worker(accepted(key))

        expect(ask(session, { prompt: "/Users/x/file.rb fails", request_id: "r1", timeout: 0.2 }).first).to eq(200)
        expect(deliveries.first.last).to include(prompt: "/Users/x/file.rb fails", enqueued_id: key)
      end

      it "answers the same request_id with another prompt as the Bridge refuses it (409 enqueued_id_conflict)" do
        session = make
        conflict = Samagotchi::SessionManager::DeliverResult.new(
          status: :refused, via: :bridge, code: 409, ack: { "error" => "enqueued_id_conflict", "detail" => "another prompt" }
        )
        worker(conflict)
        expect(ask(session, { prompt: "other", request_id: "r1" })).to match([409, include("error" => "enqueued_id_conflict")])
        expect(deliveries.first.last).to include(enqueued_id: key)
      end
    end

    it "answers without request_id exactly as before (the keys pinned)" do
      session = make
      worker(accepted("t1"), reply: "ok")
      status, body = ask(session, { prompt: "hi" })
      expect(status).to eq(200)
      expect(body.keys).to match_array(%w[status text session_id turn_id file question outcome limit error_kind retryable
                                          cancel_reason stopped_by kept_steps origin parent_strategy])
      expect(deliveries.first.last).not_to have_key(:enqueued_id)
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

    it "answers 503 server_stopping at once when chi web stops while a continue is waited for; nothing sent" do
      session = make
      allow(Samagotchi::SessionInbox::Head).to receive(:resolve)
        .and_return(Samagotchi::SessionInbox::Resolved.new(id: "7b2d41aa-0000-4000-8000-000000000000", asked: session.id,
                                                           via: :continuing))
      worker(accepted("t1"))
      app.server_running = -> { false }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(ask(session, { prompt: "hi" })).to match([503, include("error" => "server_stopping")])
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(2, below: 9)
      expect(deliveries).to be_empty
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

    it "draws the Bridge wait of its delivery from the same deadline as the rest" do
      stub_const("Samagotchi::Web::AskRoutes::ASK_MAX_SECONDS", 1.2)
      session = make
      allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |_id, bridge:, **|
        bridge.call
        accepted("t1")
      end
      app.instance_variable_set(:@bridge_wait_timeout, 30)
      allow(app).to receive(:worker_link).and_return(Samagotchi::WorkerLink::None.new)
      lefts = []
      allow(app).to receive(:await_worker_link) do |_id, timeout:|
        lefts << timeout
        Samagotchi::WorkerLink::None.new
      end

      ask(session, { prompt: "hi", timeout: 0.1 })
      expect(lefts.size).to eq(1)
      expect(lefts.first).to be_between(0, 1.2)
    end

    describe "the post to a live worker" do
      # A live link whose client records the read it was given.
      def live_link(reads)
        link = Object.new
        link.define_singleton_method(:live?) { true }
        link.define_singleton_method(:client) do |_sid, host:, read_timeout:, deadline_margin:|
          reads << [host, read_timeout, deadline_margin]
          nil
        end
        link
      end

      def read_for(max)
        stub_const("Samagotchi::Web::AskRoutes::ASK_MAX_SECONDS", max) if max
        session = make
        allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |_id, bridge:, **|
          bridge.call
          accepted("t1")
        end
        reads = []
        allow(app).to receive(:worker_link).and_return(live_link(reads))
        ask(session, { prompt: "hi", timeout: 0.1 })
        expect(reads.size).to eq(1)
        expect(reads.first.first).to eq(described_class::DEFAULT_HOST)
        # The body deadline leaves the worker time to answer 202.
        expect(reads.first.last).to eq(Samagotchi::Web::AskRoutes::POST_MARGIN)
        reads.first[1]
      end

      it "reads for what is left of the deadline but the slice, under the old 30 s" do
        floor = Samagotchi::Web::AskRoutes::POST_FLOOR
        expect(read_for(20.0)).to be_between(floor, 20.0 - Samagotchi::SessionAccess::Ask::MIN_SLICE)
      end

      it "never reads for less than POST_FLOOR" do
        expect(read_for(1.2)).to eq(Samagotchi::Web::AskRoutes::POST_FLOOR)
      end

      it "reads for at most READ_TIMEOUT on the default deadline" do
        expect(read_for(nil)).to eq(Samagotchi::BridgeClient::READ_TIMEOUT)
      end
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

    it "holds an agent's /continue yes (agent:<name>) as chi send's and sends it as cli:answer" do
      parent_answers_config("soft")
      hard = make(parent_answers: "hard")
      worker(accepted(nil, "command_id" => "c1"))

      expect(ask(hard, { prompt: "/continue yes", client_id: "agent:claude" }))
        .to match([403, include("error" => "parent_continue_refused")])
      expect(deliveries).to be_empty
      expect(ask(make, { prompt: "/continue yes", client_id: "agent:claude" }).first).to eq(200)
      expect(deliveries.last.last).to include(client_id: "cli:answer")
    end

    it "holds a parent's line to config.yml's parent_answers when no session file is left to read (fails closed)" do
      parent_answers_config("hard")
      session = make
      worker(accepted(nil, "command_id" => "c1"))
      file = Samagotchi::Session.session_file(session.id, state_dir: state_dir)
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with(file).and_return(false)

      expect(ask(session, { prompt: "/continue yes", client_id: "cli:send" }))
        .to match([403, include("error" => "parent_continue_refused")])
      expect(deliveries).to be_empty
    end
  end

  describe "POST /api/sessions/:id/wait with a token" do
    let(:session) { make }
    let(:target) { Samagotchi::ReplyWait::Target.new(turn: "t9", report_turn_id: "t9", queued: true) }

    it "refuses another session's token, one that is not base64 or holds no session, and a token beside the wait's own fields" do
      other = token_module.dump(make.id, target)
      expect(wait(session.id, { token: other })).to match([400, include("error" => "invalid_wait", "detail" => include("another session"))])
      token = token_module.dump(session.id, target)
      expect(wait(session.id, { token: "#{token[0..-3]}!!" })).to match([400, include("error" => "invalid_wait")])
      expect(wait(session.id, { token: "w1.e30" })).to match([400, include("error" => "invalid_wait")])
      expect(wait(session.id, { token: token, cursor: "x" }))
        .to match([400, include("error" => "invalid_wait", "detail" => "token or the wait's fields, not both")])
      expect(wait(session.id, { token: token, queued: false, cursor: nil, timeout: 0.1 }).first).to eq(200)
    end

    it "takes a prefix of the token's session in the URL (resolved first), as the ask does" do
      token = token_module.dump(session.id, target)
      Samagotchi::SessionInbox.write_output(dir_of(session), "the answer", enqueued_id: "t9")

      expect(wait(session.id[0, 8], { token: token, timeout: 1 }))
        .to match([200, include("status" => "done", "text" => "the answer", "session_id" => session.id)])
    end

    # The token is unsigned on purpose (Exchange::Token): a field edited and
    # re-encoded still loads, and only s routes it.
    def edited(token, **fields)
      raw = JSON.parse(token.delete_prefix("w1.").tr("-_", "+/").then { |t| t + ("=" * ((4 - (t.length % 4)) % 4)) }.unpack1("m0"))
      "w1.#{[JSON.generate(raw.merge(fields.transform_keys(&:to_s)))].pack("m0").tr("+/", "-_").delete("=")}"
    end

    it "refuses a re-encoded token whose s names another session; waits on an edited turn as a body could ask" do
      token = token_module.dump(session.id, target)
      other = make

      expect(wait(session.id, { token: edited(token, s: other.id) }))
        .to match([400, include("error" => "invalid_wait", "detail" => include("another session"))])
      expect(wait(session.id, { token: edited(token, t: 7) }))
        .to match([400, include("error" => "invalid_wait", "detail" => include("t is a string"))])

      Samagotchi::SessionInbox.write_output(dir_of(session), "the other turn's", enqueued_id: "t10")
      expect(wait(session.id, { token: edited(token, t: "t10", r: "t10"), timeout: 1 }))
        .to match([200, include("status" => "done", "text" => "the other turn's", "turn_id" => "t10")])
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

    it "reports an error of the wait after the answer went in as answered + wait_error, not as the answer failing" do
      answered(200)
      failing = instance_double(Samagotchi::SessionAccess::Exchange)
      allow(app).to receive(:plain_exchange).and_return(failing)

      allow(failing).to receive(:wait).and_raise(Errno::ENOENT, "session file")
      status, body = answer(wait: 1)
      expect(status).to eq(200)
      expect(body).to include("status" => "answered", "session_id" => session.id, "id" => "q1",
                              "wait_error" => include("error" => "wait_failed", "detail" => include("session file")))
      expect(body).not_to have_key("reply")

      allow(failing).to receive(:wait).and_raise(ArgumentError, "no such session")
      expect(answer(wait: 1))
        .to match([200, include("status" => "answered", "wait_error" => include("error" => "not_found"))])

      allow(failing).to receive(:wait).and_return(Samagotchi::ReplyWait::Result.new(status: :canceled))
      expect(answer(wait: 1))
        .to match([200, include("status" => "answered", "wait_error" => include("error" => "server_stopping"))])
    end

    it "shapes the reply for the pending turn's surface, read from its saved opener before the answer goes in" do
      voice = { "formatting" => "plain", "room" => "short", "choices" => 3, "detail" => false }
      session.messages = [{ role: "user", content: "go on", turn_id: "t1", reply_for: voice, reply_line: "[Reply for this message: …]" }]
      session.save(state_dir: state_dir)
      allow(client).to receive(:answer) do
        # The worker replies and then saves: the opener is read before this.
        Samagotchi::SessionInbox.write_output(dir_of(session), "**Done.** Ran `rm 2` ✅")
        Samagotchi::Session.load(session.id, state_dir: state_dir).tap { |s| s.messages = [] }.save(state_dir: state_dir)
        Samagotchi::BridgeClient::Response.new(status: 200, body: "{}")
      end

      status, body = answer(wait: 1)
      expect(status).to eq(200)
      expect(body["reply"]).to include("status" => "done", "text" => "Done. Ran rm 2")
    end

    it "leaves a wake turn's reply as it is after a declared turn: the latest opening declares nothing" do
      voice = { "formatting" => "plain", "room" => "short", "choices" => 3, "detail" => false }
      session.messages = [{ role: "user", content: "go on", turn_id: "t1", reply_for: voice },
                          { role: "model", content: "ok" },
                          { role: "system", content: "[CONTEXT NOTE]", turn_start: true, turn_id: "w1" }]
      session.save(state_dir: state_dir)
      allow(client).to receive(:answer) do
        Samagotchi::SessionInbox.write_output(dir_of(session), "**Done.**")
        Samagotchi::BridgeClient::Response.new(status: 200, body: "{}")
      end

      expect(answer(wait: 1).last["reply"]).to include("text" => "**Done.**")
    end

    describe "with reply_for (the answering surface)" do
      let(:session) do
        make(status: "running", pending_question: { id: "q1", question: "Run it?", options: %w[Yes No], kind: "approval", approval: {} })
      end

      it "refuses an approval from a surface without detail with 403 needs_detail, nothing relayed" do
        expect(client).not_to receive(:answer)
        expect(answer(reply_for: "voice")).to eq([403, Samagotchi::ReplyFor::NEEDS_DETAIL])
        expect(answer(reply_for: { formatting: "plain", detail: false }).first).to eq(403)
        expect(answer(reply_for: "bogus")).to match([400, include("error" => "invalid_answer")])
      end

      it "relays it with detail, or without the field (the owner's, as today)" do
        answered(200)
        expect(answer(reply_for: { formatting: "plain" }).first).to eq(200)
        expect(answer({}).first).to eq(200)
      end

      it "relays a model's question from a surface without detail" do
        model = make(status: "running", pending_question: { id: "q1", question: "Which?", options: %w[A B] })
        own(model)
        allow(app).to receive(:bridge_client).with(model.id).and_return(client)
        answered(200)
        expect(call("/api/sessions/#{model.id}/answer", body: { id: "q1", selected: ["A"], reply_for: "voice" }).first).to eq(200)
      end
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
