# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "support/test_kernel"
require "support/failing_saves"

require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/worker"
require "samagotchi/context_sources"

# A worker turns its attached context's changes into context notes between
# turns (ContextAbsorber), never into a session that has had no turn yet.
RSpec.describe Samagotchi::Worker, "attached context" do
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    WebMock.allow_net_connect! if defined?(WebMock)
    example.run
  ensure
    WebMock.disable_net_connect! if defined?(WebMock)
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  let(:tmpdir) { Dir.mktmpdir("worker-context-spec") }
  # Nested: the context root is next to the sessions dir.
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:history) { [{ role: "system", content: "sys" }, { role: "user", content: "a" }, { role: "model", content: "b" }] }
  let!(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
      s.messages = history
      s.save(state_dir: state_dir)
    end
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }
  let!(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
  let(:turns) { Queue.new }
  let(:events) { [] }
  let(:result) { instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false) }

  before do
    FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))
    allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    allow(engine).to receive(:start_idle)
    allow(engine).to receive(:stop_idle)
    allow(engine).to receive(:run_turn) do |turn_session, prompt, **|
      turns << [prompt, turn_session.messages.filter_map { |m| m[:context_source] }]
      result
    end
    engine.subscribe(observer: ->(event) { events << event })
  end

  after do
    @thread&.kill
    @thread&.join(2)
    FileUtils.rm_rf(tmpdir)
  end

  def start_worker(poll_interval: 0.05, idle_exit_minutes: 0)
    worker = described_class.new(session_id: session.id, state_dir: state_dir, session_dir: session_dir,
                                 idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval)
    @thread = Thread.new { worker.run }
    @thread.report_on_exception = false
    expect(wait_until { File.exist?(File.join(session_dir, Samagotchi::WorkerSidecar::FILE)) }).to be(true)
  end

  def attach(name, text)
    own.add(Samagotchi::ContextSources::Source.new(name: name, cmd: nil, every_seconds: nil, why: "spec", hint: nil,
                                                   scope: "session", added_by: "cli", created_at: nil))
    push(name, text)
  end

  def push(name, text)
    own.record_text(name, Samagotchi::ContextSources::Fetched.new(text: text, summary: nil, wake: false, hint: nil))
  end

  def saved_context_notes
    Samagotchi::Session.load(session.id, state_dir: state_dir).messages.select { |m| m[:context_source] }
  end

  it "adds an attached note while idle, saved and announced with its source, then an updated one; no turn runs" do
    start_worker

    attach("notes", "first")
    expect(wait_until { saved_context_notes.size == 1 }).to be(true)
    expect(saved_context_notes.first[:content]).to include("[CONTEXT NOTE from context notes", "Attached: notes. Why: spec.")
    expect(events).to include(include(type: :context_added, context_source: "notes", source: "context notes"))
    expect(wait_until { own.subscription("notes").seen }).to be_truthy

    push("notes", "second")
    expect(wait_until { saved_context_notes.size == 2 }).to be(true)
    expect(saved_context_notes.last[:content]).to include("Updated: notes.")
    expect(turns.pop(timeout: 0.3)).to be_nil
  end

  context "in a session with no turn yet" do
    let(:history) { [] }

    it "waits for the first prompt, and its turn sees the note" do
      start_worker
      attach("notes", "early")
      sleep(0.3)
      expect(saved_context_notes).to be_empty

      Samagotchi::SessionManager.write_turn_input(session.id, prompt: "hello", state_dir: state_dir)

      expect(turns.pop(timeout: 2)).to eq(["hello", ["notes"]])
    end

    it "still lets the session count as empty" do
      start_worker
      attach("notes", "early")
      sleep(0.3)

      expect(Samagotchi::SessionManager.empty_session?(session.id, state_dir: state_dir, default_model: "Gemma-4B-it"))
        .to be(true)
    end
  end

  it "doesn't preview a session by an attached context note" do
    start_worker
    attach("notes", "first")
    expect(wait_until { saved_context_notes.any? }).to be(true)

    reloaded = Samagotchi::Session.load(session.id, state_dir: state_dir)
    reloaded.messages = reloaded.messages.reject { |m| %w[user model].include?(m[:role].to_s) }
    reloaded.first_preview = nil
    reloaded.compute_first_preview!
    expect(reloaded.first_preview).to be_nil
  end

  describe "a failing save" do
    include_context "failing session saves"

    it "doesn't mark the change seen until a save holds the note" do
      start_worker
      saves_fail!

      attach("notes", "first")
      expect(wait_until { failed_saves.include?(:context) }).to be(true)
      expect(own.subscription("notes").seen).to be_nil

      saves_fail!(false)
      expect(wait_until { own.subscription("notes").seen }).to be_truthy
      expect(saved_context_notes.size).to eq(1)
    end
  end
end
