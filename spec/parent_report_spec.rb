# frozen_string_literal: true

require "json"
require "spec_helper"
require "samagotchi/parent_report"
require "samagotchi/reply_wait"

# What a parent agent reads when chi's wait ends: chi send --wait and
# chi answer, as JSON or as text on stderr.
RSpec.describe Samagotchi::ParentReport do

  let(:id) { "297da360-0000-4000-8000-000000000001" }

  let(:question) do
    { id: "q1", question: "Which file should I read?", options: %w[README.md Gemfile], multi_select: false,
      allow_freeform: false, status: "pending", created_at: "2026-10-02T10:00:00.000+02:00" }
  end

  let(:hook) do
    { id: "h1", question: "Push to main?", options: %w[Yes No], header: "deploy-guard", multi_select: false,
      allow_freeform: true, kind: "hook", hook: "deploy-guard", status: "pending" }
  end

  # The A3 shape: a guardrail's ask, as Approval.payload makes it and the
  # session file keeps it.
  let(:approval) do
    { id: "a1", question: "execute: echo SPIKE_APPROVED\n  in /w (not in a repo)\n  why: spike approval (rule spike-ask, config)",
      options: ["Allow once", "Allow this call for the session", "Allow this call in this directory",
                "Allow rule spike-ask in this directory", "Deny"],
      header: "Approve tool call?", multi_select: false, allow_freeform: true, kind: "approval",
      approval: { "tool" => "execute", "command" => "echo SPIKE_APPROVED", "cwd" => "/w", "rule" => "spike-ask",
                  "source" => "config", "reason" => "spike approval", "scopes" => %w[once session repo rule],
                  "preview" => { "diff" => "x" } },
      status: "pending" }
  end

  def json(result, timeout: nil)
    JSON.parse(described_class.json_line(result, session_id: id, timeout: timeout))
  end

  it "reports a reply as answered, exit 0" do
    result = Samagotchi::ReplyWait::Result.new(status: :done, text: "Read the file you picked. **Done**.", file: "x.txt")
    expect(json(result)).to eq("status" => "answered", "session_id" => id, "text" => "Read the file you picked. **Done**.")
    expect(described_class.exit_status(result)).to eq(0)
  end

  it "reports the model's question in full with the command that answers it, exit 3" do
    result = Samagotchi::ReplyWait::Result.new(status: :waiting_for_answer, question: question)
    expect(json(result)).to eq(
      "status" => "question", "session_id" => id,
      "question" => { "id" => "q1", "kind" => "question", "text" => "Which file should I read?",
                      "options" => %w[README.md Gemfile], "multi_select" => false, "allow_freeform" => false },
      "answer_with" => "chi answer #{id} --question q1 --option N"
    )
    expect(described_class.exit_status(result)).to eq(3)
  end

  it "keeps a hook's kind and header" do
    report = json(Samagotchi::ReplyWait::Result.new(status: :waiting_for_answer, question: hook))
    expect(report["question"]).to include("kind" => "hook", "header" => "deploy-guard", "allow_freeform" => true)
  end

  it "reports an approval with what it would run and its scopes, not the card's preview" do
    report = json(Samagotchi::ReplyWait::Result.new(status: :waiting_for_answer, question: approval))
    expect(report["answer_with"]).to eq("chi answer #{id} --question a1 --option Deny --text WHY")
    expect(report["question"]).to include("kind" => "approval", "header" => "Approve tool call?")
    expect(report["question"]["approval"]).to eq(
      "tool" => "execute", "command" => "echo SPIKE_APPROVED", "cwd" => "/w", "rule" => "spike-ask",
      "source" => "config", "reason" => "spike approval", "scopes" => %w[once session repo rule]
    )
  end

  it "maps every other end to its status and a detail line, exit 4 only while it still runs" do
    cases = {
      Samagotchi::ReplyWait::Result.new(status: :no_reply, outcome: "failed", text: "boom") => ["failed", "the turn failed: boom; chi --attach #{id} shows it", 1],
      Samagotchi::ReplyWait::Result.new(status: :no_reply, outcome: "canceled") => ["canceled", "the turn was canceled; chi --attach #{id} shows it", 1],
      Samagotchi::ReplyWait::Result.new(status: :no_reply, outcome: "completed") => ["no_answer", "the turn ended with no visible answer; chi --attach #{id} shows it", 1],
      Samagotchi::ReplyWait::Result.new(status: :no_reply) => ["no_answer", "the turn ended without a reply (canceled, failed or empty); chi --attach #{id} shows it", 1],
      Samagotchi::ReplyWait::Result.new(status: :error, text: "no model") => ["error", "the worker failed: no model; chi --attach #{id} shows what happened", 1],
      Samagotchi::ReplyWait::Result.new(status: :worker_gone) => ["worker_gone", "the worker is gone; chi --attach #{id} shows what happened", 1],
      Samagotchi::ReplyWait::Result.new(status: :stopped) => ["stopped", "the session was stopped (chi sessions stop)", 1],
      Samagotchi::ReplyWait::Result.new(status: :timeout) => ["running", "still running after 2.5 s: chi --attach #{id}", 4]
    }
    cases.each do |result, (status, detail, code)|
      expect(json(result, timeout: 2.5)).to eq("status" => status, "session_id" => id, "detail" => detail)
      expect(described_class.exit_status(result)).to eq(code)
    end
  end

  it "says a waiting approval is the user's to allow, a question where to open it" do
    approval_wait = Samagotchi::ReplyWait::Result.new(status: :waiting_for_answer, question: approval)
    expect(described_class.detail(approval_wait, session_id: id))
      .to eq("waiting for an approval: execute: echo SPIKE_APPROVED; deny it, and tell your user")
    question_wait = Samagotchi::ReplyWait::Result.new(status: :waiting_for_answer, question: question)
    expect(described_class.detail(question_wait, session_id: id))
      .to eq("waiting for an answer: Which file should I read?; open it: chi --attach #{id} or the web")
  end

  describe ".question_text" do
    it "lists the question, its numbered options and the commands that answer it" do
      expect(described_class.question_text(question, session_id: id)).to eq(<<~TEXT)
        waiting for an answer (question): Which file should I read?
            1. README.md
            2. Gemfile
          answer: chi answer #{id} --question q1 --option N
          or open it: chi --attach #{id} or the web
      TEXT
    end

    it "shows an approval's header and its whole text, and says free text is allowed" do
      expect(described_class.question_text(approval, session_id: id)).to eq(<<~TEXT)
        waiting for an answer (approval): Approve tool call?
          execute: echo SPIKE_APPROVED
            in /w (not in a repo)
            why: spike approval (rule spike-ask, config)
            1. Allow once
            2. Allow this call for the session
            3. Allow this call in this directory
            4. Allow rule spike-ask in this directory
            5. Deny
          allowing it is up to your user: deny it, and tell your user
          deny: chi answer #{id} --question a1 --option Deny --text WHY
          or leave it open: tell your user it waits in chi web (session #{id[0, 8]}); chi send --wait --format json #{id} waits until they answer
      TEXT
    end

    it "says a multi-select question takes more than one --option" do
      text = described_class.question_text(question.merge(multi_select: true), session_id: id)
      expect(text).to include("  more than one allowed: repeat --option\n")
    end
  end
end
