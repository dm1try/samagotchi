# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/guardrail_wiring"
require "samagotchi/system_one"

RSpec.describe "GuardrailWiring: System 1 on an approval (audit)" do
  S1 = Samagotchi::SystemOne

  let(:base) { File.realpath(Dir.mktmpdir("system-one-wiring")) }
  let(:state_dir) { File.join(base, "sessions") }
  let(:log_path) { File.join(base, "guardrails", "judgments.jsonl") }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: base).tap { |s| s.title = "work on P2a" }
  end
  let(:judge) { S1::FakeBackend.new { |_state, questions| questions.to_h { |question| [question.id, S1::Answer.new(id: question.id, type: :noul, noul: 0.97)] } } }
  let(:client) { S1::Client.new(backend: judge, mode: "audit", host: "splash", model: "judge-model") }
  let(:answer) { Samagotchi::QuestionAnswer.new(id: "q1", selected: ["Allow once"], selected_indices: [0]) }

  after { FileUtils.rm_rf(base) }

  def wiring(system_one: client, ask: ->(_payload) { answer })
    Samagotchi::GuardrailWiring.new(scratch: false, hooks: -> {}, tools: -> {}, session: -> { session },
                                    model_key: -> {}, cancelled: -> { false }, ask: ask,
                                    system_one: -> { system_one }, cancel_controller: -> {}).tap do |w|
      w.state_dir = state_dir
      w.interface = :worker
    end
  end

  def verdict_for(call = { name: "execute", content: "git push origin main" })
    verdict = Samagotchi::Guardrails::Verdict.new(call: call)
    verdict.ask!("pushes commits", rule: "git-push", source: "config", scopes: %w[once repo])
    verdict.context = Samagotchi::Guardrails::Context.new(cwd: base, session_id: session.id)
    verdict.targets = Samagotchi::Guardrails::Targets.for(verdict.call, verdict.context)
    verdict
  end

  def log_lines = File.exist?(log_path) ? File.readlines(log_path).map { |line| JSON.parse(line) } : []

  it "asks the user anyway and settles exactly as they answered" do
    w = wiring
    verdict = w.request_approval(verdict_for)
    expect(verdict).to be_allow
    expect(verdict.scope).to eq("once")
    expect(verdict.decided_by).to eq("user")

    lines = log_lines
    expect(lines.map { |line| line["kind"] }).to eq(%w[judgment label])
    expect(lines[0]).to include("id", "at", "rule" => "git-push", "source" => "config", "tool" => "execute",
                                "call" => "git push origin main", "p" => 0.97, "threshold" => 0.95,
                                "model" => "judge-model", "decision" => "audit", "origin" => "live")
    expect(lines[0]["session_id"]).to eq(session.id)
    expect(lines[0]["repo_name"]).to be_nil
    expect(lines[0]["call_digest"]).to eq(Digest::SHA256.hexdigest("git push origin main"))
    expect(lines[0]["latency_ms"]).to be_a(Integer)
    expect(lines[1]).to include("kind" => "label", "id" => lines[0]["id"], "answer" => "allow_once")
  end

  it "labels a wider scope allow_wide and a declined call deny" do
    wide = wiring(ask: ->(_) { Samagotchi::QuestionAnswer.new(id: "q1", selected: ["Allow this call in this repo (#{base})"], selected_indices: [1]) })
    verdict = wide.request_approval(verdict_for)
    expect([verdict.decision, verdict.scope]).to eq([:allow, "repo"])
    expect(log_lines.last["answer"]).to eq("allow_wide")

    refused = wiring(ask: ->(_) { Samagotchi::QuestionAnswer.new(id: "q1", selected: ["Deny"], selected_indices: [2], freeform: "not now") })
    verdict = refused.request_approval(verdict_for)
    expect(verdict).to be_deny
    expect(log_lines.last["answer"]).to eq("deny")
  end

  it "labels a cancelled ask none" do
    cancelled = wiring(ask: ->(_) {})
    verdict = cancelled.request_approval(verdict_for)
    expect(verdict).to be_deny
    expect(log_lines.map { |line| line["kind"] }).to eq(%w[judgment label])
    expect(log_lines.last["answer"]).to eq("none")
  end

  it "writes no label when a parent agent answered, since that is not the user" do
    parent = wiring(ask: ->(_) { Samagotchi::QuestionAnswer.new(id: "q1", selected: ["Allow once"], selected_indices: [0], by: "parent_agent") })
    verdict = parent.request_approval(verdict_for)
    expect(verdict).to be_allow
    kinds = log_lines.map { |line| line["kind"] }
    expect(kinds).to eq(["judgment"])
    expect(log_lines.last["answer"]).to be_nil
  end

  it "judges nothing for a participant's review turn" do
    w = wiring
    w.begin_turn({ client_id: "review:p_0123abcd", author: "p_0123abcd" })
    verdict = w.request_approval(verdict_for)
    expect(verdict).to be_allow
    expect(File.exist?(log_path)).to be false
  end

  it "judges nothing when there is no client (mode off), and still asks" do
    w = wiring(system_one: nil)
    verdict = w.request_approval(verdict_for)
    expect(verdict).to be_allow
    expect(File.exist?(log_path)).to be false
  end

  it "judges nothing in a non-interactive run: there is no one to ask" do
    w = wiring
    w.interface = :non_interactive
    verdict = w.request_approval(verdict_for)
    expect(verdict).to be_deny
    expect(File.exist?(log_path)).to be false
  end

  it "logs p nil when the judgment fails, and still asks the user" do
    allow(Samagotchi::Log).to receive(:warn)
    w = wiring(system_one: S1::Client.new(backend: S1::FakeBackend.new(failing: true, error: "the judge is asleep"), mode: "audit", host: "splash"))
    verdict = w.request_approval(verdict_for)
    expect(verdict).to be_allow
    expect(Samagotchi::Log).to have_received(:warn).with(:guardrails, "system_one_failed", hash_including(echo: /the judge is asleep/))
    judgment = log_lines.first
    expect(judgment["p"]).to be_nil
    expect(log_lines.last["answer"]).to eq("allow_once")
  end

  it "asks even when the log itself cannot be written" do
    FileUtils.mkdir_p(File.dirname(log_path))
    FileUtils.mkdir_p(log_path) # a directory where the judgments file wants to be
    allow(Samagotchi::Log).to receive(:warn)
    verdict = wiring.request_approval(verdict_for)
    expect(verdict).to be_allow
    expect(Samagotchi::Log).to have_received(:warn).with(:guardrails, "system_one_log_failed", anything)
  end

  it "sends the rule, the reason, the call and the diff to the judge" do
    states = []
    judge = S1::FakeBackend.new { |state, questions| states << state; questions.to_h { |q| [q.id, S1::Answer.new(id: q.id, type: :noul, noul: 0.4)] } }
    w = wiring(system_one: S1::Client.new(backend: judge, mode: "audit", host: "splash", model: "judge-model"))
    path = File.join(base, "notes.md")
    File.write(path, "one\n")
    verdict = w.request_approval(verdict_for({ name: "write", path: path, content: "one\ntwo\n" }))
    expect(verdict).to be_allow

    state = states.first
    expect(state).to include("rule" => "git-push", "reason" => "pushes commits", "tool" => "write",
                             "session" => "work on P2a", "cwd" => base)
    expect(state["change"]).to include("+two")
    expect(state["paths"]).to eq([path])
    expect(state["command"]).to be_nil

    judgment = log_lines.first
    expect(judgment["call"]).to eq(path)
    expect(judgment["call_digest"]).to eq(Digest::SHA256.hexdigest(path))
    expect(judgment["p"]).to eq(0.4)
  end

  it "cuts a long call in the log to 300 characters, digesting the whole of it" do
    long = "echo #{"a" * 400}"
    judgment = wiring.request_approval(verdict_for({ name: "execute", content: long }))
    expect(judgment).to be_allow
    line = log_lines.first
    expect(line["call"].length).to eq(300)
    expect(line["call"]).to eq("#{long[0, 299]}…")
    expect(line["call_digest"]).to eq(Digest::SHA256.hexdigest(long))
  end

  it "the instruction the judge is asked is the frozen constant" do
    asked = []
    judge = S1::FakeBackend.new { |_state, questions| asked << questions.first; questions.to_h { |q| [q.id, S1::Answer.new(id: q.id, type: :noul, noul: 0.9)] } }
    wiring(system_one: S1::Client.new(backend: judge, mode: "audit", host: "splash", model: "judge-model")).request_approval(verdict_for)
    expect(asked.first).to have_attributes(id: "allow", type: :noul)
    expect(asked.first.instructions).to eq(S1::ApprovalQuestion::INSTRUCTIONS)
    expect(asked.first.instructions).to include("without hesitation")
  end
end
