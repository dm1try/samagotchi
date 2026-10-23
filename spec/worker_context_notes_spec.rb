# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "support/test_kernel"
require "support/failing_saves"
require "support/worker_loop_rounds"

require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/worker"

# A worker takes context notes from notes/ between turns: each becomes a
# tail system message, saved at once, and no turn runs for it.
RSpec.describe Samagotchi::Worker, "context notes" do
  include WorkerLoopRounds

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
    Samagotchi::Engine.new(client: test_client,
                           kernel: test_kernel)
  end
  let(:turns) { Queue.new }
  let(:events) { [] }
  let(:result) { instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false) }

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

  def start_worker(poll_interval: 0.05, idle_exit_minutes: 0)
    worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                 idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval)
    count_loop_rounds(worker)
    @thread = Thread.new { worker.run }
    @thread.report_on_exception = false
    wait_for("the worker's sidecar") { File.exist?(File.join(session_dir, Samagotchi::WorkerSidecar::FILE)) }
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

    wait_for("the note to be saved") { saved_notes.any? }
    note = saved_notes.first
    expect(note[:note_id]).to eq(File.basename(path, ".json"))
    expect(note[:content]).to include("[CONTEXT NOTE from slack", "deploy frozen")
    expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).messages.map { |m| m[:content] }.first(3)).to eq(%w[sys a b])
    expect(events.map { |e| e[:type] }).to include(:context_added)
    # The worker deletes the note files after it saved the session.
    wait_for("the worker to delete the note files") { Dir.empty?(notes_dir) }
    loop_rounds
    expect(turns).to be_empty
  end

  describe "a failing save" do
    include_context "failing session saves"

    # Disk full: the note is in memory, and its file stays (claimed) until
    # a save holds it, so a worker that dies first doesn't lose it.
    it "stays up, keeps the note's file, and saves the note once a save works" do
      start_worker
      saves_fail!

      path = write_note("deploy frozen")

      wait_for("the notes save to fail") { failed_saves.include?(:notes) }
      expect(@thread).to be_alive
      expect(Dir.children(notes_dir)).to eq(["#{File.basename(path)}.processing"])

      saves_fail!(false)
      wait_for("the note's file to go once a save works") { Dir.empty?(notes_dir) }
      expect(saved_notes.map { |m| m[:note_id] }).to eq([File.basename(path, ".json")])
      expect(events.count { |e| e[:type] == :context_added }).to eq(1)
    end
  end

  it "takes a note sent during a turn after that turn, and the next turn sees it" do
    release = Queue.new
    boundary = Queue.new
    allow(engine).to receive(:run_turn) do |turn_session, prompt, pending_input: nil, **|
      turns << [prompt, turn_session.messages.map { |m| m[:note_id] }.compact]
      if prompt == "one"
        release.pop
        # An iteration boundary after the note came: the only place a turn
        # takes input mid-turn.
        boundary << pending_input.call
        release.pop
      end
      result
    end
    start_worker

    Samagotchi::SessionManager.write_turn_input(session.id, prompt: "one", state_dir: tmpdir)
    expect(pop!(turns, "the first turn")).to eq(["one", []])
    path = write_note("api moved")
    release << true
    expect(pop!(boundary, "the turn's iteration boundary")).to eq([])
    expect(engine.messages_checkpoint.none? { |m| m[:kind] == "note" }).to be(true)
    release << true

    wait_for("the note to be saved after the turn") { saved_notes.any? }
    Samagotchi::SessionManager.write_turn_input(session.id, prompt: "two", state_dir: tmpdir)
    expect(pop!(turns, "the second turn")).to eq(["two", [File.basename(path, ".json")]])
  end

  it "takes notes that waited for the worker before it runs anything else" do
    path = write_note("waited")
    Samagotchi::SessionManager.write_turn_input(session.id, prompt: "hello", state_dir: tmpdir)

    start_worker

    expect(pop!(turns, "the queued turn")).to eq(["hello", [File.basename(path, ".json")]])
  end

  it "still runs a new session's first prompt when a note came first" do
    session.messages = []
    session.last_prompt = "first prompt"
    session.save(state_dir: tmpdir)
    path = write_note("early")

    start_worker

    expect(pop!(turns, "the first prompt's turn")).to eq(["first prompt", [File.basename(path, ".json")]])
  end

  it "still runs the first prompt of a session that holds only a note (a worker restarted before it ran)" do
    session.messages = [Samagotchi::ContextNote.message(note_id: "n0", text: "early", source: "cli")]
    session.last_prompt = "first prompt"
    session.save(state_dir: tmpdir)

    start_worker

    expect(pop!(turns, "the first prompt's turn").first).to eq("first prompt")
  end

  it "doesn't add a note twice when a crash left it claimed after the save" do
    path = write_note("once")
    claimed = Samagotchi::SessionInbox.claim_note_file(path)
    note_id = File.basename(path, ".json")
    session.messages += [Samagotchi::ContextNote.message(note_id: note_id, text: "once", source: "cli")]
    session.save(state_dir: tmpdir)

    start_worker

    wait_for("the claimed note file to go") { !File.exist?(claimed) }
    expect(saved_notes.count { |m| m[:note_id] == note_id }).to eq(1)
    expect(events.map { |e| e[:type] }).not_to include(:context_added)
  end

  it "drops a note file that holds no note" do
    FileUtils.mkdir_p(notes_dir)
    File.write(File.join(notes_dir, "20260101000000000000000-abcdef.json"), "{broken")

    start_worker

    wait_for("the broken note file to go") { Dir.empty?(notes_dir) }
    expect(saved_notes).to be_empty
  end

  it "doesn't keep an idle worker up (a note is not activity)" do
    start_worker(idle_exit_minutes: 0.005)
    write_note("still leaves")

    expect(join!(@thread, "the worker's idle exit").value).to eq(:idle_exit)
    expect(saved_notes.size).to eq(1)
  end
end
