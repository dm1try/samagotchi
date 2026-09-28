# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/send_command"

# chi send --new: a worker session started headlessly, the way the web start
# page does, so it shows in the web at once.
RSpec.describe Samagotchi::SendCommand, "--new" do
  let(:tmpdir) { Dir.mktmpdir("send-new") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:spawned) { [] }

  before do
    allow(Samagotchi::SessionManager).to receive(:spawn_session) do |**kwargs|
      spawned << kwargs
      Samagotchi::Session.new_session(mode: "assist", model_name: kwargs[:model_name] || "m",
                                      working_directory: kwargs[:working_directory] || Dir.pwd)
    end
  end

  after { FileUtils.rm_rf(tmpdir) }

  def run(*argv, stdin: StringIO.new(""))
    described_class.new(argv, stdin: stdin, stdout: out, stderr: err, state_dir: tmpdir).run
  end

  it "starts a session with the composed message and prints its full id" do
    expect(run("--new", "-m", "review this", stdin: StringIO.new("diff --git a b\n"))).to eq(0), err.string

    expect(spawned).to eq([{ prompt: "> diff --git a b\n\nreview this", working_directory: nil, model_name: nil,
                             state_dir: tmpdir }])
    expect(out.string).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}  started\n\z/)
    expect(err.string).to be_empty
  end

  it "passes --dir (expanded) and --model" do
    Dir.mktmpdir("proj") do |dir|
      expect(run("--new", "--dir", dir, "--model=Qwen-27B", "-m", "hi")).to eq(0), err.string
      expect(spawned.first).to include(working_directory: File.expand_path(dir), model_name: "Qwen-27B")

      expect(run("--new", "--dir=#{dir}/.", "--model", "M", "-m", "hi")).to eq(0), err.string
      expect(spawned.last).to include(working_directory: File.expand_path(dir), model_name: "M")
    end
  end

  it "takes no ids: one new session per call" do
    expect(run("--new", "-m", "hi", "3fa2")).to eq(2)
    expect(err.string).to include("--new takes no session ids", "Usage: chi send")
    expect(spawned).to be_empty
  end

  it "refuses a --dir that is not a folder" do
    expect(run("--new", "--dir", "/nope/not/here", "-m", "hi")).to eq(2)
    expect(err.string).to include("chi send: no folder /nope/not/here")
    expect(spawned).to be_empty
  end

  it "keeps --dir and --model to --new" do
    expect(run("--dir", "/tmp", "-m", "hi", "3fa2")).to eq(2)
    expect(run("--model", "M", "-m", "hi", "3fa2")).to eq(2)
    expect(err.string).to include("--dir needs --new", "--model needs --new")
  end

  it "is a usage error with no message" do
    expect(run("--new", "-m", " ")).to eq(2)
    expect(err.string).to include("no message")
    expect(spawned).to be_empty
  end

  it "reports a failed start in one line" do
    allow(Samagotchi::SessionManager).to receive(:spawn_session).and_raise(RuntimeError, "no default model")
    expect(run("--new", "-m", "hi")).to eq(1)
    expect(err.string).to eq("chi send: could not start a session: no default model\n")
  end
end

# chi send --wait: block until the session's next reply and print it, so an
# agent gets a one-shot answer the user can watch in the web.
RSpec.describe Samagotchi::SendCommand, "--wait" do
  let(:tmpdir) { Dir.mktmpdir("send-wait") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:threads) { [] }
  let(:owner) { [{ "pid" => 1, "kind" => "worker" }] }
  let(:delivered) { [] }

  before do
    stub_const("Samagotchi::SendCommand::POLL_INTERVAL", 0.02)
    allow(Samagotchi::SessionManager).to receive(:session_owner) { owner[0] }
    allow(Samagotchi::SessionManager).to receive(:spawn_session) do |prompt:, **|
      make(status: "running", prompt: prompt).tap { |s| @started = s }
    end
    allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |id, prompt:, **|
      delivered << [id, prompt]
      @on_deliver&.call
      { status: :accepted, ack: {} }
    end
  end

  after do
    threads.each(&:join)
    FileUtils.rm_rf(tmpdir)
  end

  def run(*argv, stdin: StringIO.new(""))
    described_class.new(argv, stdin: stdin, stdout: out, stderr: err, state_dir: tmpdir).run
  end

  def make(status:, prompt: "hi", pending_question: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w").tap do |s|
      s.status = status
      s.last_prompt = prompt
      s.pending_question = pending_question
      s.save(state_dir: tmpdir)
    end
  end

  def update(session, status: nil, pending_question: :keep, add_message: nil)
    s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
    s.status = status if status
    s.pending_question = pending_question unless pending_question == :keep
    s.messages << add_message if add_message
    s.save(state_dir: tmpdir)
  end

  def write_reply(session, text)
    Samagotchi::SessionManager.write_output(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), text)
    sleep(0.002)
  end

  def later(delay = 0.1, &block)
    threads << Thread.new do
      sleep(delay)
      block.call
    end
  end

  it "prints the new session's reply in full on stdout, the id line on stderr" do
    reply = "line one\n#{"x" * 40_000}\nlast"
    later { write_reply(@started, reply) }

    expect(run("--new", "--wait", "-m", "review")).to eq(0), err.string
    expect(out.string).to eq("#{reply}\n")
    expect(err.string).to eq("#{@started.id}  started\n")
  end

  it "exits 3 with the attach hint when the turn waits for an answer" do
    later { update(@started, pending_question: { id: "q1", kind: "approval", question: "Run rm -rf build?" }) }

    expect(run("--new", "--wait", "-m", "clean")).to eq(3)
    expect(out.string).to be_empty
    expect(err.string).to end_with("chi send: waiting for an answer: Run rm -rf build?; " \
                                   "open it: chi --attach #{@started.id} or the web\n")
  end

  it "returns only a reply newer than the ones before, and ignores a question pending before the send" do
    old = make(status: "idle", pending_question: { id: "stale", question: "Old?" })
    write_reply(old, "the old answer")
    @on_deliver = lambda do
      later do
        update(old, status: "running")
        sleep(0.05)
        write_reply(old, "the new answer")
        update(old, status: "idle")
      end
    end

    expect(run("--wait", "-m", "one more", old.id[0, 8])).to eq(0), err.string
    expect(delivered).to eq([[old.id, "one more"]])
    expect(out.string).to eq("the new answer\n")
    expect(err.string).to eq("#{old.id[0, 8]}  sent\n")
  end

  it "refuses a session with a running turn: its reply would be printed as the answer" do
    busy = make(status: "running")

    expect(run("--wait", "-m", "and?", busy.id)).to eq(1)
    expect(err.string).to eq("#{busy.id[0, 8]}  busy: a turn is running; wait or attach\n")
    expect(delivered).to be_empty
  end

  it "ends without a reply when the turn fails before the first look" do
    idle = make(status: "idle")
    # The whole turn, failed and noted, inside the send.
    @on_deliver = -> { update(idle, add_message: { role: "user", content: "[turn failed]" }) }

    expect(run("--wait", "-m", "x", idle.id)).to eq(1)
    expect(err.string).to end_with("chi send: the turn ended without a reply (canceled, failed or empty); " \
                                   "chi --attach #{idle.id} shows it\n")
  end

  it "reports a worker that died without saying so" do
    stub_const("Samagotchi::SendCommand::WORKER_GONE_AFTER", 0.1)
    owner[0] = nil

    expect(run("--new", "--wait", "-m", "x")).to eq(1)
    expect(err.string).to end_with("chi send: the worker is gone; chi --attach #{@started.id} shows what happened\n")
  end

  it "reports a failed worker and a stopped session" do
    later { update(@started, status: "error") }
    expect(run("--new", "--wait", "-m", "x")).to eq(1)
    expect(err.string).to include("chi send: the worker failed")

    later { update(@started, status: "stopped") }
    expect(run("--new", "--wait", "-m", "x")).to eq(1)
    expect(err.string).to include("chi send: the session was stopped")
  end

  it "gives up after --timeout, the session still running" do
    expect(run("--new", "--wait", "--timeout", "0.1", "-m", "x")).to eq(1)
    expect(err.string).to end_with("chi send: still running after 0.1 s: chi --attach #{@started.id}\n")
  end

  it "leaves the turn running on Ctrl-C and exits 130" do
    allow(Samagotchi::ReplyWait).to receive(:call).and_raise(Interrupt)

    expect(run("--new", "--wait", "-m", "x")).to eq(130)
    expect(err.string).to end_with("chi send: still running: chi --attach #{@started.id}\n")
    expect(Samagotchi::Session.load(@started.id, state_dir: tmpdir).status).to eq("running")
  end

  describe "with no message (wait only)" do
    it "sends nothing and prints a running session's next reply, past the question already reported" do
      asked = make(status: "running", pending_question: { id: "q1", question: "Which branch?" })
      write_reply(asked, "an older answer")
      later do
        update(asked, pending_question: nil)
        write_reply(asked, "merged into main")
        update(asked, status: "idle")
      end

      expect(run("--wait", asked.id[0, 8])).to eq(0), err.string
      expect(delivered).to be_empty
      expect(out.string).to eq("merged into main\n")
      expect(err.string).to be_empty
    end

    it "waits on an idle session with no worker until one replies" do
      stub_const("Samagotchi::SendCommand::WORKER_GONE_AFTER", 0.05)
      owner[0] = nil
      idle = make(status: "idle")
      later(0.2) do
        update(idle, status: "running")
        write_reply(idle, "hello from the web's turn")
      end

      expect(run("--wait", idle.id)).to eq(0), err.string
      expect(out.string).to eq("hello from the web's turn\n")
      expect(delivered).to be_empty
    end

    it "reports a new question and a timeout as --wait does" do
      busy = make(status: "running")
      later { update(busy, pending_question: { id: "q2", question: "Delete it?" }) }
      expect(run("--wait", busy.id)).to eq(3)
      expect(err.string).to end_with("chi send: waiting for an answer: Delete it?; open it: chi --attach #{busy.id} or the web\n")

      expect(run("--wait", "--timeout", "0.1", busy.id)).to eq(1)
      expect(err.string).to end_with("chi send: still running after 0.1 s: chi --attach #{busy.id}\n")
      expect(delivered).to be_empty
    end

    it "is a usage error with --new or with two ids" do
      a = make(status: "idle")
      b = make(status: "idle")
      expect(run("--new", "--wait")).to eq(2)
      expect(err.string).to include("no message")
      expect(run("--wait", a.id, b.id)).to eq(2)
      expect(err.string).to include("--wait takes one session")
    end
  end

  it "keeps --wait to one session and --timeout to --wait" do
    a = make(status: "idle")
    b = make(status: "idle")
    expect(run("--wait", "-m", "x", a.id, b.id)).to eq(2)
    expect(err.string).to include("--wait takes one session")
    expect(run("--timeout", "5", "-m", "x", a.id)).to eq(2)
    expect(err.string).to include("--timeout needs --wait")
    expect(run("--wait", "--timeout", "soon", "-m", "x", a.id)).to eq(2)
    expect(err.string).to include("--timeout takes seconds")
    expect(delivered).to be_empty
  end
end
