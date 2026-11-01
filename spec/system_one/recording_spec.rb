# frozen_string_literal: true

require "samagotchi/system_one"

RSpec.describe Samagotchi::SystemOne::Recording do
  let(:s1) { Samagotchi::SystemOne }
  let(:store) { s1::Runs::MemoryStore.new }
  let(:runs) { s1::Runs.new(store: store) }
  let(:questions) { { "allow" => { "type" => "noul", "instructions" => "Allow it?" } } }
  let(:answer) { s1::Answer.new(id: "allow", type: :noul, noul: 0.9) }
  let(:backend) { s1::FakeBackend.new({ "allow" => answer }) }
  let(:client) { s1::Client.new(backend: backend, mode: "audit", host: "judge", model: "jev") }
  let(:context) do
    described_class::Context.new(session_id: "s1", chain_link: "s0", session_model: "big", test_run: true)
  end

  def recording(wrapped = client, runs: self.runs)
    described_class.wrap(wrapped, judgment: "approvals.allow", runs: runs, context: context)
  end

  def line = store.lines["approvals.allow"].last

  it "is nil for no client, so the caller's check stays" do
    expect(described_class.wrap(nil, judgment: "x", runs: runs)).to be_nil
  end

  it "has the client's duck type" do
    expect(recording).to have_attributes(host: "judge", model: "jev", mode: "audit", backend: backend)
  end

  it "returns the client's answers and saves what was sent and answered" do
    expect(recording.ask(state: { "command" => "git push" }, questions: questions)).to eq("allow" => answer)
    expect(line).to include("kind" => "run", "judgment" => "approvals.allow", "asked" => true, "origin" => "live",
                            "state" => { "command" => "git push" }, "host" => "judge", "model" => "jev", "mode" => "audit",
                            "session_id" => "s1", "chain_link" => "s0", "session_model" => "big", "test_run" => true)
    expect(line["id"]).to match(%r{\Aapprovals\.allow/\h{8}-})
    expect(line["answers"]["allow"]).to include("type" => "noul", "noul" => 0.9)
    expect(line["instructions_digest"]).to match(/\A\h{16}\z/)
    expect(line["latency_ms"]).to be_a(Integer)
    expect(line).not_to have_key("failure")
  end

  it "uses the run id it is given: one client serves several threads" do
    recording.ask(state: "x", questions: questions, run_id: "approvals.allow/given")
    expect(line["id"]).to eq("approvals.allow/given")
  end

  it "saves why there was no judgment, and still answers nil" do
    failing = s1::Client.new(backend: s1::FakeBackend.new(failing: true, error: "asleep"), mode: "on", host: "judge")
    allow(Samagotchi::Log).to receive(:warn)
    expect(recording(failing).ask(state: "x", questions: questions)).to be_nil
    expect(line).to include("failure" => "Samagotchi::SystemOne::BackendError", "failure_text" => a_string_matching(/asleep/))
    expect(line).not_to have_key("answers")
  end

  it "says an answer that doesn't cover the questions is no_answer" do
    allow(Samagotchi::Log).to receive(:warn)
    empty = s1::Client.new(backend: s1::FakeBackend.new({}), mode: "on", host: "judge")
    expect(recording(empty).ask(state: "x", questions: questions)).to be_nil
    expect(line).to include("failure" => "no_answer")
  end

  it "saves a cancelled ask, then raises as before" do
    cancelled = s1::Client.new(backend: s1::FakeBackend.new { raise Samagotchi::LLM::RequestCancelled, "stop" }, mode: "on", host: "judge")
    expect { recording(cancelled).ask(state: "x", questions: questions) }.to raise_error(Samagotchi::LLM::RequestCancelled)
    expect(line).to include("failure" => "cancelled")
  end

  it "saves an unexpected raise from the client, then raises as before" do
    raising = instance_double(s1::Client, host: "judge")
    allow(raising).to receive(:ask).and_raise("boom")
    expect { recording(raising).ask(state: "x", questions: questions) }.to raise_error("boom")
    expect(line).to include("failure" => "RuntimeError", "failure_text" => "boom", "host" => "judge")
  end

  it "keeps the answer when the run can't be saved: one warn" do
    broken = s1::Runs.new(store: Class.new { def append(*) = raise(IOError, "disk full") }.new)
    expect(Samagotchi::Log).to receive(:warn).with(:system_one, "system_one_run_failed", hash_including(echo: /disk full/)).once
    expect(recording(runs: broken).ask(state: "x", questions: questions)).to eq("allow" => answer)
  end

  it "scrubs bytes that aren't UTF-8 in the copy saved, and leaves what was sent alone" do
    sent = { "command" => +"caf\xE9" }
    seen = nil
    wrapped = s1::Client.new(backend: s1::FakeBackend.new { |state, _q| (seen = state) && { "allow" => answer } }, mode: "on", host: "judge")
    recording(wrapped).ask(state: sent, questions: questions)
    expect(JSON.generate(line["state"])).to include("caf�")
    expect(seen["command"].bytes).to eq("caf\xE9".bytes)
  end

  it "saves no run when there was nothing to ask" do
    expect(recording.ask(state: "x", questions: {})).to be_nil
    expect(store.lines).to be_empty
  end

  it "keeps the answer when the state is nested too deep to copy: one warn" do
    deep = []
    200_000.times { deep = [deep] }
    expect(Samagotchi::Log).to receive(:warn).with(:system_one, "system_one_run_failed", anything).once
    expect(recording.ask(state: deep, questions: questions)).to eq("allow" => answer)
  end

  it "saves nothing and asks as before without a store" do
    off = s1::Runs.new
    expect(off).not_to receive(:record)
    expect(recording(runs: off).ask(state: "x", questions: questions)).to eq("allow" => answer)
    expect(backend.calls).to eq(1)
  end

  it "saves what an http backend tells it: the resolved and served model, the raw answers, the usage" do
    fake = Class.new do
      define_method(:ask) do |state:, questions:, cancel_controller: nil, observer: nil|
        _ = [state, questions, cancel_controller]
        observer&.call(model: "resolved")
        observer&.call(served_model: "served", raw: { "allow" => { "type" => "noul", "noul" => 0.9, "extra" => 1 } },
                       usage: { "input_tokens" => 3 })
        { "allow" => Samagotchi::SystemOne::Answer.new(id: "allow", type: :noul, noul: 0.9) }
      end
    end.new
    recording(s1::Client.new(backend: fake, mode: "on", host: "judge")).ask(state: "x", questions: questions)
    expect(line).to include("model" => "resolved", "served_model" => "served", "usage" => { "input_tokens" => 3 })
    expect(line["answers"]["allow"]["extra"]).to eq(1)
  end

  describe "Context.of" do
    it "takes the parent, else the session continued" do
      session = Struct.new(:id, :parent_id, :continues, :test_run)
      expect(described_class::Context.of(session.new("a", "p", "c", false)).to_h)
        .to include("session_id" => "a", "chain_link" => "p", "test_run" => nil)
      expect(described_class::Context.of(session.new("a", nil, "c", true)).to_h)
        .to include("chain_link" => "c", "test_run" => true)
      expect(described_class::Context.of(nil).session_id).to be_nil
    end
  end
end
