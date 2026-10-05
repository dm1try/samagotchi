# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/worker"

# The worker's side of delegate reports: a delegate child's turns ring its
# parent (ChildRing), and a parent's turns take its children's reports at
# their iteration boundaries (ChildReports), committed when the turn is kept.
RSpec.describe Samagotchi::Worker, "delegate reports" do
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    WebMock.allow_net_connect! if defined?(WebMock)
    example.run
  ensure
    WebMock.disable_net_connect! if defined?(WebMock)
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  let(:tmpdir) { Dir.mktmpdir("worker-reports") }
  let!(:parent) { save(Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir)) }
  let(:parent_dir) { Samagotchi::Session.session_dir(parent.id, state_dir: tmpdir) }
  let!(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
  let(:turns) { Queue.new }
  let(:events) { Queue.new }
  let(:result) { instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false) }
  let(:wakes) { [] }

  before do
    allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    allow(engine).to receive(:start_idle)
    allow(engine).to receive(:stop_idle)
    allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
      turns << [prompt, kwargs]
      result
    end
    allow(Samagotchi::SessionManager).to receive(:wake_for_report) { |id, **| wakes << id }
    engine.subscribe(observer: ->(event) { events << event })
  end

  after do
    @thread&.kill
    @thread&.join(2)
    FileUtils.rm_rf(tmpdir)
  end

  def save(session)
    session.save(state_dir: tmpdir)
    FileUtils.mkdir_p(File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), "input"))
    session
  end

  def make_child(prompt: "")
    child = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir,
                                            parent_id: parent.id, delegate: true)
    child.last_prompt = prompt
    save(child)
  end

  def start_worker(session, poll_interval: 0.1)
    dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
    worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: dir, idle_exit_minutes: 0,
                                 poll_interval: poll_interval)
    @thread = Thread.new { worker.run }
    @thread.report_on_exception = false
    expect(wait_until { File.exist?(File.join(dir, Samagotchi::WorkerSidecar::FILE)) }).to be(true)
    worker
  end

  def send_turn(session, prompt, client_id)
    Samagotchi::SessionManager.write_turn_input(session.id, prompt: prompt, client_id: client_id, state_dir: tmpdir)
  end

  def rings = Samagotchi::SessionInbox.find_ring_files(parent_dir)
  def ring_whys = rings.map { |f| Samagotchi::SessionInbox.read_ring(f)[:why] }

  def question(kind)
    engine.instance_variable_get(:@session_observer)
          .notify(type: :question_requested, pending_question: { id: "q-#{kind}", kind: kind, question: "?" }.compact)
  end

  def next_turn(timeout: 3) = turns.pop(timeout: timeout)

  describe "a delegate child" do
    it "rings its parent after its first turn (the parent's task) is saved, and wakes a parent with no worker" do
      child = make_child(prompt: "count the specs")
      start_worker(child)

      expect(next_turn&.first).to eq("count the specs")
      expect(wait_until { ring_whys == ["turn_end"] }).to be(true)
      expect(Samagotchi::SessionInbox.read_ring(rings.first)[:child_id]).to eq(child.id)
      expect(wait_until { wakes == [parent.id] }).to be(true)
    end

    it "rings after a follow-up from its parent, not after a turn the user typed into it" do
      child = make_child
      start_worker(child)

      send_turn(child, "from the web", "web:tab1")
      expect(next_turn&.first).to eq("from the web")
      sleep(0.2)
      expect(rings).to be_empty

      send_turn(child, "and the second?", "delegate:#{parent.id[0, 8]}")
      expect(next_turn&.first).to eq("and the second?")
      expect(wait_until { ring_whys == ["turn_end"] }).to be(true)
    end

    it "rings on the model's question and the continue offer in its parent's turn, not on an approval or a hook's" do
      child = make_child
      allow(engine).to receive(:run_turn) do |_session, prompt, **|
        %w[approval hook].each { |kind| question(kind) }
        question(nil)
        turns << [prompt]
        result
      end
      start_worker(child)
      send_turn(child, "go", "delegate:#{parent.id[0, 8]}")

      expect(next_turn&.first).to eq("go")
      expect(wait_until { ring_whys == %w[question turn_end] }).to be(true)
    end

    it "rings after a turn that follows a question it rang about, whoever starts that turn (D10)" do
      child = make_child
      allow(engine).to receive(:run_turn) do |session, prompt, **|
        if prompt == "go"
          session.pending_question = { id: "c1", kind: "continue", question: "Continue it?" }
          question("continue")
        else
          session.pending_question = nil
        end
        turns << [prompt]
        result
      end
      start_worker(child)
      send_turn(child, "go", "delegate:#{parent.id[0, 8]}")
      expect(wait_until { ring_whys == %w[question turn_end] }).to be(true)
      rings.each { |f| File.delete(f) }

      send_turn(child, "answered on the web", "web:tab1")
      expect(next_turn(timeout: 3)&.first).to eq("go")
      expect(next_turn&.first).to eq("answered on the web")
      expect(wait_until { ring_whys == ["turn_end"] }).to be(true)
      rings.each { |f| File.delete(f) }

      # Settled: the user's next turn is the user's again.
      send_turn(child, "another", "web:tab1")
      expect(next_turn&.first).to eq("another")
      sleep(0.2)
      expect(rings).to be_empty
    end

    it "doesn't ring when delegate_reports is off" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("session.delegate_reports").and_return("off")
      child = make_child(prompt: "task")
      start_worker(child)

      expect(next_turn&.first).to eq("task")
      sleep(0.2)
      expect(rings).to be_empty
    end

    it "never rings for a fork" do
      fork = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir,
                                             parent_id: parent.id)
      fork.last_prompt = "seeded"
      save(fork)
      start_worker(fork)

      expect(next_turn&.first).to eq("seeded")
      sleep(0.2)
      expect(rings).to be_empty
    end
  end

  describe "a parent" do
    let(:child) { make_child }
    let(:child_dir) { Samagotchi::Session.session_dir(child.id, state_dir: tmpdir) }

    # The child's turn ended with +text+ and rang.
    def child_answers(text)
      Samagotchi::Tools::DelegateWait.mark_started(parent.id, child, state_dir: tmpdir)
      Samagotchi::SessionInbox.write_output(child_dir, text)
      s = Samagotchi::Session.load(child.id, state_dir: tmpdir)
      s.last_turn = { "outcome" => "completed", "ended_at" => Time.now.iso8601(6) }
      s.save(state_dir: tmpdir)
      Samagotchi::SessionInbox.write_ring(parent_dir, child_id: child.id, why: "turn_end")
    end

    def cursor = Samagotchi::Tools::DelegateCursors.get(parent.id, child.id, state_dir: tmpdir)

    it "merges a report at an iteration boundary as the child's, and commits it when the turn is kept" do
      allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
        child_answers("found it")
        turns << [prompt, kwargs[:pending_input].call, kwargs[:pending_input].call]
        result
      end
      start_worker(parent)
      send_turn(parent, "keep going", "web:tab1")

      prompt, first, second = next_turn
      expect(prompt).to eq("keep going")
      expect(first).to eq([Samagotchi::Steer::Line.new(text: "session: #{child.id}\nstatus: answered\n---\nfound it",
                                                       source: "delegate_report")])
      # Taken once in the turn.
      expect(second).to eq([])
      merged = nil
      expect(wait_until { merged = drain.find { |e| e[:type] == :input_merged } }).to be_truthy
      expect(merged).to include(count: 1, origins: [{ client_id: "child:#{child.id[0, 8]}" }])

      expect(wait_until { rings.empty? }).to be(true)
      expect(cursor.reply_file).to end_with(".txt")
    end

    it "leaves the report out of a failed turn's restored prompts and keeps its ring for the next turn" do
      calls = 0
      allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
        calls += 1
        child_answers("found it") if calls == 1
        turns << [prompt, kwargs[:pending_input].call]
        raise Samagotchi::LLM::ServerError.new("main: HTTP 500: boom", host: "main", status: 500) if calls == 1

        result
      end
      start_worker(parent)
      send_turn(parent, "boom", "web:tab1")

      expect(next_turn.last.map(&:source)).to eq(["delegate_report"])
      restored = nil
      expect(wait_until { (restored = drain.select { |e| e[:type] == :prompt_restored }).any? }).to be(true)
      expect(restored.map { |e| e[:prompt] }).to eq(["boom"])
      expect(rings.size).to eq(1)

      send_turn(parent, "again", "web:tab1")
      prompt, lines = next_turn
      expect(prompt).to eq("again")
      expect(lines.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\nfound it"])
      expect(wait_until { rings.empty? }).to be(true)
    end

    def drain
      list = []
      list << events.pop until events.empty?
      (@seen ||= []).concat(list)
    end
  end
end
