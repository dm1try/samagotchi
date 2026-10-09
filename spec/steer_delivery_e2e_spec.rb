# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "samagotchi/session_manager"
require "samagotchi/worker"
require "samagotchi/send_command"
require_relative "support/fake_provider_server"

# What a message sent to a running turn does, end to end: a real Worker (its
# drain, its Bridge), a real KernelLoop streaming a long thinking generation
# from a fake model server, and `chi send` posting to the Bridge. A plain
# message goes in at the turn's next step boundary and never cuts the
# thinking; one sent with --cut cuts it (`steer_cut`). The one e2e for
# steer delivery (P1); bridge_spec and send_command_spec cover the variants.
RSpec.describe "steering a running turn (chi send)" do
  around do |example|
    env = { "SAMAGOTCHI_DEFAULT_MODEL" => "Qwen3.6", "SAMAGOTCHI_STEER_CUT_AFTER" => "1" }
    FakeProviderServer.without_webmock { with_env(env) { example.run } }
  end

  let(:model) { "Qwen3.6" }
  let(:server) { FakeProviderServer.start }
  let(:tmpdir) { Dir.mktmpdir("steer-delivery") }
  let!(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: tmpdir).tap { |s| s.save(state_dir: tmpdir) }
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
  let(:client) { Samagotchi::Client.new(host: "127.0.0.1", port: server.port, transport: :llama_cpp, sleeper: ->(_s) {}) }
  let(:kernel) { Samagotchi::KernelLoop.new(client: client, profile: Samagotchi::ModelProfile.qwen36) }
  let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel, profile: "qwen36") }
  let(:events) { [] }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:short) { session.id[0, 8] }

  before do
    engine.subscribe(observer: ->(event) { events << event })
    allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    allow(engine).to receive_messages(start_idle: nil, stop_idle: nil)
  end

  after do
    @thread&.kill
    @thread&.join(2)
    @lock&.release
    FileUtils.rm_rf(tmpdir)
    server&.stop
  end

  def event(content) = "data: #{JSON.generate(content: content)}\n\n"
  def stop = "data: #{JSON.generate(content: "", stop: true)}\n\n"

  # A generation that thinks for ~4 s, chunk by chunk, then reads a file
  # (a step boundary, where a plain message merges); with tool_call: false
  # it only thinks, and the held stream never ends by itself. Every later
  # generation answers PONG.
  def stream_thinking(tool_call: true, chunks: 80, delay: 0.05)
    File.write(File.join(tmpdir, "notes.txt"), "notes\n")
    pieces = [event("<think>")] + Array.new(chunks) { event("I should check the file again to be sure. ") }
    if tool_call
      pieces += [event("</think>"), event("<tool_call>\n<function=read>\n"),
                 event("<parameter=path>\n#{File.join(tmpdir, "notes.txt")}\n</parameter>\n"),
                 event("</function>\n</tool_call>"), stop]
    end
    server.enqueue("/completion", sse: pieces, delay: delay, hold: !tool_call)
    server.default("/completion", sse: [event("<think>"), event("short"), event("</think>"), event("PONG"), stop])
  end

  # The worker as a spawned one runs: holding the session's OwnerLock, so
  # chi send sees a live, running worker.
  def start_worker
    @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
    worker = Samagotchi::Worker.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                    idle_exit_minutes: 0, poll_interval: 0.05)
    @thread = Thread.new { worker.run }
    @thread.report_on_exception = false
    expect(wait_until(timeout: 10) { File.exist?(File.join(session_dir, "bridge.json")) }).to be_truthy
  end

  def run_turn(prompt)
    Samagotchi::SessionManager.write_turn_input(session.id, prompt: prompt, state_dir: tmpdir)
  end

  def types = events.map { |e| e[:type] }

  # Waits until the model has been thinking for +seconds+, then sends as
  # chi send does. The thinking is fresh throughout (a chunk every 50 ms),
  # so a cut is eligible from steer.cut_after (1 s here) on.
  def send_after_thinking(*argv, seconds: 1.4)
    thinking = wait_until(timeout: 10) { events.any? { |e| e[:type] == :generation_chunk && !e[:thinking].to_s.strip.empty? } }
    raise "the model never started thinking" unless thinking

    sleep(seconds)
    Samagotchi::SendCommand.new([*argv, session.id], stdin: StringIO.new(""), stdout: out, stderr: err, state_dir: tmpdir).run
  end

  def merged(content)
    wait_until(timeout: 15) do
      events.any? { |e| e[:type] == :pending_input_merged && e[:content].to_s.include?(content) }
    end
  end

  it "takes a plain message at the next step boundary, without cutting the thinking" do
    stream_thinking
    run_turn("have a long think")
    start_worker

    expect(send_after_thinking("-m", "mind the typos")).to eq(0), err.string
    expect(out.string).to eq("#{short}  sent (goes in at the running turn's next step)\n")

    expect(merged("mind the typos")).to be_truthy, "events: #{types.tally}"
    expect(types).not_to include(:steer_cut)
    # Merged at the boundary after the thinking generation's tool call ran.
    expect(types.index(:tool_call_completed)).to be < types.index(:pending_input_merged)
  end

  it "cuts the thinking when the message asks for it (chi send --cut)" do
    stream_thinking(tool_call: false)
    run_turn("have a long think")
    start_worker

    expect(send_after_thinking("--cut", "-m", "drop the tests")).to eq(0), err.string
    expect(out.string).to eq("#{short}  sent (cut in now)\n")

    expect(wait_until(timeout: 15) { types.include?(:steer_cut) }).to be_truthy, "events: #{types.tally}"
    expect(events.find { |e| e[:type] == :steer_cut }).to include(source: "chi_send", iteration: 1)
    # The cut's step starts again with the message.
    expect(merged("drop the tests")).to be_truthy
    expect(types.index(:steer_cut)).to be < types.index(:pending_input_merged)
  end
end
