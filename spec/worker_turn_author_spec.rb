# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/worker"

# The worker reads a turn's author from its input file into the turn's
# origin (Engine#run_turn's origin:), and its mid-turn drain keeps it with
# each merged line's origin. An owner's input carries none.
RSpec.describe Samagotchi::Worker, "a turn's author" do
  around do |example|
    WebMock.allow_net_connect! if defined?(WebMock)
    with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run }
  ensure
    WebMock.disable_net_connect! if defined?(WebMock)
  end

  let(:tmpdir) { Dir.mktmpdir("worker-author") }
  let!(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
      s.save(state_dir: tmpdir)
    end
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
  let!(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
  let(:result) { instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false) }
  let(:turns) { Queue.new }
  let(:merged_origins) { Queue.new }

  before do
    FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))
    # p_1 and p_2 are invited (the worker runs no turn of a participant
    # the sidecar doesn't list as active).
    active = %w[p_1 p_2].map do |id|
      { "id" => id, "kind" => "human", "name" => id, "role" => "reviewer", "added_at" => "2026-10-23T10:00:00Z",
        "expires_at" => (Time.now + 3600).utc.iso8601, "removed_at" => nil, "cap" => 2.0 }
    end
    File.write(File.join(session_dir, "participants.json"), JSON.generate({ "participants" => active }))
    allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    allow(engine).to receive_messages(start_idle: nil, stop_idle: nil)
    engine.subscribe(observer: ->(event) { merged_origins << event[:origins] if event[:type] == :input_merged })
    allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
      if prompt == "first"
        Samagotchi::SessionInbox.write_input(session_dir, prompt: "steer", client_id: "web:t", author: "p:p_2")
        kwargs[:pending_input].call
      end
      turns << [prompt, kwargs[:origin]&.to_h]
      result
    end
  end

  after do
    @thread&.kill
    @thread&.join(2)
    FileUtils.rm_rf(tmpdir)
  end

  def start_worker
    worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                 idle_exit_minutes: 0, poll_interval: 0.02)
    @thread = Thread.new { worker.run }
    @thread.report_on_exception = false
  end

  it "runs the turn with the file's author in its origin; another participant's line waits for its own turn" do
    start_worker
    Samagotchi::SessionInbox.write_input(session_dir, prompt: "first", client_id: "web:t", enqueued_id: "e1", author: "p:p_1")

    expect(pop!(turns, "the authored turn")).to eq(["first", { client_id: "web:t", enqueued_id: "e1", author: "p:p_1" }])
    expect(pop!(turns, "the other participant's own turn")).to eq(["steer", { client_id: "web:t", author: "p:p_2" }])
    expect(merged_origins).to be_empty
  end

  it "runs an owner's turn with no author in its origin" do
    start_worker
    Samagotchi::SessionInbox.write_input(session_dir, prompt: "mine", client_id: "web:t", enqueued_id: "e2")

    expect(pop!(turns, "the owner's turn")).to eq(["mine", { client_id: "web:t", enqueued_id: "e2" }])
  end
end
