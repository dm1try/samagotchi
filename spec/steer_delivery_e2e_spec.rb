# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "samagotchi/session_manager"
require "samagotchi/worker"
require "samagotchi/send_command"
require "samagotchi/answer_command"
require_relative "support/fake_provider_server"

# What a message sent to a running turn does, end to end: a real Worker (its
# drain, its Bridge), a real KernelLoop streaming a long thinking generation
# from a fake model server, and `chi send` posting to the Bridge. A plain
# message goes in at the turn's next step boundary and never cuts the
# thinking; one sent with --cut cuts it (`steer_cut`); one queued waits for
# the turn's end and runs as its own turn, and --queue --wait gets that
# turn's own answer, as chi answer gets the answered turn's. The one e2e
# for steer delivery;
# bridge_spec, worker_spec and send_command_spec cover the variants.
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

  # A generation that thinks, chunk by chunk, until +sent+ says the
  # example's message went in (at most +chunks+ of them), then reads a file
  # (a step boundary, where a plain message merges); with tool_call: false
  # it only thinks, ~4 s, and the held stream never ends by itself. Every
  # later generation answers PONG.
  def stream_thinking(tool_call: true, chunks: 80, delay: 0.05, sent: -> { @sent })
    File.write(File.join(tmpdir, "notes.txt"), "notes\n")
    thought = event("I should check the file again to be sure. ")
    pieces = if tool_call
               read = [event("</think>"), event("<tool_call>\n<function=read>\n"),
                       event("<parameter=path>\n#{File.join(tmpdir, "notes.txt")}\n</parameter>\n"),
                       event("</function>\n</tool_call>"), stop]
               Enumerator.new do |chunk|
                 chunk << event("<think>")
                 (chunks * 4).times { sent.call ? break : chunk << thought }
                 read.each { |piece| chunk << piece }
               end
             else
               [event("<think>")] + Array.new(chunks) { thought }
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
      .tap { @sent = true }
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

  # P3a: a queued message is skipped by the drain, a next_step one sent
  # after it still merges, and the queued one is its own turn after.
  it "runs a queued message as its own turn after the running one, while a later plain one still merges" do
    stream_thinking
    run_turn("have a long think")
    start_worker
    expect(wait_until(timeout: 10) { events.any? { |e| e[:type] == :generation_chunk } }).to be_truthy

    queued = Samagotchi::SessionManager.deliver_turn(session.id, prompt: "later please", client_id: "web:x",
                                                                 delivery: "queue", state_dir: tmpdir)
    expect(queued).to include(status: :accepted)
    expect(queued[:ack]).to include("delivery" => "queue")
    sleep(0.01)
    plain = Samagotchi::SessionManager.deliver_turn(session.id, prompt: "mind the typos", client_id: "web:x", state_dir: tmpdir)
    @sent = true
    expect(plain[:ack]).to include("delivery" => "next_step")

    expect(merged("mind the typos")).to be_truthy, "events: #{types.tally}"
    started = wait_until(timeout: 15) { events.find { |e| e[:type] == :turn_started && e[:prompt] == "later please" } }
    expect(started).to be_truthy, "events: #{types.tally}"
    expect(started.dig(:origin, :enqueued_id)).to eq(queued[:ack]["enqueued_id"])
    first_end = events.index { |e| e[:type] == :turn_completed }
    expect(first_end).to be < events.index(started)
    expect(events.select { |e| e[:type] == :pending_input_merged }.map { |e| e[:content].to_s }.join).not_to include("later please")
  end

  # P3b: chi send --queue --wait into a running turn is not refused, and
  # prints the queued turn's own answer, not the running turn's.
  it "waits for the queued turn's own answer (chi send --queue --wait)" do
    # The send waits for the queued turn: the thinking ends once it went in.
    stream_thinking(sent: -> { err.string.include?("sent (queued") })
    answer = ->(text) { server.enqueue("/completion", sse: [event("<think>"), event("ok"), event("</think>"), event(text), stop]) }
    answer.call("RUNNING ANSWER")
    answer.call("QUEUED ANSWER")
    run_turn("have a long think")
    start_worker

    expect(send_after_thinking("--queue", "--wait", "--timeout", "30", "-m", "later please", seconds: 0.2)).to eq(0), err.string
    expect(out.string).to eq("QUEUED ANSWER\n")
    expect(err.string).to eq("#{short}  sent (queued: runs after the current turn)\n")
    replies = Dir.children(File.join(session_dir, "output")).sort
    expect(replies.size).to eq(2)
    expect(File.read(File.join(session_dir, "output", replies.first))).to eq("RUNNING ANSWER")
  end

  # chi answer to the running turn's question, a turn queued behind it:
  # the answered turn's own reply comes back, not the queued turn's newer
  # one (a slow poll lets both end before the wait looks again).
  it "prints the answered turn's own reply with a queued turn behind it (chi answer)" do
    stub_const("Samagotchi::AnswerCommand::POLL_INTERVAL", 2)
    ask = [event("<think>"), event("ask"), event("</think>"), event("<tool_call>\n<function=ask_user_question>\n"),
           event("<parameter=question>\nWhich one?\n</parameter>\n<parameter=options>\n[\"A\", \"B\"]\n</parameter>\n"),
           event("</function>\n</tool_call>"), stop]
    server.enqueue("/completion", sse: ask)
    server.enqueue("/completion", sse: [event("<think>"), event("ok"), event("</think>"), event("RUNNING ANSWER"), stop])
    server.default("/completion", sse: [event("<think>"), event("ok"), event("</think>"), event("QUEUED ANSWER"), stop])
    # As chi send or the Bridge writes it: with its enqueued_id.
    Samagotchi::SessionManager.write_turn_input(session.id, prompt: "pick one", enqueued_id: "x1", state_dir: tmpdir)
    start_worker
    pending = wait_until(timeout: 15) { Samagotchi::Session.load(session.id, state_dir: tmpdir).pending_question }
    expect(pending).to be_truthy, "events: #{types.tally}"

    sent = Samagotchi::SendCommand.new(["--queue", "-m", "later please", session.id], stdin: StringIO.new(""), stdout: out,
                                                                                    stderr: err, state_dir: tmpdir).run
    expect(sent).to eq(0), err.string
    answered = StringIO.new
    status = Samagotchi::AnswerCommand.new([session.id, "--question", pending.id, "--option", "A", "--timeout", "30"],
                                           stdout: answered, stderr: err, state_dir: tmpdir).run

    expect(status).to eq(0), err.string
    expect(answered.string).to eq("RUNNING ANSWER\n")
    expect(wait_until(timeout: 15) { Dir.children(File.join(session_dir, "output")).size == 2 }).to be_truthy
  end
end
