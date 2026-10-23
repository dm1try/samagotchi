# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/answer_command"
require_relative "support/remote_backend"

# chi answer: a parent agent (or a script) answers the question a session's
# worker waits on, then waits for what comes next, as chi send --wait does.
RSpec.describe Samagotchi::AnswerCommand do
  # Remotely the parent's options are checked by the worker alone (chi web
  # passes chi answer's client_id on; the fake Bridge here takes anything).
  PARENT_CHECK = "the parent check before posting is this machine's; remotely the worker's"

  let(:tmpdir) { Dir.mktmpdir("answer") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:threads) { [] }
  let(:owner) { [Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker")] }
  let(:posted) { [] }
  let(:clients) { [] }
  # What the fake Bridge answers, in turn; the last one repeats.
  let(:replies) { [[200, { status: "answered" }]] }
  let(:bridge) do
    double("BridgeClient").tap do |client|
      allow(client).to receive(:answer) do |id:, selected:, freeform: nil, client_id: nil|
        posted << [:answer, id, selected, freeform]
        clients << client_id
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
    allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers") { @parent_answers || "soft" }
    # Remotely chi web reaches the worker through its sidecar's port: the
    # same fake Bridge (nil: none).
    if backend == :remote
      allow(backend_app(tmpdir)).to receive(:bridge_client) { Samagotchi::BridgeClient.discover("x", session_dir: tmpdir) }
    end
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
    described_class.new(argv, stdout: out, stderr: err, state_dir: tmpdir, access: backend_access(tmpdir)).run
  end

  def asking(pending, status: "running", parent_answers: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w").tap do |s|
      s.parent_answers = parent_answers
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
      wait_for("the answer to be posted", timeout: 10) { posted.any? }
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

  RemoteBackend.both(self) do
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
        wait_for("the answer to be posted", timeout: 10) { posted.any? }
        sleep(0.1)
        update(s, pending_question: { id: "q2", question: "And then?", options: %w[Stop Go] })
      end

      expect(run(s.id, "--question", "q1", "--option", "1", "--format", "json")).to eq(3)
      expect(json_out).to include("status" => "question", "answer_with" => "#{via.chi} answer #{s.id} --question q2 --option N")
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

    it "says in the JSON that the answer didn't go in (409), with what came next" do
      s = asking(question)
      replies.replace([[409, { error: "question_not_pending", detail: "question already answered" }]])
      replies_after_answer(s, "the web's answer won")

      expect(run(s.id, "--question", "q1", "--option", "1", "--format", "json")).to eq(0), err.string
      expect(json_out).to eq("status" => "answered", "session_id" => s.id, "text" => "the web's answer won",
                             "answered_here" => false)
    end

    it "says in the JSON that a question no longer waited on wasn't answered, with the one that waits now" do
      s = asking({ id: "q2", question: "And then?", options: %w[Stop Go] })

      expect(run(s.id, "--question", "q1", "--option", "1", "--timeout", "1", "--format", "json")).to eq(3)
      expect(json_out).to include("status" => "question", "answered_here" => false)
      expect(json_out["question"]).to include("id" => "q2")
    end

    it "has no answered_here when the answer went in" do
      s = asking(question)
      replies_after_answer(s, "Read NOTES.md.")

      expect(run(s.id, "--question", "q1", "--option", "2", "--format", "json")).to eq(0), err.string
      expect(json_out).not_to have_key("answered_here")
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
                               "send the task again: #{via.chi} send --wait -m \"…\" #{s.id}\n")

      allow(bridge).to receive(:answer).and_raise(Errno::ECONNREFUSED)
      allow(Samagotchi::BridgeClient).to receive(:discover).and_return(bridge)
      expect(run(s.id, "--question", "q1", "--option", "1", "--format", "json")).to eq(1)
      expect(json_out).to include("status" => "error", "detail" => start_with("the worker is gone"))
    end

    it "names an older worker that can't dismiss (404)" do
      s = asking(question)
      replies.replace([[404, { error: "not_found" }]])

      expect(run(s.id, "--question", "q1", "--dismiss")).to eq(1)
      expect(err.string).to include("this session's worker runs an older chi and can't dismiss a question; " \
                                    "restart it: #{via.chi} sessions stop #{s.id}")
      expect(err.string).to include(backend == :remote ? "then a message (chi --remote studio send #{s.id} -m …)" : "chi --resume #{s.id}")
    end

    it "gives up after --timeout with exit 4, the turn still running" do
      s = asking(question)

      expect(run(s.id, "--question", "q1", "--option", "1", "--timeout", "0.2", "--format", "json")).to eq(4)
      expect(json_out).to include("status" => "running")
    end

    describe "an approval (guardrails.parent_answers)" do
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

      it "refuses every Allow under standard and hard: that is the user's, so deny and tell the user", local_only: PARENT_CHECK do
        s = asking(approval)
        # A --timeout, so an Allow that slips through fails rather than hangs.
        %w[standard hard].each do |strategy|
          @parent_answers = strategy
          ["1", "Allow once", "2", "3"].each do |option|
            expect(run(s.id, "--question", "a1", "--option", option, "--timeout", "0.3")).to eq(1)
          end
        end
        expect(posted).to be_empty
        expect(err.string).to include("chi answer: allowing a tool call is up to the user: deny it (--option Deny " \
                                      "--text WHY), and tell your user")
        expect(err.string).not_to include("--attach")
      end

      it "under soft (the default) lets Allow once through, picked by its scope, never a wider one", local_only: PARENT_CHECK do
        s = asking(approval)
        %w[2 3].each { |option| expect(run(s.id, "--question", "a1", "--option", option, "--timeout", "0.3")).to eq(1) }
        expect(err.string).to include("only Allow once (guardrails.parent_answers: soft)")
        expect(posted).to be_empty

        replies_after_answer(s, "ran it")
        expect(run(s.id, "--question", "a1", "--option", "1")).to eq(0), err.string
        expect(posted).to eq([[:answer, "a1", ["Allow once"], nil]])
      end

      it "fails closed on an approval whose scopes are missing, empty or malformed: only Deny goes", local_only: PARENT_CHECK do
        [nil, [], "once", [nil]].each do |scopes|
          s = asking(approval.merge(approval: approval[:approval].merge(scopes: scopes)))
          %w[1 2 3].each do |option|
            expect(run(s.id, "--question", "a1", "--option", option, "--timeout", "0.3")).to eq(1), "#{scopes.inspect} #{option}"
          end
        end
        s = asking(approval.except(:approval))
        expect(run(s.id, "--question", "a1", "--option", "Allow once", "--timeout", "0.3")).to eq(1)
        expect(posted).to be_empty
        expect(err.string).to include("only Allow once (guardrails.parent_answers: soft)")

        replies_after_answer(s, "ok")
        expect(run(s.id, "--question", "a1", "--option", "Deny", "--text", "no")).to eq(0), err.string
        expect(posted).to eq([[:answer, "a1", ["Deny"], "no"]])
      end

      # P3: the session file's own parent_answers, tighten-only.
      it "holds the parent to the session's own level when stricter than config.yml's, never to a looser one", local_only: PARENT_CHECK do
        s = asking(approval, parent_answers: "standard")
        expect(run(s.id, "--question", "a1", "--option", "1", "--timeout", "0.3")).to eq(1)
        expect(err.string).to include("allowing a tool call is up to the user")
        expect(posted).to be_empty

        @parent_answers = "standard"
        s = asking(approval, parent_answers: "soft")
        expect(run(s.id, "--question", "a1", "--option", "1", "--timeout", "0.3")).to eq(1)
        expect(posted).to be_empty

        # The step-limit refusal names where the level comes from.
        @parent_answers = "soft"
        s = asking({ id: "c1", question: "Continue?", options: %w[Continue Stop], kind: "continue", status: "pending" },
                   parent_answers: "hard")
        expect(run(s.id, "--question", "c1", "--option", "Continue", "--timeout", "0.3")).to eq(1)
        expect(err.string).to include("(parent_answers: hard (this session))")
        expect(posted).to be_empty
      end

      it "refuses an allow with --text (the text doesn't make it a deny)", local_only: PARENT_CHECK do
        @parent_answers = "standard"
        s = asking(approval)
        expect(run(s.id, "--question", "a1", "--option", "1", "--text", "fine", "--timeout", "0.3")).to eq(1)
        expect(posted).to be_empty
      end

      it "takes guardrails.parent_answers from config.yml only, never the parent's environment" do
        allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_call_original
        original = ENV["SAMAGOTCHI_GUARDRAILS_PARENT_ANSWERS"]
        ENV["SAMAGOTCHI_GUARDRAILS_PARENT_ANSWERS"] = "hard"
        Samagotchi::Config.reload!
        # The environment's hard is not read: soft, the default, lets Allow once through.
        s = asking(approval)
        replies_after_answer(s, "ran it")
        expect(run(s.id, "--question", "a1", "--option", "Allow once")).to eq(0), err.string
        expect(posted).to eq([[:answer, "a1", ["Allow once"], nil]])
      ensure
        original ? ENV["SAMAGOTCHI_GUARDRAILS_PARENT_ANSWERS"] = original : ENV.delete("SAMAGOTCHI_GUARDRAILS_PARENT_ANSWERS")
        Samagotchi::Config.reload!
      end

      it "marks its answers as chi answer's, so the worker checks them again with its own config" do
        s = asking(question)
        replies_after_answer(s, "ok")
        expect(run(s.id, "--question", "q1", "--option", "1")).to eq(0), err.string
        expect(clients).to eq(["cli:answer"])
      end

      context "when the worker refuses the allow (its config is stricter)" do
        let(:replies) do
          [[403, { error: "parent_answer_refused", reason: "permit",
                   detail: "allowing a tool call is up to the user: approve it in the web or chi --attach x" }]]
        end

        it "exits 1 with the worker's reason, in the JSON line too" do
          s = asking(approval)
          expect(run(s.id, "--question", "a1", "--option", "1", "--format", "json")).to eq(1)
          expect(posted.size).to eq(1)
          expect(json_out).to include("status" => "error",
                                      "detail" => "allowing a tool call is up to the user: approve it in the web or " \
                                                  "chi --attach x")
        end
      end

      it "under soft refuses even Allow once on an approval only the user may allow (user_only), before posting", local_only: PARENT_CHECK do
        s = asking(approval.merge(user_only: true))
        expect(run(s.id, "--question", "a1", "--option", "Allow once", "--timeout", "0.3")).to eq(1)
        expect(posted).to be_empty
        expect(err.string).to include("only the user can allow it")
      end

      it "holds a plugin's tagged question to the strategy: cost-cap's Continue refused under hard, its Stop goes", local_only: PARENT_CHECK do
        @parent_answers = "hard"
        cap = { id: "h1", kind: "hook", hook: "plugin.rb (bundle cost-cap)", header: "Cost cap",
                question: "Cost cap reached: $3.04 spent of $3.00. Continue raises it to $6.00.",
                options: %w[Continue Stop], effects: %w[spend deny], multi_select: false, allow_freeform: false,
                status: "pending" }
        s = asking(cap)
        expect(run(s.id, "--question", "h1", "--option", "Continue", "--timeout", "0.3")).to eq(1)
        expect(posted).to be_empty
        expect(err.string).to include("a parent agent may not pick Continue here (guardrails.parent_answers: hard): " \
                                      "answer Stop (--option Stop --text WHY)")

        replies_after_answer(s, "stopped")
        expect(run(s.id, "--question", "h1", "--option", "Stop")).to eq(0), err.string
        expect(posted).to eq([[:answer, "h1", ["Stop"], nil]])
      end

      it "under soft refuses an approval that doesn't offer once", local_only: PARENT_CHECK do
        s = asking(approval.merge(options: ["Allow this call for the session", "Deny"],
                                  approval: approval[:approval].merge(scopes: %w[session])))
        expect(run(s.id, "--question", "a1", "--option", "1", "--timeout", "0.3")).to eq(1)
        expect(posted).to be_empty
      end
    end

    # The answered turn's own reply, not a newer one of a turn queued behind
    # it (the reply files carry their turn's enqueued_id).
    describe "the turn it answers (turn ids)" do
      def session_dir(session) = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)

      def turn_reply(session, text, id)
        Samagotchi::SessionInbox.write_output(session_dir(session), text, enqueued_id: id)
      end

      def end_turn(session, id, outcome: "completed")
        t = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        t.status = "idle"
        t.pending_question = nil
        t.interrupted_turn = nil
        t.last_turn = Samagotchi::LastTurn.new(outcome: outcome, ended_at: Time.now.iso8601(3), enqueued_id: id)
        t.save(state_dir: tmpdir)
      end

      def running(session, id)
        t = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        t.status = "running"
        t.interrupted_turn = { "iteration" => 1, "enqueued_id" => id }
        t.save(state_dir: tmpdir)
      end

      it "prints the answered turn's reply when a queued turn behind it answers later (newer file)" do
        s = asking(question)
        running(s, "x1")
        threads << Thread.new do
          wait_for("the answer to be posted", timeout: 10) { posted.any? }
          sleep(0.05)
          turn_reply(s, "x1 answer", "x1")
          end_turn(s, "x1")
          running(s, "q1")
          turn_reply(s, "queued answer", "q1")
          end_turn(s, "q1")
        end
        # The queued turn's reply is there before the wait's first look.
        sleep(0.01)

        expect(run(s.id, "--question", "q1", "--option", "1")).to eq(0), err.string
        expect(out.string).to eq("x1 answer\n")
      end

      it "ends a Stop of a continue offer on that turn's not_continued, the queued turn's reply aside" do
        s = asking({ id: "c1", kind: "continue", question: "Continue it?", options: %w[Continue Stop] }, status: "idle")
        t = Samagotchi::Session.load(s.id, state_dir: tmpdir)
        t.last_turn = Samagotchi::LastTurn.new(outcome: "completed", exhausted: true, limit: 30, enqueued_id: "x1",
                                               ended_at: "2026-10-13T10:00:00.000Z")
        t.save(state_dir: tmpdir)
        Samagotchi::WorkerSidecar.new(port: 1, features: %w[delivery turn_ids]).write(session_dir(s))
        threads << Thread.new do
          wait_for("the answer to be posted", timeout: 10) { posted.any? }
          turn_reply(s, "queued answer", "q1")
          t = Samagotchi::Session.load(s.id, state_dir: tmpdir)
          t.pending_question = nil
          t.last_turn = Samagotchi::LastTurn.new(outcome: "not_continued", ended_at: Time.now.iso8601(3), enqueued_id: "x1")
          t.save(state_dir: tmpdir)
        end

        expect(run(s.id, "--question", "c1", "--option", "Stop", "--format", "json")).to eq(0), err.string
        expect(json_out).to include("status" => "not_continued")
      end

      it "waits for the next reply as before when the worker names no turn (no id on its mark)" do
        s = asking(question)
        running(s, nil)
        replies_after_answer(s, "next reply")

        expect(run(s.id, "--question", "q1", "--option", "1")).to eq(0), err.string
        expect(out.string).to eq("next reply\n")
      end
    end

    describe "a step-limit question (kind continue)" do
      let(:limit_question) do
        { id: "c1", kind: "continue", header: "Step limit", question: "The turn ran out of iterations (100 steps) before it answered. Continue it?",
          options: %w[Continue Stop], multi_select: false, allow_freeform: true, limit: 100, status: "pending" }
      end

      before do
        allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers") { @parent_answers || "soft" }
      end

      it "continues it, marked as chi answer's, and prints the continued turn's reply" do
        s = asking(limit_question, status: "idle")
        replies_after_answer(s, "Done after all.")

        expect(run(s.id, "--question", "c1", "--option", "Continue")).to eq(0), err.string
        expect(posted).to eq([[:answer, "c1", ["Continue"], nil]])
        expect(clients).to eq(["cli:answer"])
        expect(out.string).to eq("Done after all.\n")
      end

      it "continues it with a text, which goes to the desk with the answer (exit 0)" do
        s = asking(limit_question, status: "idle")
        replies_after_answer(s, "Done after all.")

        expect(run(s.id, "--question", "c1", "--option", "Continue", "--text", "also check X")).to eq(0), err.string
        expect(posted).to eq([[:answer, "c1", ["Continue"], "also check X"]])
        expect(out.string).to eq("Done after all.\n")
      end

      it "stops it with a reason" do
        s = asking(limit_question, status: "idle")
        threads << Thread.new do
          wait_for("the answer to be posted", timeout: 10) { posted.any? }
          t = Samagotchi::Session.load(s.id, state_dir: tmpdir)
          t.pending_question = nil
          t.last_turn = { "outcome" => "not_continued", "ended_at" => "2026-10-03T12:00:00.000+00:00" }
          t.save(state_dir: tmpdir)
        end

        expect(run(s.id, "--question", "c1", "--option", "Stop", "--text", "enough", "--format", "json")).to eq(0), err.string
        expect(posted).to eq([[:answer, "c1", ["Stop"], "enough"]])
        expect(json_out).to include("status" => "not_continued")
      end

      it "refuses Continue under guardrails.parent_answers: hard (stop-only parents), before posting", local_only: PARENT_CHECK do
        @parent_answers = "hard"
        s = asking(limit_question, status: "idle")

        expect(run(s.id, "--question", "c1", "--option", "Continue", "--timeout", "0.3")).to eq(1)
        expect(posted).to be_empty
        expect(err.string).to include("may only stop this turn").and include("guardrails.parent_answers: hard")
      end

      it "does not dismiss it: the turn waits on Continue or Stop" do
        s = asking(limit_question, status: "idle")

        expect(run(s.id, "--question", "c1", "--dismiss", "--timeout", "0.3")).to eq(1)
        expect(posted).to be_empty
        expect(err.string).to include("can't be dismissed: answer Continue or Stop")
      end

      it "reports the worker's 409 not_dismissable instead of waiting" do
        s = asking(question, status: "idle")
        replies.replace([[409, { error: "not_dismissable", detail: "answer Continue or Stop" }]])

        expect(run(s.id, "--question", "q1", "--dismiss", "--timeout", "2")).to eq(1)
        expect(err.string).to include("answer Continue or Stop")
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
end
