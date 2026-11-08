# frozen_string_literal: true

require "samagotchi/session"
require "samagotchi/system_one/client"
require "samagotchi/system_one/fake_backend"
require "samagotchi/system_one/recorder"

RSpec.describe Samagotchi::SystemOne::Recorder do
  let(:store) { Samagotchi::SystemOne::Runs::MemoryStore.new }
  let(:runs) { Samagotchi::SystemOne::Runs.new(store: store) }
  let(:client) { Samagotchi::SystemOne::Client.new(backend: Samagotchi::SystemOne::FakeBackend.new({}), mode: "on", host: "judge", tag: :toolkit) }
  let(:recorder) { described_class.new(runs: runs, session_model: "Gemma-4B-it") }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd).tap do |s|
      s.parent_id = "parent"
      s.test_run = true
    end
  end

  it "wraps the client with the session's context, the model and the use's mode" do
    wrapped = recorder.wrap(client, "toolkit.suggest", session, mode: "audit")

    expect(wrapped).to be_a(Samagotchi::SystemOne::Recording)
    wrapped.skip(state: { "x" => 1 }, questions: { "q" => Samagotchi::SystemOne::Question.new(id: "q", type: "noul", instructions: "?") },
                 reason: "busy")
    expect(store.lines["toolkit.suggest"].first).to include("session_id" => session.id, "chain_link" => "parent",
                                                            "session_model" => "Gemma-4B-it", "test_run" => true, "mode" => "audit")
  end

  it "names no model without a session" do
    expect(Samagotchi::SystemOne::Recording::Context).to receive(:of).with(nil, session_model: nil).and_call_original

    recorder.wrap(client, "toolkit.suggest", nil)
  end

  it "passes a nil client and a scratch session's client through" do
    expect(recorder.wrap(nil, "toolkit.suggest", session)).to be_nil
    expect(recorder.wrap(client, "toolkit.suggest", session.tap { |s| s.scratch = true })).to equal(client)
  end

  it "leaves the client as it was when the recording can't be set up, and says so" do
    allow(Samagotchi::SystemOne::Recording::Context).to receive(:of).and_raise("no context")
    allow(Samagotchi::Log).to receive(:warn)

    expect(recorder.wrap(client, "toolkit.suggest", session)).to equal(client)
    expect(Samagotchi::Log).to have_received(:warn).with(:system_one, "system_one_recording_failed", hash_including(error: "RuntimeError"))
  end

  it "says whether runs are saved; NONE saves none and passes every client through" do
    expect(recorder.saving?).to be(true)
    expect(described_class.new(runs: Samagotchi::SystemOne::Runs.new, session_model: "m").saving?).to be(false)
    expect(described_class::NONE.saving?).to be(false)
    expect(described_class::NONE.wrap(client, "toolkit.suggest", session)).to equal(client)
  end
end
