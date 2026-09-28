# frozen_string_literal: true

require "open3"
require "rbconfig"
require "socket"
require "stringio"
require "timeout"
require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/send_command"
require "samagotchi/owner_lock"
require "samagotchi/engine"
require "samagotchi/bridge"

RSpec.describe Samagotchi::SendCommand do
  let(:tmpdir) { Dir.mktmpdir("send-command") }
  let(:locks) { [] }
  let(:bridges) { [] }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    # The Bridge serves real HTTP on 127.0.0.1.
    WebMock.allow_net_connect! if defined?(WebMock)
    example.run
  ensure
    WebMock.disable_net_connect! if defined?(WebMock)
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  after do
    bridges.each(&:stop)
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(owner: nil, status: nil, id: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app").tap do |s|
      s.id = id if id
      s.last_prompt = "hi"
      s.status = status if status
      s.save(state_dir: tmpdir)
      locks << Samagotchi::OwnerLock.acquire(dir_of(s), kind: owner) if owner
    end
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)

  # A live worker's Bridge (no turn loop: it only writes input files and
  # announces), with the events its engine sent.
  def serve(session)
    engine = Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client),
                                    kernel: instance_double(Samagotchi::KernelLoop))
    events = []
    engine.subscribe(observer: ->(e) { events << e })
    bridge = Samagotchi::Bridge.new(engine: engine, state_dir: tmpdir, session_id: session.id, heartbeat_interval: 5,
                                    input_format: Samagotchi::SessionManager::INPUT_FORMAT)
    bridge.start
    bridges << bridge
    events
  end

  def run(*argv, stdin: StringIO.new(""))
    described_class.new(argv, stdin: stdin, stdout: out, stderr: err, state_dir: tmpdir).run
  end

  def inputs_of(session)
    Dir.glob(File.join(dir_of(session), Samagotchi::SessionManager::INPUT_DIR, "*.json")).map { |path| JSON.parse(File.read(path)) }
  end

  def short(session) = session.id[0, 8]

  it "sends -m through the live worker's Bridge, announced as from cli:send" do
    a = make(owner: "worker")
    events = serve(a)

    expect(run("-m", "is this the same bug?", short(a))).to eq(0), err.string

    expect(out.string).to eq("#{short(a)}  sent\n")
    expect(inputs_of(a)).to contain_exactly(include("prompt" => "is this the same bug?", "client_id" => "cli:send"))
    expect(events.map { |e| e.slice(:type, :client_id, :prompt) })
      .to eq([{ type: :turn_enqueued, client_id: "cli:send", prompt: "is this the same bug?" }])
  end

  it "quotes stdin above the -m message" do
    a = make(owner: "worker")
    serve(a)

    expect(run("-m", "same bug?", a.id, stdin: StringIO.new("undefined method\r\n\n  at foo.rb:3\n\n"))).to eq(0), err.string
    expect(inputs_of(a).first["prompt"]).to eq("> undefined method\n>\n>   at foo.rb:3\n\nsame bug?")
  end

  it "sends stdin as the message itself without -m" do
    a = make(owner: "worker")
    serve(a)

    expect(run(a.id, stdin: StringIO.new("what does this do?\n"))).to eq(0), err.string
    expect(inputs_of(a).first["prompt"]).to eq("what does this do?")
  end

  it "says a running turn picks the message up" do
    a = make(owner: "worker", status: Samagotchi::Session::STATUS_RUNNING)
    serve(a)

    expect(run("-m", "also check the tests", a.id)).to eq(0)
    expect(out.string).to eq("#{short(a)}  sent (the running turn picks it up)\n")
  end

  it "falls back to the input file when the Bridge goes away mid-send" do
    a = make(owner: "worker")
    serve(a)
    allow_any_instance_of(Samagotchi::BridgeClient).to receive(:post_turn).and_raise(Errno::ECONNREFUSED)

    expect(run("-m", "hi there", a.id)).to eq(0), err.string
    expect(out.string).to eq("#{short(a)}  sent\n")
    expect(err.string).to be_empty
    expect(inputs_of(a)).to contain_exactly(include("prompt" => "hi there", "client_id" => "cli:send"))
  end

  it "wakes the worker of a session nobody runs" do
    stub_const("Samagotchi::SessionManager::TURN_BRIDGE_WAIT", 0)
    a = make(status: Samagotchi::Session::STATUS_STOPPED)
    allow(Process).to receive(:spawn).and_return(40_004)

    expect(run("-m", "wake up", a.id)).to eq(0), err.string
    expect(out.string).to eq("#{short(a)}  sent (started its worker)\n")
    expect(Process).to have_received(:spawn).at_least(:once)
    expect(inputs_of(a).first["prompt"]).to eq("wake up")
  end

  it "refuses a session open in a chi REPL and exits 1, still sending to the others" do
    repl = make(owner: "tui")
    live = make(owner: "worker")
    serve(live)
    allow(Process).to receive(:spawn)

    expect(run("-m", "x", repl.id, live.id)).to eq(1)
    expect(out.string.lines).to eq(["#{short(repl)}  refused: it is open in a chi REPL; messages need attached mode\n",
                                    "#{short(live)}  sent\n"])
    expect(Process).not_to have_received(:spawn)
    expect(inputs_of(repl)).to be_empty
  end

  it "reports a failure in one line, no backtrace" do
    a = make(owner: "worker")
    allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_raise(Errno::EACCES, "input")

    expect(run("-m", "x", a.id)).to eq(1)
    expect(out.string).to eq("#{short(a)}  failed: Permission denied - input\n")
  end

  it "says a message the worker didn't answer for was not sent" do
    a = make(owner: "worker")
    allow(Samagotchi::SessionManager).to receive(:deliver_turn)
      .and_return(status: :timeout, ack: { "error" => "worker_timeout",
                                           "detail" => "the session's worker did not answer, so the message was not sent" })

    expect(run("-m", "x", a.id)).to eq(1)
    expect(out.string).to eq("#{short(a)}  failed: the session's worker did not answer, so the message was not sent\n")
  end

  it "reports an unknown or ambiguous id and exits 1" do
    live = make(owner: "worker")
    serve(live)
    make(id: "abc1-one")
    make(id: "abc1-two")

    expect(run("-m", "x", "nope", "abc1", live.id)).to eq(1)
    expect(err.string).to include("no session nope", "session id abc1 matches 2 sessions")
    expect(inputs_of(live).size).to eq(1)
  end

  describe "without a locale (Finder, launchd: stdin and ARGV aren't UTF-8)" do
    it "keeps non-ASCII text from stdin and -m" do
      a = make(owner: "worker")
      serve(a)

      expect(run("-m", "café?".b, a.id, stdin: StringIO.new("h\xC3\xA9llo".dup.force_encoding("US-ASCII")))).to eq(0), err.string
      expect(inputs_of(a).first["prompt"]).to eq("> héllo\n\ncafé?")
    end
  end

  it "doesn't wait on an inherited stdin that is neither a pipe nor a file (a launcher's socket)" do
    a = make(owner: "worker")
    serve(a)
    socket, other_end = UNIXSocket.pair

    expect(Timeout.timeout(5) { run("-m", "hi", a.id, stdin: socket) }).to eq(0), err.string
    expect(inputs_of(a).first["prompt"]).to eq("hi")
  ensure
    [socket, other_end].compact.each(&:close)
  end

  it "is a usage error with neither -m nor stdin, or both blank" do
    a = make(owner: "worker")
    tty = StringIO.new("")
    def tty.tty? = true

    expect(run(a.id, stdin: tty)).to eq(2)
    expect(run("-m", " ", a.id, stdin: StringIO.new("\n \n"))).to eq(2)
    expect(err.string).to include("Usage: chi send")
    expect(inputs_of(a)).to be_empty
  end

  it "refuses a message over 16 KiB before sending any" do
    a = make(owner: "worker")

    expect(run("-m", "x" * (16 * 1024 + 1), a.id)).to eq(1)
    expect(err.string).to include("chi send: the message is 16385 bytes; the limit is 16 KiB")
    expect(inputs_of(a)).to be_empty
  end

  it "asks for targets, and has no --all" do
    expect(run("-m", "x")).to eq(2)
    expect(err.string).to include("give session ids")
    expect(run("-m", "x", "--all")).to eq(2)
    expect(err.string).to include("--all")
  end

  it "prints help" do
    expect(run("--help")).to eq(0)
    expect(out.string).to include("Usage: chi send", "-m TEXT", "chi sessions list --live")
  end

  describe "bin/chi send" do
    let(:chi) { File.expand_path("../bin/chi", __dir__) }

    let(:xdg) { Dir.mktmpdir("chi-send") }
    let(:tmpdir) { FileUtils.mkdir_p(Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg })).first }

    after { FileUtils.rm_rf(xdg) }

    it "keeps the order of the ids given when stdout and stderr share a pipe" do
      repl = make(owner: "tui")
      live = make(owner: "worker")
      serve(live)

      output, _status = Open3.capture2e({ "XDG_STATE_HOME" => xdg }, RbConfig.ruby, chi, "send", "-m", "x",
                                        short(repl), "nope", short(live), stdin_data: "")

      expect(output.lines.map { |line| line[/refused|no session nope|sent/] }).to eq(["refused", "no session nope", "sent"])
    end

    it "is wired before the main option parser, and keeps non-ASCII text without a locale" do
      a = make(owner: "worker")
      # A history with non-ASCII in it, read with no locale.
      a.messages = [{ role: "user", content: "caf\u00E9 \u2615" }, { role: "model", content: "\u2014 ok" }]
      a.save(state_dir: tmpdir)
      events = serve(a)

      # No locale at all, as an app started from Finder or launchd has it.
      # GEM_HOME/GEM_PATH as Bundler set them: CI installs the gems under
      # vendor/bundle, where a bare ruby can't find nokogiri.
      bare = ENV.to_h.slice("GEM_HOME", "GEM_PATH")
                .merge("XDG_STATE_HOME" => xdg, "HOME" => Dir.home, "PATH" => "#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin")
      stdout, stderr, status = Open3.capture3(bare, RbConfig.ruby, chi, "send", "-m", "caf\u00E9?", short(a),
                                              stdin_data: "h\u00E9llo", unsetenv_others: true)

      expect(status.exitstatus).to eq(0), stderr
      expect(stdout).to eq("#{short(a)}  sent\n")
      expect(stderr).not_to include("warning")
      expect(events.map { |e| e.slice(:type, :client_id, :prompt) })
        .to eq([{ type: :turn_enqueued, client_id: "cli:send", prompt: "> héllo\n\ncafé?" }])
    end
  end
end
