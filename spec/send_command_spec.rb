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

  describe "--image" do
    let(:fixtures) { File.expand_path("fixtures/images", __dir__) }
    let(:png) { File.join(fixtures, "tiny.png") }
    let(:jpg) { File.join(fixtures, "tiny.jpg") }

    # Each ref names a file in that session's own images/.
    def images_in(session, input)
      input.fetch("images").map do |ref|
        expect(File.file?(File.join(dir_of(session), ref["file"]))).to be(true), "#{ref["file"]} missing in #{short(session)}"
        ref["name"]
      end
    end

    it "copies the image into the session and sends it as a ref with the message" do
      a = make(owner: "worker")
      events = serve(a)

      expect(run("--image", png, "-m", "why is this red?", short(a))).to eq(0), err.string

      expect(out.string).to eq("#{short(a)}  sent with 1 image\n")
      input = inputs_of(a).first
      expect(input).to include("prompt" => "why is this red?", "client_id" => "cli:send")
      expect(images_in(a, input)).to eq(["tiny.png"])
      expect(events.first).to include(type: :turn_enqueued, images: [include(name: "tiny.png")])
    end

    it "sends each image to each session, from its own images/, ingesting a file once" do
      a = make(owner: "worker")
      b = make(owner: "worker")
      serve(a)
      serve(b)
      allow(Samagotchi::ImageStore).to receive(:ingest).and_call_original

      expect(run("--image=#{png}", "--image", jpg, "-m", "look", a.id, b.id)).to eq(0), err.string

      expect(out.string.lines).to eq(["#{short(a)}  sent with 2 images\n", "#{short(b)}  sent with 2 images\n"])
      expect(images_in(a, inputs_of(a).first)).to eq(["tiny.png", "tiny.jpg"])
      expect(images_in(b, inputs_of(b).first)).to eq(["tiny.png", "tiny.jpg"])
      expect(Samagotchi::ImageStore).to have_received(:ingest).twice
    end

    it "converts an image the model can't take (bmp) to png" do
      skip "no sips or ImageMagick" unless Samagotchi::ImageResizer.detect.available?
      a = make(owner: "worker")
      serve(a)

      expect(run("--image", File.join(fixtures, "tiny.bmp"), "-m", "hm", a.id)).to eq(0), err.string
      expect(inputs_of(a).first["images"].first["file"]).to end_with(".png")
    end

    it "says a busy session runs the image message after the current turn" do
      a = make(owner: "worker", status: Samagotchi::Session::STATUS_RUNNING)
      serve(a)

      expect(run("--image", png, "-m", "and this?", a.id)).to eq(0)
      expect(out.string).to eq("#{short(a)}  sent with 1 image (runs after the current turn)\n")
    end

    it "refuses a missing file, a non-image or too many images before sending anything" do
      a = make(owner: "worker")
      serve(a)

      expect(run("--image", "/nope/shot.png", "-m", "x", a.id)).to eq(2)
      expect(err.string).to include("chi send: /nope/shot.png: no such file")
      # A text file named .png.
      expect(run("--image", File.join(fixtures, "text.png"), "-m", "x", a.id)).to eq(2)
      expect(err.string).to include("chi send: text.png is not an image chi can send")
      expect(run(*(["--image", png] * 21), "-m", "x", a.id)).to eq(2)
      expect(err.string).to include("at most 20 images")
      expect(inputs_of(a)).to be_empty
    end

    it "needs text with the images, also with --wait (which would otherwise only wait)" do
      a = make(owner: "worker")
      tty = StringIO.new("")
      def tty.tty? = true

      expect(run("--image", png, a.id, stdin: tty)).to eq(2)
      expect(run("--wait", "--image", png, a.id, stdin: tty)).to eq(2)
      expect(err.string.scan("chi send: --image needs a message: pass -m TEXT or pipe it in").size).to eq(2)
      expect(inputs_of(a)).to be_empty
    end

    it "takes piped context as the text" do
      a = make(owner: "worker")
      serve(a)

      expect(run("--image", png, a.id, stdin: StringIO.new("the error log\n"))).to eq(0), err.string
      expect(inputs_of(a).first).to include("prompt" => "the error log")
    end

    it "fails the one session it can't copy into and still sends to the others" do
      a = make(owner: "worker")
      b = make(owner: "worker")
      serve(b)
      allow(Samagotchi::ImageStore).to receive(:copy_file).and_call_original
      allow(Samagotchi::ImageStore).to receive(:copy_file)
        .with(anything, from: anything, to: dir_of(a)).and_raise(Errno::ENOSPC, "images")

      expect(run("--image", png, "-m", "x", a.id, b.id)).to eq(1)
      expect(out.string.lines).to eq(["#{short(a)}  failed: No space left on device - images\n",
                                      "#{short(b)}  sent with 1 image\n"])
      expect(inputs_of(a)).to be_empty
    end

    it "fails a session whose worker predates images, with the reason" do
      a = make(owner: "worker")
      engine = Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client),
                                      kernel: instance_double(Samagotchi::KernelLoop))
      bridge = Samagotchi::Bridge.new(engine: engine, state_dir: tmpdir, session_id: a.id, heartbeat_interval: 5,
                                      input_format: 2)
      bridge.start
      bridges << bridge

      expect(run("--image", png, "-m", "x", a.id)).to eq(1)
      expect(out.string).to eq("#{short(a)}  failed: this session's worker predates images: restart it (/exit, then resume)\n")
      expect(inputs_of(a)).to be_empty
    end

    it "with --new starts the session idle, waits for its worker, then sends the turn with the image (one worker)" do
      started = nil
      worker = nil
      allow(Process).to receive(:spawn) do
        # The worker coming up a moment later, as a real one does: it owns
        # the session, then serves its Bridge.
        started ||= Samagotchi::Session.list(state_dir: tmpdir).first
        worker ||= Thread.new do
          sleep(0.3)
          locks << Samagotchi::OwnerLock.acquire(dir_of(started), kind: "worker")
          serve(started)
        end
        40_005
      end

      Dir.mktmpdir("proj") do |dir|
        expect(run("--new", "--dir", dir, "--image", png, "-m", "what is this?")).to eq(0), err.string
      end

      worker.join
      expect(Process).to have_received(:spawn).once
      expect(out.string).to eq("#{started.id}  started with 1 image\n")
      session = Samagotchi::Session.load(started.id, state_dir: tmpdir)
      expect(session.last_prompt).to be_nil
      expect(session.first_preview).to eq("what is this?")
      input = inputs_of(started).first
      expect(input).to include("prompt" => "what is this?")
      expect(images_in(started, input)).to eq(["tiny.png"])
    end

    it "with --new keeps the idle session and names it when its worker never comes up" do
      stub_const("Samagotchi::SessionManager::TURN_BRIDGE_WAIT", 0)
      allow(Process).to receive(:spawn).and_return(40_006)

      expect(run("--new", "--image", png, "-m", "hi")).to eq(1)
      started = Samagotchi::Session.list(state_dir: tmpdir).first
      expect(out.string).to eq("#{started.id}  failed: its worker did not start; the session is kept (chi --attach #{started.id})\n")
      expect(Process).to have_received(:spawn).once
    end
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
