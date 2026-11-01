# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/guardrail_wiring"
require "samagotchi/system_one"

# An approval's saved run: one id with its judgments line, and what came of it.
RSpec.describe "GuardrailWiring: System 1's saved runs" do
  let(:s1) { Samagotchi::SystemOne }
  let(:base) { File.realpath(Dir.mktmpdir("wiring-runs")) }
  let(:store) { s1::Runs::MemoryStore.new }
  let(:runs) { s1::Runs.new(store: store) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: base) }
  let(:judge) { s1::FakeBackend.new { |_state, questions| questions.to_h { |question| [question.id, s1::Answer.new(id: question.id, type: :noul, noul: 0.97)] } } }
  let(:once) { Samagotchi::QuestionAnswer.new(id: "q1", selected: ["Allow once"], selected_indices: [0]) }

  after { FileUtils.rm_rf(base) }

  def wiring(client, ask: ->(_payload) { once })
    recording = s1::Recording.wrap(client, judgment: s1::ApprovalQuestion::JUDGMENT, runs: runs)
    Samagotchi::GuardrailWiring.new(scratch: false, hooks: -> {}, tools: -> {}, session: -> { session }, model_key: -> {},
                                    cancelled: -> { false }, ask: ask, system_one: -> { recording }, system_one_runs: -> { runs },
                                    cancel_controller: -> {}).tap do |w|
      w.state_dir = File.join(base, "sessions")
      w.interface = :worker
    end
  end

  def verdict_for(rule: "git-push")
    verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "execute", content: "git push origin main" })
    verdict.ask!("pushes commits", rule: rule, source: "config", scopes: %w[once repo])
    verdict.context = Samagotchi::Guardrails::Context.new(cwd: base, session_id: session.id)
    verdict.targets = Samagotchi::Guardrails::Targets.for(verdict.call, verdict.context)
    verdict
  end

  def judgments = s1::Log.new(dir: File.join(base, "guardrails")).entries
  def lines(kind) = store.lines["approvals.allow"].select { |line| line["kind"] == kind }

  it "shares one id between the run and the judgments line, and saves the answer as a strong label" do
    wiring(s1::Client.new(backend: judge, mode: "audit", host: "splash", model: "jev")).request_approval(verdict_for)
    id = lines("run").first["id"]
    expect(id).to start_with("approvals.allow/")
    expect(judgments.first["id"]).to eq(id)
    expect(lines("label").first).to include("run_id" => id, "value" => "allow_once", "by" => "user", "strength" => "strong", "question" => "allow")
    expect(lines("acted").first).to include("run_id" => id, "what" => "audit")
  end

  it "saves the gates as they were at the ask" do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("guardrails.system_one.rules").and_return("git-push")
    allow(s1::SelfProtect).to receive(:refuse?).and_return(true)
    wiring(s1::Client.new(backend: judge, mode: "audit", host: "splash")).request_approval(verdict_for)
    expect(lines("gates").first).to include("rule" => "git-push", "rule_listed" => true, "self_protect_refused" => true, "threshold" => 0.8)
  end

  it "says an unlisted rule was unlisted" do
    wiring(s1::Client.new(backend: judge, mode: "audit", host: "splash")).request_approval(verdict_for(rule: "other"))
    expect(lines("gates").first).to include("rule_listed" => false)
  end

  it "saves none for a cancelled ask's answer as an answer" do
    wiring(s1::Client.new(backend: judge, mode: "on", host: "splash"), ask: ->(_) {}).request_approval(verdict_for)
    expect(lines("label").first).to include("value" => "none", "by" => "none")
    expect(lines("label").first).not_to have_key("strength")
  end

  it "changes nothing the user sees when the gates can't be read" do
    allow(s1::SelfProtect).to receive(:refuse?).and_raise("no")
    allow(Samagotchi::Log).to receive(:warn)
    verdict = wiring(s1::Client.new(backend: judge, mode: "audit", host: "splash")).request_approval(verdict_for)
    expect(verdict).to be_allow
    expect(Samagotchi::Log).to have_received(:warn).with(:guardrails, "system_one_run_facts_failed", anything)
    expect(lines("label").size).to eq(1)
  end

  it "hangs nothing on a scratch session's ask: no run, no gates, no label" do
    session.scratch = true
    runs_file = s1::Runs.new(store: store)
    w = Samagotchi::GuardrailWiring.new(scratch: true, hooks: -> {}, tools: -> {}, session: -> { session }, model_key: -> {},
                                        cancelled: -> { false }, ask: ->(_) { once },
                                        system_one: -> { s1::Client.new(backend: judge, mode: "audit", host: "splash") },
                                        system_one_runs: -> { runs_file }, cancel_controller: -> {})
    w.state_dir = File.join(base, "sessions")
    w.interface = :worker
    w.request_approval(verdict_for)
    expect(store.lines).to be_empty
    expect(judgments.first["id"]).not_to include("/")
  end

  it "denies an agent's write to the saved runs, on the state dir it is wired to" do
    w = wiring(s1::Client.new(backend: judge, mode: "audit", host: "splash"))
    verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "write", path: File.join(base, "system_one", "runs", "x.jsonl"), content: "x" })
    verdict.context = Samagotchi::Guardrails::Context.new(cwd: base, session_id: session.id)
    verdict.targets = Samagotchi::Guardrails::Targets.for(verdict.call, verdict.context)
    w.send(:protected_paths).check(verdict)
    expect([verdict.decision, verdict.rule]).to eq([:deny, "system-one-runs"])
  end

  it "reads no gate with runs off" do
    off = s1::Runs.new
    w = Samagotchi::GuardrailWiring.new(scratch: false, hooks: -> {}, tools: -> {}, session: -> { session }, model_key: -> {},
                                        cancelled: -> { false }, ask: ->(_) { once },
                                        system_one: -> { s1::Client.new(backend: judge, mode: "audit", host: "splash") },
                                        system_one_runs: -> { off }, cancel_controller: -> {})
    w.state_dir = File.join(base, "sessions")
    w.interface = :worker
    expect(s1::SelfProtect).not_to receive(:refuse?)
    expect(w.request_approval(verdict_for)).to be_allow
  end
end
