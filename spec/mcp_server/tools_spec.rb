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
require "samagotchi/mcp_server/tools"

# McpServer::Tools on a real Local backend over a temp state dir; the
# worker is a double of its delivery (#deliver_turn) and of its Bridge's
# answer (#answer), as ask_spec's.
RSpec.describe Samagotchi::McpServer::Tools do
  let(:tmpdir) { Dir.mktmpdir("mcp-tools") }
  let(:access) { Samagotchi::SessionAccess::Local.new(state_dir: tmpdir) }
  let(:tools) { described_class.new(access, slice: 0.3, cap: 2) }
  let(:deliveries) { [] }
  let(:locks) { [] }
  let(:question) { { id: "q1", question: "Which file?", options: %w[README.md NOTES.md], multi_select: false } }

  before do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return("soft")
  end

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(status: "idle", pending_question: nil, parent_answers: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap do |s|
      s.status = status
      s.pending_question = pending_question
      s.parent_answers = parent_answers
      s.save(state_dir: tmpdir)
      FileUtils.mkdir_p(dir_of(s))
    end
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
  def own(session) = locks << Samagotchi::OwnerLock.acquire(dir_of(session), kind: "worker")

  def worker(turn: "t1", reply: nil)
    allow(access).to receive(:deliver_turn) do |id, **options|
      deliveries << [id, options]
      Samagotchi::SessionInbox.write_output(dir_of(Samagotchi::Session.load(id, state_dir: tmpdir)), reply, enqueued_id: turn) if reply
      Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge, ack: { "enqueued_id" => turn })
    end
  end

  def call(name, **arguments) = JSON.parse(JSON.generate(tools.call(name, arguments.transform_keys(&:to_s))))
  def text(result) = result["content"].first["text"]

  it "lists the four tools in a fixed order, only chi_sessions read-only" do
    expect(tools.list.map { |tool| tool[:name] }).to eq(%w[chi_sessions chi_ask chi_wait chi_answer])
    expect(tools.list.select { |tool| tool.dig(:annotations, :readOnlyHint) }.map { |tool| tool[:name] }).to eq(["chi_sessions"])
  end

  describe "chi_sessions" do
    it "lists rows newest first, at most limit, with whether a question waits" do
      older = make
      waiting = make(status: "running", pending_question: question)
      own(waiting)
      result = call("chi_sessions", limit: 5)
      ids = result["structuredContent"]["sessions"].map { |row| row["id"] }
      expect(ids).to contain_exactly(older.id, waiting.id)
      row = result["structuredContent"]["sessions"].find { |r| r["id"] == waiting.id }
      expect(row).to include("waiting" => "question")
      expect(text(result)).to include("#{waiting.id} · ", "a question waits")
      expect(call("chi_sessions", limit: 1)["structuredContent"]["sessions"].size).to eq(1)
    end

    it "refuses a limit out of range or of the wrong type" do
      expect(call("chi_sessions", limit: 51)).to include("isError" => true)
      expect(text(call("chi_sessions", limit: "5"))).to eq("limit has the wrong type")
    end
  end

  describe "chi_ask" do
    it "answers done with the reply, sent as chi send's queued turn" do
      session = make
      worker(reply: "the answer")

      result = call("chi_ask", session: session.id[0, 8], prompt: "hi")
      expect(result).to include("isError" => false)
      expect(text(result)).to eq("the answer")
      # The words in structuredContent too: a host may hand its model that alone.
      expect(result["structuredContent"]).to eq("status" => "done", "session_id" => session.id, "turn_id" => "t1",
                                                "text" => "the answer")
      expect(deliveries.first.last).to include(client_id: "cli:send", delivery: Samagotchi::Delivery::QUEUE)
    end

    it "answers still running with a token that chi_wait takes to the answer" do
      session = make(status: "running")
      own(session)
      worker(turn: "t2")

      running = call("chi_ask", session: session.id, prompt: "go")
      token = running["structuredContent"]["token"]
      expect(running["structuredContent"]).to include("status" => "running", "session_id" => session.id)
      expect(text(running)).to eq("Still running. Call chi_wait with this token to keep waiting.\ntoken: #{token}")

      expect(call("chi_wait", token: token)["structuredContent"]).to include("status" => "running", "token" => token)
      Samagotchi::SessionInbox.write_output(dir_of(session), "later", enqueued_id: "t2")
      done = call("chi_wait", token: token)
      expect([text(done), done["structuredContent"]["status"]]).to eq(%w[later done])
    end

    it "answers a question with its options, the hint and what a parent may pick" do
      session = make
      worker
      pending = Samagotchi::PendingQuestion.from_file(question)
      allow(access).to receive(:wait_reply).and_return(Samagotchi::ReplyWait::Result.new(status: :waiting_for_answer, question: pending))

      result = call("chi_ask", session: session.id, prompt: "read one")
      expect(text(result)).to include("Which file?", "  1. README.md", "  2. NOTES.md", "question_id: q1",
                                      "Call chi_answer with session, question_id and option (or text).")
      expect(result["structuredContent"]).to include(
        "status" => "waiting_for_answer", "session_id" => session.id, "allowed" => %w[README.md NOTES.md],
        "question" => { "id" => "q1", "kind" => "question", "text" => "Which file?", "options" => %w[README.md NOTES.md],
                        "multi_select" => false }
      )
    end

    it "answers a turn that left no reply as an error in chi's words" do
      session = make
      worker
      allow(access).to receive(:wait_reply)
        .and_return(Samagotchi::ReplyWait::Result.new(status: :no_reply, outcome: "failed", text: "the model is down"))

      result = call("chi_ask", session: session.id, prompt: "hi")
      expect(result).to include("isError" => true)
      expect(text(result)).to eq("the turn failed: the model is down")
    end

    it "refuses a shell line and a session command other than /continue; nothing is sent" do
      session = make
      worker
      ["!rm -rf x", "  /model x", "/parent-answers soft"].each do |line|
        result = call("chi_ask", session: session.id, prompt: line)
        expect([result["isError"], text(result)]).to eq([true, Samagotchi::McpServer::Text::COMMAND_REFUSED])
      end
      expect(deliveries).to be_empty
    end

    it "sends /continue yes as chi answer's, and refuses it where parent_answers does" do
      soft = make
      worker(reply: "continued")
      call("chi_ask", session: soft.id, prompt: "/continue yes")
      expect(deliveries.last.last).to include(client_id: "cli:answer")

      hard = make(parent_answers: "hard")
      result = call("chi_ask", session: hard.id, prompt: "/continue yes")
      expect(result).to include("isError" => true)
      expect(result["structuredContent"]).to include("reason" => "parent_refused", "session_id" => hard.id)
      expect(deliveries.size).to eq(1)
    end

    it "refuses an unknown session, an empty prompt and missing arguments" do
      expect(text(call("chi_ask", session: "feedbeef", prompt: "hi"))).to include("feedbeef")
      expect(text(call("chi_ask", session: make.id, prompt: "  "))).to eq("prompt is required (a string)")
      expect(text(call("chi_ask", prompt: "hi"))).to eq("session is required (a string)")
    end

    it "refuses while a question waits, naming it" do
      waiting = make(status: "running", pending_question: question)
      own(waiting)
      result = call("chi_ask", session: waiting.id, prompt: "hi")
      expect(result["structuredContent"]).to include("reason" => "waiting", "question_id" => "q1")
      expect(text(result)).to include("a question waits for an answer first", "question_id: q1")
    end
  end

  describe "chi_wait" do
    it "refuses a token that isn't one" do
      result = call("chi_wait", token: "w1.nope!")
      expect([result["isError"], text(result)]).to eq([true, "a wait token is url-safe base64"])
    end
  end

  describe "chi_answer" do
    let(:answers) { [] }
    let(:session) { make(status: "running", pending_question: question).tap { |s| own(s) } }

    def bridge(status, json = { "ok" => true })
      allow(access).to receive(:answer) do |id, **options|
        answers << [id, options]
        Samagotchi::BridgeClient::Response.new(status: status, body: JSON.generate(json))
      end
    end

    it "answers by number or label, as chi answer's, then waits" do
      bridge(200)
      running = call("chi_answer", session: session.id, question_id: "q1", option: 2)
      expect(answers.last).to match([session.id, { question_id: "q1", selected: ["NOTES.md"], freeform: nil, client_id: "cli:answer",
                                                   within: a_value_between(0.9, 1.0) }])
      expect(running["structuredContent"]).to include("status" => "running")
      call("chi_answer", session: session.id[0, 8], question_id: "q1", option: "README.md")
      expect(answers.last.last[:selected]).to eq(["README.md"])
    end

    it "refuses an option the question doesn't offer and several on a single-select one, before posting" do
      bridge(200)
      expect(text(call("chi_answer", session: session.id, question_id: "q1", option: 3)))
        .to eq("no option 3; the options: 1. README.md, 2. NOTES.md")
      expect(text(call("chi_answer", session: session.id, question_id: "q1", options: [1, 2])))
        .to eq("one option only: the question is single-select")
      expect(text(call("chi_answer", session: session.id, question_id: "q1"))).to include("nothing to answer with")
      expect(answers).to be_empty
    end

    it "answers the worker's parent refusal as the tool's error" do
      bridge(403, { "error" => "parent_refused", "detail" => "a parent may only deny here: tell your user" })
      result = call("chi_answer", session: session.id, question_id: "q1", option: 1)
      expect([result["isError"], text(result)]).to eq([true, "a parent may only deny here: tell your user"])
      expect(result["structuredContent"]).to include("reason" => "parent_refused")
    end

    it "says in its text and answered_here false when the question was answered elsewhere first (409)" do
      bridge(409, { "error" => "question_not_pending" })
      result = call("chi_answer", session: session.id, question_id: "q1", option: 1)
      expect(result["structuredContent"]).to include("answered_here" => false, "status" => "running")
      expect(text(result)).to start_with("Question q1 is no longer open (answered elsewhere, or another one waits); " \
                                         "not answered here. What came next:\nStill running.")
      expect(result["structuredContent"]["text"]).to eq(text(result))
    end

    it "says so in its text for a question_id that isn't the pending one, posting nothing" do
      bridge(200)
      result = call("chi_answer", session: session.id, question_id: "q0", option: 1)
      expect(answers).to be_empty
      expect(text(result)).to start_with("Question q0 is no longer open")
      expect(result["structuredContent"]).to include("answered_here" => false)
    end

    it "keeps its text as is when the answer went in" do
      bridge(200)
      expect(text(call("chi_answer", session: session.id, question_id: "q1", option: 1))).to start_with("Still running.")
    end

    it "refuses a question that no longer waits in an idle session" do
      result = call("chi_answer", session: make.id, question_id: "q1", option: 1)
      expect(result["structuredContent"]).to include("reason" => "no_question")
    end
  end

  it "answers any exception as an error result, never raising" do
    allow(access).to receive(:summaries).and_raise(IOError, "disk gone")
    expect(text(call("chi_sessions"))).to eq("disk gone")
  end
end
