# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/session_commands"
require "samagotchi/turn_flow"
require "samagotchi/memory_bundle/installer"

MCP_SHIPPED = File.expand_path("../../../lib/samagotchi/bundles/mcp", __dir__)
MCP_FAKE = File.expand_path("../../fixtures/mcp/fake_server.rb", __dir__)

def alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
end

# The mcp bundle's JSON-RPC client, against spec/fixtures/mcp/fake_server.rb.
RSpec.describe "The mcp bundle's client" do
  let(:client_class) do
    mod = Module.new
    mod.module_eval(File.read(File.join(MCP_SHIPPED, "plugin.rb")), "plugin.rb", 1)
    mod::Plugin::Client
  end
  let(:logged) { Queue.new }
  let(:exits) { Queue.new }
  let(:env) { {} }
  let(:client) do
    client_class.new([RbConfig.ruby, MCP_FAKE], env: env, log: ->(event, **fields) { logged << [event, fields] },
                                                on_exit: ->(reason) { exits << reason })
  end

  after { client.close }

  def initialize!
    client.request("initialize", { protocolVersion: "2025-06-18", capabilities: {} }, timeout: 5)
  end

  it "initializes, answers the server's ping on the way, and lists tools; stderr goes to the log" do
    expect(initialize!).to include("serverInfo" => { "name" => "fake", "version" => "1" })
    client.notify("notifications/initialized")
    expect(client.request("tools/list", nil, timeout: 5)["tools"].map { |t| t["name"] }).to eq(%w[echo add fail mixed])
    Timeout.timeout(2) { sleep(0.05) until logged.size.positive? }
    expect(logged.pop).to eq(["stderr", { line: "fake mcp server starting (normal)" }])
  end

  it "raises an error answer" do
    initialize!
    expect { client.request("tools/call", { name: "nope" }, timeout: 5) }
      .to raise_error(client_class::Error, "unknown tool (-32602)")
  end

  context "logging what it received" do
    let(:log_file) { File.join(Dir.mktmpdir("mcp-log-"), "received.jsonl") }
    let(:env) { { "FAKE_MCP_LOG" => log_file } }

    def received = File.readlines(log_file).map { |line| JSON.parse(line) }

    it "sends notifications/cancelled when the wait is cancelled" do
      initialize!
      cancel = false
      Thread.new { sleep(0.3); cancel = true }
      expect { client.request("tools/call", { name: "slow" }, timeout: 10, cancelled: -> { cancel }) }
        .to raise_error(client_class::Cancelled)
      Timeout.timeout(2) { sleep(0.05) until received.any? { |m| m["method"] == "notifications/cancelled" } }
      call = received.find { |m| m["method"] == "tools/call" }
      expect(received.last).to include("method" => "notifications/cancelled",
                                       "params" => { "requestId" => call["id"], "reason" => "cancelled by the user" })
      expect(received.find { |m| m["id"] == "srv-1" }).to include("result" => {})
    end

    it "times out, and says so to the server" do
      initialize!
      expect { client.request("tools/call", { name: "slow" }, timeout: 0.3) }
        .to raise_error(client_class::Timeout, "tools/call timed out after 0.3s")
      Timeout.timeout(2) { sleep(0.05) until received.any? { |m| m["method"] == "notifications/cancelled" } }
    end
  end

  it "fails a waiting call when the server exits, once, and every call after" do
    initialize!
    expect { client.request("tools/call", { name: "crash" }, timeout: 5) }
      .to raise_error(client_class::Dead, "the server exited (status 4)")
    expect(exits.pop(timeout: 2)).to eq("the server exited (status 4)")
    expect { client.request("tools/list", nil, timeout: 5) }.to raise_error(client_class::Dead)
    expect(exits.size).to eq(0)
  end

  it "ends the process on close, without an exit notice" do
    initialize!
    pid = client.pid
    client.close
    expect(alive?(pid)).to be(false)
    expect(exits.size).to eq(0)
  end

  it "kills a server that ignores stdin EOF" do
    client = client_class.new([RbConfig.ruby, "-e", "trap('TERM') {}; $stdin.read; sleep 30"])
    pid = client.pid
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.close
    expect(alive?(pid)).to be(false)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
  end

  it "raises Dead for a command that doesn't exist" do
    expect { client_class.new(["/nonexistent/mcp-server"]) }.to raise_error(client_class::Dead, /can't start/)
  end
end

# The shipped mcp bundle (lib/samagotchi/bundles/mcp), installed into an Engine.
RSpec.describe "The mcp bundle" do
  let(:tmpdir) { Dir.mktmpdir("mcp-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  let(:client) { instance_double(Samagotchi::Client, complete: nil) }
  let(:fake) { { "command" => [RbConfig.ruby, MCP_FAKE] } }
  let(:servers) { { "fake" => fake } }
  let(:settings) { { "servers" => servers, "startup_timeout" => 2, "timeout" => 5 } }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  before do
    FileUtils.mkdir_p(system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow_any_instance_of(Samagotchi::Engine).to receive(:bundle_settings).and_return("mcp" => settings)
    Samagotchi::MemoryBundle::Installer.new(source: MCP_SHIPPED, name: "mcp", scope: "system", strict: true).run
  end

  after do
    @engine&.shutdown
    FileUtils.rm_rf(tmpdir)
  end

  # An Engine whose init tasks (a server's first start) ran, as its first
  # turn sees it: the tasks done, their tools applied.
  def engine
    @engine ||= Samagotchi::Engine.new(client: client).tap do |built|
      @init_events = []
      built.subscribe(observer: ->(e) { @init_events << e })
      built.start_init_tasks!
      built.instance_variable_get(:@plugin_tasks).tasks.each { |task| task.thread&.join(10) }
      built.apply_staged_tools!
    end
  end

  def tools = engine.instance_variable_get(:@tools)

  def call_tool(name, args = {})
    tools[name].handler.call({ name: name, args: args }, nil)
  end

  # Through ToolRunner, with the session's images in +session_dir+.
  def run_tool(name, args = {}, vision: nil)
    kernel = engine.instance_variable_get(:@kernel)
    vision ||= Samagotchi::VisionContext.new(session_dir: session_dir, resizer: Samagotchi::ImageResizer.new(nil))
    kernel.turn_settings = kernel.turn_settings.with(vision: vision)
    Samagotchi::ToolRunner.new(kernel).run({ name: name, args: args }, iteration: 1, call_index: 1, call_count: 1,
                                                                       on_stream_event: nil, max_tool_output_chars: nil)
  end

  let(:session_dir) { File.join(tmpdir, "session").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:tiny_png) { File.expand_path("../../fixtures/images/tiny.png", __dir__) }

  # What the Engine's load and init tasks showed: notices and cards.
  def load_events
    engine
    engine.send(:announce_guardrail_failures, ->(e) { @init_events << e })
    @init_events.select { |e| %i[hook_notice card].include?(e[:type]) }
  end

  def server_pid
    engine.instance_variable_get(:@services).to_a.first.value.pid
  end

  it "installs cleanly (the manifest's sha256 is plugin.rb's)" do
    installer = Samagotchi::MemoryBundle::Installer.new(source: MCP_SHIPPED, name: "mcp", scope: "system", strict: true)
    installer.run
    expect(installer.warnings).to be_empty
  end

  it "installs with no memory file (nothing in the index) and loads as a plugin" do
    expect(Dir.glob(File.join(system_dir, "*.md")).map { |f| File.basename(f) }).not_to include("mcp.md")
    expect(engine.plugin_failures.any?).to be(false)
  end

  it "registers each tool as mcp_<server>_<tool>, sanitized, with its inputSchema, label and preview" do
    names = tools.entries.map(&:name).grep(/\Amcp_/)
    expect(names).to eq(%w[mcp_fake_echo mcp_fake_add mcp_fake_fail mcp_fake_mixed mcp_fake_slow mcp_fake_crash
                           mcp_fake_weird_name_v2 mcp_fake_changed mcp_fake_path])
    echo = tools["mcp_fake_echo"]
    expect(echo.schema).to include(name: "mcp_fake_echo", description: "Echo the text back.")
    expect(echo.schema[:parameters]).to include(properties: { text: { type: "string", description: "what to echo" } },
                                                required: ["text"])
    expect(echo.label).to eq("fake: echo")
    expect(echo.preview.call({ name: "mcp_fake_echo", args: { "text" => "hi there" } })).to eq("text=hi there")
    expect(echo.source).to eq("mcp")
  end

  it "calls a tool: text joined, other content as placeholders, isError as Error:" do
    expect(call_tool("mcp_fake_echo", { "text" => "BANANA42" })).to eq("echo: BANANA42")
    expect(call_tool("mcp_fake_add", { "a" => 2, "b" => 3.5 })).to eq("5.5")
    expect(call_tool("mcp_fake_mixed"))
      .to eq("first\n[image 1: image/png, attached]\ninline\n[resource link: file:///y.txt]\nlast")
    expect(call_tool("mcp_fake_fail")).to eq("Error: it broke")
  end

  describe "images" do
    it "attaches an image block's picture (decoded), the text saying where it was" do
      result = run_tool("mcp_fake_mixed")
      expect(result[:output]).to eq("[mcp_fake_mixed]\nfirst\n[image 1: image/png, attached]\ninline\n[resource link: file:///y.txt]\nlast")
      expect(result[:images].map { |ref| ref.slice(:name, :width, :height, :source) })
        .to eq([{ name: "mixed-1.png", width: 3, height: 2, source: "tool" }])
      expect(File.binread(File.join(session_dir, result[:images].first[:file]))).to eq(File.binread(tiny_png))
    end

    it "keeps the text and says so when the model can't see images" do
      blind = Samagotchi::VisionContext.new(session_dir: session_dir,
                                            capability: Samagotchi::VisionSupport::Answer.new(value: false, reason: "no"))
      result = run_tool("mcp_fake_mixed", vision: blind)
      expect(result[:output]).to end_with("last\nmixed-1.png is an image; this model can't see images")
      expect(result).not_to have_key(:images)
    end

    it "attaches an image whose path is the whole answer, when it is in the temp dir" do
      shot = File.join(tmpdir, "screenshot.png")
      FileUtils.cp(tiny_png, shot)
      result = run_tool("mcp_fake_path", { "path" => shot })
      expect(result[:output]).to eq("[mcp_fake_path]\n#{shot}\n[image 1: screenshot.png, attached]")
      expect(result[:images].map { |ref| ref[:name] }).to eq(["screenshot.png"])
    end

    context "when the server runs elsewhere" do
      let(:servers) { { "fake" => fake.merge("cwd" => tmpdir) } }

      it "leaves a path outside the temp dir and the server's cwd as text (and a text file, and a relative path)" do
        notes = File.join(tmpdir, "notes.png")
        File.write(notes, "not really a png")
        [tiny_png, notes, "screenshot.png"].each do |path|
          result = run_tool("mcp_fake_path", { "path" => path })
          expect(result[:output]).to eq("[mcp_fake_path]\n#{path}")
          expect(result).not_to have_key(:images)
        end
      end

      it "checks a path inside a sentence as a whole-text one: under a root, an image by its bytes" do
        notes = File.join(tmpdir, "notes.png")
        File.write(notes, "not really a png")
        text = "Saved to #{notes} and #{tiny_png}; see /nowhere/x.gif"
        result = run_tool("mcp_fake_path", { "path" => text })
        expect(result[:output]).to eq("[mcp_fake_path]\n#{text}")
        expect(result).not_to have_key(:images)
      end
    end

    it "attaches image paths inside a sentence, each once, past the sentence's full stop" do
      shot = File.join(tmpdir, "screenshot.png")
      second = File.join(tmpdir, "b.JPEG")
      spaced = File.join(tmpdir, "page 2.jpg") # a space: only a whole-text path can have one
      [shot, second, spaced].each { |path| FileUtils.cp(tiny_png, path) }
      text = "Saved screenshot to #{shot}. Also (#{shot}), \"#{second}\" and #{spaced}."
      result = run_tool("mcp_fake_path", { "path" => text })
      expect(result[:output])
        .to eq("[mcp_fake_path]\n#{text}\n[image 1: screenshot.png, attached]\n[image 2: b.JPEG, attached]")
      expect(result[:images].map { |ref| ref[:name] }).to eq(%w[screenshot.png b.JPEG])
    end

    context "when the image is in the server's cwd" do
      let(:servers) { { "fake" => fake.merge("cwd" => File.dirname(tiny_png)) } }

      it "attaches it" do
        allow(Dir).to receive(:tmpdir).and_return("/nonexistent-tmp")
        expect(run_tool("mcp_fake_path", { "path" => tiny_png })[:images].size).to eq(1)
      end
    end

    context "with attach_image_paths: false" do
      let(:servers) { { "fake" => fake.merge("attach_image_paths" => false) } }

      it "leaves the path as text" do
        shot = File.join(tmpdir, "screenshot.png")
        FileUtils.cp(tiny_png, shot)
        expect(run_tool("mcp_fake_path", { "path" => shot })).not_to have_key(:images)
      end
    end
  end

  it "times out a call by the settings' timeout" do
    settings["timeout"] = 0.3
    expect(call_tool("mcp_fake_slow")).to eq("Error: tools/call timed out after 0.3s")
  end

  it "stops waiting when the turn is cancelled" do
    allow(engine).to receive(:active_cancel_controller).and_return(double(cancelled?: true))
    expect(call_tool("mcp_fake_slow")).to eq("Error: tools/call was cancelled")
  end

  it "says a dead server's calls fail, with one notice" do
    notices = []
    engine.subscribe(observer: ->(e) { notices << e if e[:type] == :hook_notice })
    expect(call_tool("mcp_fake_crash")).to eq("Error: MCP server fake is not running (the server exited (status 4))")
    expect(call_tool("mcp_fake_echo", { "text" => "x" })).to start_with("Error: MCP server fake is not running")
    Timeout.timeout(2) { sleep(0.05) until notices.any? }
    expect(notices.map { |n| n[:text] }).to eq(["MCP server fake stopped: the server exited (status 4); its tools fail until chi restarts"])
  end

  context "with a broken server beside a working one" do
    let(:servers) do
      { "gone" => { "command" => ["/nonexistent/mcp-server"] }, "hung" => fake.merge("env" => { "FAKE_MCP_MODE" => "hang" }),
        "fake" => fake }
    end

    it "starts them in init tasks: chi's start doesn't wait; each broken one is a warn card; the rest works" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      built = Samagotchi::Engine.new(client: client)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      built.shutdown
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      engine
      # Side by side: one startup_timeout (the hung one's), not one each.
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3.5
      cards = load_events.select { |e| e[:type] == :card }
      expect(cards.map { |c| [c[:title], c[:body], c[:level]] }).to contain_exactly(
        ["gone didn't start",
         "MCP server gone didn't start: can't start /nonexistent/mcp-server: No such file or directory; its tools are left out", :warn],
        ["hung didn't start",
         "MCP server hung didn't start: initialize timed out after 2s; its tools are left out", :warn]
      )
      finished = @init_events.select { |e| e[:type] == :plugin_init_finished }
      expect(finished.map { |e| [e[:label], e[:ok], e[:summary]] }).to include(
        ["Starting MCP server fake (first run, saving its tools)", true, "fake ready, 9 tools"]
      )
      expect(tools.entries.map(&:name).grep(/\Amcp_/)).to all(start_with("mcp_fake_"))
      expect(call_tool("mcp_fake_echo", { "text" => "ok" })).to eq("echo: ok")
    end
  end

  context "with a server's tools: filter" do
    let(:servers) { { "fake" => fake.merge("tools" => ["echo", "a*"]) } }

    it "registers only those" do
      expect(tools.entries.map(&:name).grep(/\Amcp_/)).to eq(%w[mcp_fake_echo mcp_fake_add])
    end
  end

  context "with a name clash" do
    let(:servers) { { "fake" => fake, "fake-" => fake.merge("tools" => ["echo"]) } }

    it "leaves the second out with one notice" do
      expect(tools["mcp_fake_echo"]).not_to be_nil
      notices = load_events.select { |e| e[:type] == :hook_notice }.map { |e| e[:text] }
      expect(notices).to eq(["MCP tool fake-/echo left out: tool mcp_fake_echo is registered twice"])
    end
  end

  it "/mcp shows the servers, their state and tools as a card" do
    commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                               default_model: "Gemma-4B-it", registry: engine.command_registry)
    cards = []
    engine.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
    expect(engine.command_registry.lookup("/mcp").anytime).to be(true)
    engine.running_anytime { commands.run("/mcp") }
    expect(cards.last).to include(title: "MCP servers", id: "mcp-servers", source: "mcp")
    expect(cards.last[:body]).to start_with("**fake**: running (pid #{server_pid}), 9 tools\n- `mcp_fake_echo`\n")
  end

  describe "the tools/list cache (start: lazy)" do
    let(:pids_file) { File.join(tmpdir, "pids") }
    let(:tools_file) { File.join(tmpdir, "tools").tap { |f| File.write(f, "echo\nadd\nslow\n") } }
    let(:mode_file) { File.join(tmpdir, "mode") }
    let(:fake) do
      { "command" => [RbConfig.ruby, MCP_FAKE],
        "env" => { "FAKE_MCP_PIDS" => pids_file, "FAKE_MCP_TOOLS" => tools_file, "FAKE_MCP_MODE_FILE" => mode_file } }
    end

    def spawned = File.exist?(pids_file) ? File.readlines(pids_file).size : 0
    def mcp_tools = tools.entries.map(&:name).grep(/\Amcp_/)
    def cache = JSON.parse(File.read(File.join(ENV["XDG_STATE_HOME"], "samagotchi", "plugins", "mcp", "tools-fake.json")))

    # The next session: a new Engine on the same data dir.
    def next_engine
      @engine&.shutdown
      @engine = nil
      engine
    end

    def mcp_card
      cards = []
      handle = engine.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
      commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                                 default_model: "Gemma-4B-it", registry: engine.command_registry)
      engine.running_anytime { commands.run("/mcp") }
      engine.unsubscribe(handle: handle)
      cards.last[:body]
    end

    before do
      engine # the first run: no cache, the server starts and its list is saved
      expect(spawned).to eq(1)
    end

    it "saves the unfiltered list keyed by a digest, never the env" do
      expect(cache["tools"].map { |t| t["name"] }).to eq(%w[echo add slow])
      expect(cache["digest"]).to match(/\A\h{64}\z/)
      expect(File.read(File.join(ENV["XDG_STATE_HOME"], "samagotchi", "plugins", "mcp", "tools-fake.json")))
        .not_to include(pids_file)
    end

    it "registers a hit's tools without starting the server; the first call starts it" do
      next_engine
      expect(mcp_tools).to eq(%w[mcp_fake_echo mcp_fake_add mcp_fake_slow])
      expect(spawned).to eq(1)
      expect(mcp_card).to eq("**fake**: cached (not started), 3 tools\n- `mcp_fake_echo`\n- `mcp_fake_add`\n- `mcp_fake_slow`")
      expect(spawned).to eq(1)
      expect(call_tool("mcp_fake_echo", { "text" => "lazy" })).to eq("echo: lazy")
      expect(spawned).to eq(2)
      expect(call_tool("mcp_fake_add", { "a" => 1, "b" => 2 })).to eq("3")
      expect(spawned).to eq(2)
      expect(mcp_card).to start_with("**fake**: running (pid ")
      expect(engine.apply_staged_tools!).to be(false)
    end

    it "replaces the tools for the next turn when the live list differs, and rewrites the cache" do
      File.write(tools_file, "echo\nfail\n")
      next_engine
      expect(mcp_tools).to eq(%w[mcp_fake_echo mcp_fake_add mcp_fake_slow])
      expect(call_tool("mcp_fake_echo", { "text" => "x" })).to eq("echo: x")
      expect(cache["tools"].map { |t| t["name"] }).to eq(%w[echo fail])
      expect(mcp_tools).to eq(%w[mcp_fake_echo mcp_fake_add mcp_fake_slow])
      expect(engine.apply_staged_tools!).to be(true)
      expect(mcp_tools).to eq(%w[mcp_fake_echo mcp_fake_fail])
      expect(call_tool("mcp_fake_fail")).to eq("Error: it broke")
    end

    it "lists the tools again on notifications/tools/list_changed: the cache and the next turn's tools" do
      File.write(tools_file, "echo\nadd\nslow\nchanged\n")
      next_engine
      expect(call_tool("mcp_fake_echo", { "text" => "x" })).to eq("echo: x")
      expect(engine.apply_staged_tools!).to be(true)
      File.write(tools_file, "echo\nchanged\n")
      expect(call_tool("mcp_fake_changed")).to eq("changed")
      Timeout.timeout(5) { sleep(0.05) until cache["tools"].map { |t| t["name"] } == %w[echo changed] }
      Timeout.timeout(5) { sleep(0.05) until engine.apply_staged_tools! }
      expect(mcp_tools).to eq(%w[mcp_fake_echo mcp_fake_changed])
      expect(call_tool("mcp_fake_echo", { "text" => "still" })).to eq("echo: still")
      expect(spawned).to eq(2)
    end

    context "when the config changes" do
      it "misses: the server starts with the session and the cache is rewritten" do
        digest = cache["digest"]
        servers["fake"] = fake.merge("env" => fake["env"].merge("EXTRA" => "1"))
        next_engine
        expect(spawned).to eq(2)
        expect(cache["digest"]).not_to eq(digest)
        expect(mcp_card).to start_with("**fake**: running (pid ")
      end
    end

    context "with start: eager" do
      it "starts the server with every session, cache or not" do
        servers["fake"] = fake.merge("start" => "eager")
        next_engine
        expect(spawned).to eq(2)
        expect(mcp_tools).to eq(%w[mcp_fake_echo mcp_fake_add mcp_fake_slow])
      end
    end

    it "stops a start that hangs when the turn is cancelled, and leaves the server cached for the next call" do
      File.write(mode_file, "hang")
      settings["startup_timeout"] = 30
      next_engine
      cancel = false
      allow(engine).to receive(:active_cancel_controller) { double(cancelled?: cancel) }
      Thread.new { sleep(0.3); cancel = true }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(call_tool("mcp_fake_echo", { "text" => "x" })).to eq("Error: initialize was cancelled")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      File.write(mode_file, "")
      cancel = false
      expect(call_tool("mcp_fake_echo", { "text" => "again" })).to eq("echo: again")
    end

    context "when the cache is over a day old" do
      let(:cache_file) { File.join(ENV["XDG_STATE_HOME"], "samagotchi", "plugins", "mcp", "tools-fake.json") }

      before do
        File.write(cache_file, JSON.generate(cache.merge("saved_at" => (Time.now - (25 * 3600)).utc.iso8601)))
        File.write(tools_file, "echo\n")
      end

      it "still registers the cached tools; a quiet refresh lists them with a server of its own and replaces them" do
        next_engine
        # The refresh's server, stopped after listing; the session's isn't started.
        expect(spawned).to eq(2)
        expect(alive?(File.readlines(pids_file).last.to_i)).to be(false)
        expect(@init_events.map { |e| e[:type] }).not_to include(:plugin_init_started, :plugin_init_finished)
        expect(cache["tools"].map { |t| t["name"] }).to eq(%w[echo])
        expect(Time.iso8601(cache["saved_at"])).to be > Time.now - 60
        expect(mcp_tools).to eq(%w[mcp_fake_echo])
        expect(mcp_card).to eq("**fake**: cached (not started), 1 tool\n- `mcp_fake_echo`")
      end

      it "leaves the refresh to the worker that holds the lock" do
        File.open("#{cache_file}.lock", File::CREAT | File::RDWR) do |lock|
          lock.flock(File::LOCK_EX)
          next_engine
        end
        expect(spawned).to eq(1)
        expect(mcp_tools).to eq(%w[mcp_fake_echo mcp_fake_add mcp_fake_slow])
      end
    end

    %w[hang exit].each do |mode|
      context "when a cached server doesn't start (#{mode})" do
        it "fails the first call once, answers later calls at once, and drops its tools next turn; the cache stays" do
          File.write(mode_file, mode)
          next_engine
          notices = []
          engine.subscribe(observer: ->(e) { notices << e if e[:type] == :hook_notice })
          expect(call_tool("mcp_fake_echo", { "text" => "x" })).to start_with("Error: MCP server fake didn't start: ")
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          expect(call_tool("mcp_fake_add", { "a" => 1, "b" => 2 })).to start_with("Error: MCP server fake didn't start: ")
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
          expect(spawned).to eq(2)
          expect(notices.map { |n| n[:text] }).to contain_exactly(
            a_string_starting_with("MCP server fake didn't start: ").and(ending_with("its tools are left out from the next turn"))
          )
          expect(engine.apply_staged_tools!).to be(true)
          expect(mcp_tools).to be_empty
          expect(cache["tools"].size).to eq(3)
        end
      end
    end
  end

  it "stops the server process when the Engine shuts down" do
    pid = server_pid
    expect(alive?(pid)).to be(true)
    engine.shutdown
    expect(alive?(pid)).to be(false)
    expect(call_tool("mcp_fake_echo", { "text" => "x" })).to eq("Error: service mcp:fake is stopped")
  end
end
