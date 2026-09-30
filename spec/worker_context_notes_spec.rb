# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"

require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/worker"

# A worker takes context notes from notes/ between turns: each becomes a
# tail system message, saved at once, and no turn runs for it.
RSpec.describe Samagotchi::Worker, "context notes" do
  def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def wait_until(timeout: 2)
    deadline = mono + timeout
    sleep(0.01) until yield || mono > deadline
    yield
  end

  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    WebMock.allow_net_connect! if defined?(WebMock)
    example.run
  ensure
    WebMock.disable_net_connect! if defined?(WebMock)
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  let(:tmpdir) { Dir.mktmpdir("worker-notes-spec") }
  let!(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
      s.messages = [{ role: "system", content: "sys" }, { role: "user", content: "a" }, { role: "model", content: "b" }]
      s.save(state_dir: tmpdir)
    end
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
  let(:notes_dir) { File.join(session_dir, Samagotchi::SessionInbox::NOTES_DIR) }
  let!(:engine) do
    Samagotchi::Engine.new(client: instance_double(Samagotchi::Client),
                           kernel: instance_double(Samagotchi::KernelLoop))
  end
  let(:turns) { Queue.new }
  let(:events) { [] }
  let(:result) { instance_double(Samagotchi::KernelLoop::Result, output: "") }

  before do
    FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))
    allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    allow(engine).to receive(:start_idle)
    allow(engine).to receive(:stop_idle)
    allow(engine).to receive(:run_turn) do |turn_session, prompt, **|
      turns << [prompt, turn_session.messages.map { |m| m[:note_id] }.compact]
      result
    end
    engine.subscribe(observer: ->(event) { events << event })
  end

  after do
    @thread&.kill
    @thread&.join(2)
    FileUtils.rm_rf(tmpdir)
  end

  # The worker's exit is caught on its thread (see worker_spec): a SystemExit
  # leaving a thread ends the whole rspec run early, green.
  def start_worker(poll_interval: 0.05, idle_exit_minutes: 0)
    worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                 idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval)
    @thread = Thread.new do
      worker.run
    rescue SystemExit => e
      e
    end
    @thread.report_on_exception = false
    expect(wait_until { File.exist?(File.join(session_dir, Samagotchi::WorkerSidecar::FILE)) }).to be(true)
  end

  def write_note(text, **opts)
    Samagotchi::SessionInbox.write_note(session.id, text: text, state_dir: tmpdir, **opts)
  end

  def saved_notes
    Samagotchi::Session.load(session.id, state_dir: tmpdir).messages.select { |m| m[:kind] == "note" }
  end

  it "takes a note while idle: saved as a tail message, announced, and no turn runs" do
    start_worker

    path = write_note("deploy frozen", source: "slack")

    expect(wait_until { saved_notes.any? }).to be(true)
    note = saved_notes.first
    expect(note[:note_id]).to eq(File.basename(path, ".json"))
    expect(note[:content]).to include("[CONTEXT NOTE from slack", "deploy frozen")
    expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).messages.map { |m| m[:content] }.first(3)).to eq(%w[sys a b])
    expect(events.map { |e| e[:type] }).to include(:context_added)
    expect(Dir.children(notes_dir)).to be_empty
    expect(turns.pop(timeout: 0.3)).to be_nil
  end

  it "takes a note sent during a turn after that turn, and the next turn sees it" do
    release = Queue.new
    allow(engine).to receive(:run_turn) do |turn_session, prompt, **|
      turns << [prompt, turn_session.messages.map { |m| m[:note_id] }.compact]
      release.pop if prompt == "one"
      result
    end
    start_worker

    Samagotchi::SessionManager.write_turn_input(session.id, prompt: "one", state_dir: tmpdir)
    expect(turns.pop(timeout: 2)).to eq(["one", []])
    path = write_note("api moved")
    sleep(0.2)
    expect(engine.messages_checkpoint.none? { |m| m[:kind] == "note" }).to be(true)
    release << true

    expect(wait_until { saved_notes.any? }).to be(true)
    Samagotchi::SessionManager.write_turn_input(session.id, prompt: "two", state_dir: tmpdir)
    expect(turns.pop(timeout: 2)).to eq(["two", [File.basename(path, ".json")]])
  end

  it "takes notes that waited for the worker before it runs anything else" do
    path = write_note("waited")
    Samagotchi::SessionManager.write_turn_input(session.id, prompt: "hello", state_dir: tmpdir)

    start_worker

    expect(turns.pop(timeout: 2)).to eq(["hello", [File.basename(path, ".json")]])
  end

  it "still runs a new session's first prompt when a note came first" do
    session.messages = []
    session.last_prompt = "first prompt"
    session.save(state_dir: tmpdir)
    path = write_note("early")

    start_worker

    expect(turns.pop(timeout: 2)).to eq(["first prompt", [File.basename(path, ".json")]])
  end

  it "still runs the first prompt of a session that holds only a note (a worker restarted before it ran)" do
    session.messages = [Samagotchi::ContextNote.message(note_id: "n0", text: "early", source: "cli")]
    session.last_prompt = "first prompt"
    session.save(state_dir: tmpdir)

    start_worker

    expect(turns.pop(timeout: 2)&.first).to eq("first prompt")
  end

  it "doesn't add a note twice when a crash left it claimed after the save" do
    path = write_note("once")
    claimed = Samagotchi::SessionInbox.claim_note_file(path)
    note_id = File.basename(path, ".json")
    session.messages += [Samagotchi::ContextNote.message(note_id: note_id, text: "once", source: "cli")]
    session.save(state_dir: tmpdir)

    start_worker

    expect(wait_until { !File.exist?(claimed) }).to be(true)
    expect(saved_notes.count { |m| m[:note_id] == note_id }).to eq(1)
    expect(events.map { |e| e[:type] }).not_to include(:context_added)
  end

  it "drops a note file that holds no note" do
    FileUtils.mkdir_p(notes_dir)
    File.write(File.join(notes_dir, "20260101000000000000000-abcdef.json"), "{broken")

    start_worker

    expect(wait_until { Dir.children(notes_dir).empty? }).to be(true)
    expect(saved_notes).to be_empty
  end

  it "doesn't keep an idle worker up (a note is not activity)" do
    start_worker(idle_exit_minutes: 0.005)
    write_note("still leaves")

    expect(@thread.join(3)&.value).to eq(:idle_exit)
    expect(saved_notes.size).to eq(1)
  end
end
