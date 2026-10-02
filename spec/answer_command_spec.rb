# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/answer_command"

# chi answer: a parent agent (or a script) answers the question a session's
# worker waits on, then waits for what comes next, as chi send --wait does.
RSpec.describe Samagotchi::AnswerCommand do
  let(:tmpdir) { Dir.mktmpdir("answer") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:threads) { [] }
  let(:owner) { [Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker")] }
  let(:posted) { [] }
  # What the fake Bridge answers, in turn; the last one repeats.
  let(:replies) { [[200, { status: "answered" }]] }
  let(:bridge) do
    double("BridgeClient").tap do |client|
      allow(client).to receive(:answer) do |id:, selected:, freeform: nil|
        posted << [:answer, id, selected, freeform]
        respond
      end
      allow(client).to receive(:dismiss_question) do |id:|
        posted << [:dismiss, id]
        respond
      end
    end
  end

  let(:question) do
    { id: "q1", question: "Which file should I read?", options: %w[README.md NOTES.md], multi_select: false,
      allow_freeform: false, status: "pending" }
  end

  let(:approval) do
    { id: "a1", question: "execute: echo hi\n  why: spike (rule spike-ask, config)", header: "Approve tool call?",
      options: ["Allow once", "Allow this call for the session", "Allow rule spike-ask in this directory", "Deny"],
      multi_select: false, allow_freeform: true, kind: "approval",
      approval: { tool: "execute", command: "echo hi", rule: "spike-ask", scopes: %w[once session rule] },
      status: "pending" }
  end

  before do
    stub_const("Samagotchi::AnswerCommand::POLL_INTERVAL", 0.02)
    allow(Samagotchi::SessionManager).to receive(:session_owner) { owner[0] }
    allow(Samagotchi::BridgeClient).to receive(:discover) { bridge }
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_approvals") { @parent_approvals || "off" }
  end

  after do
    threads.each(&:join)
    FileUtils.rm_rf(tmpdir)
  end

  def respond
    status, body = replies.size > 1 ? replies.shift : replies.first
    Samagotchi::BridgeClient::Response.new(status: status, body: JSON.generate(body))
  end

  def run(*argv)
    described_class.new(argv, stdout: out, stderr: err, state_dir: tmpdir).run
  end

  def asking(pending, status: "running")
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w").tap do |s|
      s.status = status
      s.last_prompt = "go"
      s.pending_question = pending
      s.save(state_dir: tmpdir)
    end
  end

  def update(session, status: nil, pending_question: :keep)
    s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
    s.status = status if status
    s.pending_question = pending_question unless pending_question == :keep
    s.save(state_dir: tmpdir)
  end

  def write_reply(session, text)
    Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), text)
  end

  # The worker takes the answer: the question goes, a reply comes.
  def replies_after_answer(session, text)
    threads << Thread.new do
      sleep(0.02) until posted.any?
      sleep(0.05)
      update(session, pending_question: nil)
      write_reply(session, text)
      update(session, status: "idle")
    end
  end

  def json_out
    lines = out.string.lines
    expect(lines.size).to eq(1), out.string
    JSON.parse(lines.first)
  end

  it "answers by option number, then prints the reply that follows" do
    s = asking(question)
    replies_after_answer(s, "Read NOTES.md. Done.")

    expect(run(s.id[0, 8], "--question", "q1", "--option", "2")).to eq(0), err.string
    expect(posted).to eq([[:answer, "q1", ["NOTES.md"], nil]])
    expect(out.string).to eq("Read NOTES.md. Done.\n")
  end

  it "takes the option's label, free text, and several options on a multi-select question" do
    s = asking(question.merge(multi_select: true, allow_freeform: true))
    replies_after_answer(s, "ok")

    expect(run(s.id, "--question", "q1", "--option", "README.md", "--option", "2", "--text", "both")).to eq(0), err.string
    expect(posted).to eq([[:answer, "q1", %w[README.md NOTES.md], "both"]])
  end

  it "comes back with exit 3 and the next question, not the one it answered" do
    s = asking(question)
    threads << Thread.new do
      sleep(0.02) until posted.any?
      sleep(0.1)
      update(s, pending_question: { id: "q2", question: "And then?", options: %w[Stop Go] })
    end

    expect(run(s.id, "--question", "q1", "--option", "1", "--format", "json")).to eq(3)
    expect(json_out).to include("status" => "question", "answer_with" => "chi answer #{s.id} --question q2 --option N")
    expect(json_out["question"]).to include("id" => "q2", "options" => %w[Stop Go])
  end

  it "dismisses a question: the model goes on to its reply" do
    s = asking(question)
    replies_after_answer(s, "I won't read anything then.")

    expect(run(s.id, "--question", "q1", "--dismiss", "--format", "json")).to eq(0), err.string
    expect(posted).to eq([[:dismiss, "q1"]])
    expect(json_out).to eq("status" => "answered", "session_id" => s.id, "text" => "I won't read anything then.")
  end

  it "keeps waiting when another client answered first (409), and prints that turn's reply" do
    s = asking(question)
    replies.replace([[409, { error: "question_not_pending", detail: "question already answered" }]])
    replies_after_answer(s, "the web's answer won")

    expect(run(s.id, "--question", "q1", "--option", "1")).to eq(0), err.string
    expect(out.string).to eq("the web's answer won\n")
    expect(err.string).to eq("chi answer: question q1 is no longer open; not answered here, waiting for what comes next\n")
  end

  it "doesn't answer a question the session no longer waits on, and reports the one that waits now" do
    s = asking({ id: "q2", question: "And then?", options: %w[Stop Go] })

    expect(run(s.id, "--question", "q1", "--option", "1", "--timeout", "1")).to eq(3)
    expect(posted).to be_empty
    expect(err.string).to start_with("chi answer: question q1 is no longer open; not answered here")
    expect(err.string).to include("chi answer: waiting for an answer (question): And then?")
  end

  it "says so when the question is no longer open and nothing runs" do
    s = asking(nil, status: "idle")

    expect(run(s.id, "--question", "q1", "--option", "1", "--format", "json")).to eq(1)
    expect(posted).to be_empty
    expect(json_out).to eq("status" => "error", "session_id" => s.id,
                           "detail" => "no question q1 waits in #{s.id[0, 8]}; nothing to answer")
  end

  it "refuses an option that isn't offered, a number out of range, or two on a single-select question (exit 2)" do
    s = asking(question)
    expect(run(s.id, "--question", "q1", "--option", "Gemfile")).to eq(2)
    expect(err.string).to include("chi answer: no option Gemfile; the options: 1. README.md, 2. NOTES.md")
    expect(run(s.id, "--question", "q1", "--option", "3")).to eq(2)
    expect(run(s.id, "--question", "q1", "--option", "1", "--option", "2")).to eq(2)
    expect(err.string).to include("one option only: the question is single-select")
    expect(posted).to be_empty
  end

  it "reports the Bridge's 400 with exit 2" do
    s = asking(question.merge(allow_freeform: true))
    replies.replace([[400, { error: "invalid_answer", detail: "selection required" }]])

    expect(run(s.id, "--question", "q1", "--text", " ")).to eq(2)
    expect(err.string).to include("chi answer: selection required")
  end

  it "retries once when the worker read the answer too late (408)" do
    s = asking(question)
    replies.replace([[408, { error: "deadline_passed" }], [200, { status: "answered" }]])
    replies_after_answer(s, "ok")

    expect(run(s.id, "--question", "q1", "--option", "1")).to eq(0), err.string
    expect(posted.size).to eq(2)
  end

  it "says the worker is gone when no Bridge answers, and how to send the task again" do
    s = asking(question)
    allow(Samagotchi::BridgeClient).to receive(:discover).and_return(nil)

    expect(run(s.id, "--question", "q1", "--option", "1")).to eq(1)
    expect(err.string).to eq("chi answer: the worker is gone and the question with it; " \
                             "send the task again: chi send --wait -m \"…\" #{s.id}\n")

    allow(bridge).to receive(:answer).and_raise(Errno::ECONNREFUSED)
    allow(Samagotchi::BridgeClient).to receive(:discover).and_return(bridge)
    expect(run(s.id, "--question", "q1", "--option", "1", "--format", "json")).to eq(1)
    expect(json_out).to include("status" => "error", "detail" => start_with("the worker is gone"))
  end

  it "names an older worker that can't dismiss (404)" do
    s = asking(question)
    replies.replace([[404, { error: "not_found" }]])

    expect(run(s.id, "--question", "q1", "--dismiss")).to eq(1)
    expect(err.string).to include("this session's worker runs an older chi and can't dismiss a question")
  end

  it "gives up after --timeout with exit 4, the turn still running" do
    s = asking(question)

    expect(run(s.id, "--question", "q1", "--option", "1", "--timeout", "0.2", "--format", "json")).to eq(4)
    expect(json_out).to include("status" => "running")
  end

  describe "an approval (guardrails.parent_approvals)" do
    it "denies with Deny and a reason, or with text alone" do
      s = asking(approval)
      replies_after_answer(s, "I won't run it.")
      expect(run(s.id, "--question", "a1", "--option", "Deny", "--text", "use printf")).to eq(0), err.string
      expect(posted.last).to eq([:answer, "a1", ["Deny"], "use printf"])

      s = asking(approval)
      posted.clear
      replies_after_answer(s, "ok")
      expect(run(s.id, "--question", "a1", "--text", "not now")).to eq(0), err.string
      expect(posted.last).to eq([:answer, "a1", [], "not now"])
    end

    it "denies with --dismiss" do
      s = asking(approval)
      replies_after_answer(s, "ok")
      expect(run(s.id, "--question", "a1", "--dismiss")).to eq(0), err.string
      expect(posted).to eq([[:dismiss, "a1"]])
    end

    it "refuses every Allow by default: that is the user's, in the web or chi --attach" do
      s = asking(approval)
      # A --timeout, so an Allow that slips through fails rather than hangs.
      ["1", "Allow once", "2", "3"].each do |option|
        expect(run(s.id, "--question", "a1", "--option", option, "--timeout", "0.3")).to eq(1)
      end
      expect(posted).to be_empty
      expect(err.string).to include("chi answer: allowing a tool call is up to the user: approve it in the web or " \
                                    "chi --attach #{s.id}; deny it with --option Deny --text WHY")
    end

    it "with parent_approvals: once lets Allow once through, picked by its scope, never a wider one" do
      @parent_approvals = "once"
      s = asking(approval)
      %w[2 3].each { |option| expect(run(s.id, "--question", "a1", "--option", option, "--timeout", "0.3")).to eq(1) }
      expect(err.string).to include("only Allow once (guardrails.parent_approvals: once)")
      expect(posted).to be_empty

      replies_after_answer(s, "ran it")
      expect(run(s.id, "--question", "a1", "--option", "1")).to eq(0), err.string
      expect(posted).to eq([[:answer, "a1", ["Allow once"], nil]])
    end

    it "fails closed on an approval whose scopes are missing, empty or malformed: only Deny goes" do
      @parent_approvals = "once"
      [nil, [], "once", [nil]].each do |scopes|
        s = asking(approval.merge(approval: approval[:approval].merge(scopes: scopes)))
        %w[1 2 3].each do |option|
          expect(run(s.id, "--question", "a1", "--option", option, "--timeout", "0.3")).to eq(1), "#{scopes.inspect} #{option}"
        end
      end
      s = asking(approval.except(:approval))
      expect(run(s.id, "--question", "a1", "--option", "Allow once", "--timeout", "0.3")).to eq(1)
      expect(posted).to be_empty
      expect(err.string).to include("only Allow once (guardrails.parent_approvals: once)")

      replies_after_answer(s, "ok")
      expect(run(s.id, "--question", "a1", "--option", "Deny", "--text", "no")).to eq(0), err.string
      expect(posted).to eq([[:answer, "a1", ["Deny"], "no"]])
    end

    it "refuses an allow with --text (the text doesn't make it a deny)" do
      s = asking(approval)
      expect(run(s.id, "--question", "a1", "--option", "1", "--text", "fine", "--timeout", "0.3")).to eq(1)
      expect(posted).to be_empty
    end

    it "takes guardrails.parent_approvals from config.yml only, never the parent's environment" do
      allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_approvals").and_call_original
      original = ENV["SAMAGOTCHI_GUARDRAILS_PARENT_APPROVALS"]
      ENV["SAMAGOTCHI_GUARDRAILS_PARENT_APPROVALS"] = "once"
      Samagotchi::Config.reload!
      s = asking(approval)
      expect(run(s.id, "--question", "a1", "--option", "Allow once", "--timeout", "0.3")).to eq(1)
      expect(posted).to be_empty
      expect(err.string).to include("allowing a tool call is up to the user")
    ensure
      original ? ENV["SAMAGOTCHI_GUARDRAILS_PARENT_APPROVALS"] = original : ENV.delete("SAMAGOTCHI_GUARDRAILS_PARENT_APPROVALS")
      Samagotchi::Config.reload!
    end

    it "with parent_approvals: once refuses an approval that doesn't offer once" do
      @parent_approvals = "once"
      s = asking(approval.merge(options: ["Allow this call for the session", "Deny"],
                                approval: approval[:approval].merge(scopes: %w[session])))
      expect(run(s.id, "--question", "a1", "--option", "1", "--timeout", "0.3")).to eq(1)
      expect(posted).to be_empty
    end
  end

  it "needs a session, --question and an answer; --dismiss stands alone" do
    expect(run("--question", "q1", "--option", "1")).to eq(2)
    expect(err.string).to include("give one session id")
    expect(run("abc", "--option", "1")).to eq(2)
    expect(err.string).to include("--question QID is required")
    expect(run("abc", "--question", "q1")).to eq(2)
    expect(err.string).to include("nothing to answer with: --option, --text or --dismiss")
    expect(run("abc", "--question", "q1", "--dismiss", "--option", "1")).to eq(2)
    expect(err.string).to include("--dismiss takes no --option or --text")
    expect(run("abc", "--question", "q1", "--option", "1", "--format", "yaml")).to eq(2)
    expect(run("abc", "--question", "q1", "--option", "1", "--timeout", "soon")).to eq(2)
    expect(out.string).to be_empty
  end

  it "reports an unknown session (exit 1)" do
    expect(run("nope", "--question", "q1", "--option", "1")).to eq(1)
    expect(err.string).to eq("chi answer: no session nope\n")
  end

  it "prints help" do
    expect(run("--help")).to eq(0)
    expect(out.string).to include("Usage: chi answer ID --question QID")
  end
end
