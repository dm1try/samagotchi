# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/mcp_bundle"

# The shipped mcp bundle (lib/samagotchi/bundles/mcp), installed into an
# Engine. Its tools/list cache is in mcp_bundle_cache_spec, its client in
# mcp_client_spec.
RSpec.describe "The mcp bundle" do
  include_context "the mcp bundle in an Engine"

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
    # By name (Tools::Registry), whatever order the server lists them in.
    expect(names).to eq(%w[mcp_fake_add mcp_fake_blob mcp_fake_changed mcp_fake_crash mcp_fake_echo mcp_fake_fail
                           mcp_fake_mixed mcp_fake_path mcp_fake_slow mcp_fake_weird_name_v2])
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
      .to eq("first\n[image 1: image/png]\ninline\n[resource link: file:///y.txt]\nlast")
    expect(call_tool("mcp_fake_fail")).to eq("Error: it broke")
  end

  describe "images" do
    it "attaches an image block's picture (decoded), the text saying where it was" do
      result = run_tool("mcp_fake_mixed")
      expect(result[:output]).to eq("[mcp_fake_mixed]\nfirst\n[image 1: image/png]\ninline\n[resource link: file:///y.txt]\nlast")
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

    it "writes a neutral image line, never claiming it was attached" do
      result = run_tool("mcp_fake_mixed")
      expect(result[:output]).to include("[image 1: image/png]")
      expect(result[:output]).not_to include("attached")
    end

    it "attaches a resource block carrying an image blob" do
      result = run_tool("mcp_fake_blob")
      expect(result[:output]).to eq("[mcp_fake_blob]\nhere\n[image 1: image/png]")
      expect(result[:images].map { |ref| ref.slice(:name, :width, :height, :source) })
        .to eq([{ name: "blob-1.png", width: 3, height: 2, source: "tool" }])
      expect(File.binread(File.join(session_dir, result[:images].first[:file]))).to eq(File.binread(tiny_png))
    end

    it "attaches an image whose path is the whole answer, when it is in the temp dir" do
      shot = File.join(tmpdir, "screenshot.png")
      FileUtils.cp(tiny_png, shot)
      result = run_tool("mcp_fake_path", { "path" => shot })
      expect(result[:output]).to eq("[mcp_fake_path]\n#{shot}\n[image 1: screenshot.png]")
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
        .to eq("[mcp_fake_path]\n#{text}\n[image 1: screenshot.png]\n[image 2: b.JPEG]")
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

  describe "a server that exits" do
    let(:pids_file) { File.join(tmpdir, "pids") }
    let(:fake) { { "command" => [RbConfig.ruby, MCP_FAKE], "env" => { "FAKE_MCP_PIDS" => pids_file } } }
    let(:notices) { [] }

    def pids = File.readlines(pids_file).map(&:to_i)

    before { engine.subscribe(observer: ->(e) { notices << e[:text] if e[:type] == :hook_notice }) }

    it "restarts on its next call, with one notice" do
      expect(call_tool("mcp_fake_crash")).to eq("Error: MCP server fake is not running (the server exited (status 4))")
      Timeout.timeout(2) { sleep(0.05) until notices.any? }
      expect(notices).to eq(["MCP server fake stopped: the server exited (status 4); it restarts on its next call"])
      expect(call_tool("mcp_fake_echo", { "text" => "back" })).to eq("echo: back")
      expect(call_tool("mcp_fake_add", { "a" => 1, "b" => 2 })).to eq("3")
      expect(pids.size).to eq(2)
      expect(alive?(pids.first)).to be(false)
      expect(engine.apply_staged_tools!).to be(false)
    end

    it "restarts at most 3 times a session; then its calls fail at once, and the notice says so" do
      4.times do |i|
        expect(call_tool("mcp_fake_echo", { "text" => "x" })).to eq("echo: x") if i.positive? # the restart
        expect(call_tool("mcp_fake_crash")).to start_with("Error: MCP server fake is not running")
        Timeout.timeout(2) { sleep(0.05) until notices.size == i + 1 }
      end
      expect(notices.last)
        .to eq("MCP server fake stopped: the server exited (status 4); it was restarted 3 times, its tools fail until chi restarts")
      expect(call_tool("mcp_fake_echo", { "text" => "x" }))
        .to eq("Error: MCP server fake is not running (the server exited (status 4); restarted 3 times this session)")
      expect(pids.size).to eq(4)
    end

    it "stops the restarted process when the Engine shuts down" do
      call_tool("mcp_fake_crash")
      expect(call_tool("mcp_fake_echo", { "text" => "x" })).to eq("echo: x")
      expect(alive?(pids.last)).to be(true)
      engine.shutdown
      expect(alive?(pids.last)).to be(false)
      expect(call_tool("mcp_fake_echo", { "text" => "x" })).to eq("Error: service mcp:fake is stopped")
    end
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
        ["Starting MCP server fake (first run, saving its tools)", true, "fake ready, 10 tools"]
      )
      expect(tools.entries.map(&:name).grep(/\Amcp_/)).to all(start_with("mcp_fake_"))
      expect(call_tool("mcp_fake_echo", { "text" => "ok" })).to eq("echo: ok")
    end
  end

  context "with a server's tools: filter" do
    let(:servers) { { "fake" => fake.merge("tools" => ["echo", "a*"]) } }

    it "registers only those" do
      expect(tools.entries.map(&:name).grep(/\Amcp_/)).to eq(%w[mcp_fake_add mcp_fake_echo])
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
    tokens = chat_tokens(tools.entries.map(&:name).grep(/\Amcp_/))
    expect(tokens).to be > 100
    expect(cards.last[:body]).to start_with("**fake**: running (pid #{server_pid}), 10 tools, ~#{tokens} tokens\n- `mcp_fake_")
    listed = cards.last[:body].scan(/^- `(\w+)`$/).flatten
    expect(listed.size).to eq(10)
    expect(listed).to eq(listed.sort) # not the server's tools/list order (echo first)
    expect(listed.first).not_to eq("mcp_fake_echo")
    expect(cards.last[:body]).to end_with("\n\nTotal: ~#{tokens} tokens of tool definitions in every request " \
                                          "(estimated: their JSON as the chat API gets it, ÷ 4).")
  end

  context "with two servers, one that doesn't start" do
    let(:servers) { { "fake" => fake.merge("tools" => %w[echo add]), "gone" => { "command" => ["/nonexistent/mcp-server"] } } }

    it "/mcp totals only the tools the model has, and the load log records each server's estimate" do
      log = []
      allow(Samagotchi::Log).to receive(:info).and_call_original
      allow(Samagotchi::Log).to receive(:info).with(:plugins, "mcp_tools_estimated", any_args) { |*, **fields| log << fields }
      commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                                 default_model: "Gemma-4B-it", registry: engine.command_registry)
      cards = []
      engine.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
      engine.running_anytime { commands.run("/mcp") }
      tokens = chat_tokens(%w[mcp_fake_add mcp_fake_echo])
      expect(cards.last[:body]).to include("**fake**: running (pid #{server_pid}), 2 tools, ~#{tokens} tokens\n",
                                           "**gone**: failed: ")
      expect(cards.last[:body]).to end_with("Total: ~#{tokens} tokens of tool definitions in every request " \
                                            "(estimated: their JSON as the chat API gets it, ÷ 4).")
      expect(log).to eq([{ bundle: "mcp", server: "fake", tools: 2, tokens: tokens }])
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
