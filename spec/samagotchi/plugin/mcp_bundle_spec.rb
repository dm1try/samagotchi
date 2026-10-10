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

  it "registers find_mcp_tools and mcp_call, never a tool per server tool" do
    expect(mcp_tools).to eq(%w[find_mcp_tools mcp_call])
    find_tool = tools["find_mcp_tools"]
    expect(find_tool.schema[:parameters]).to include(required: ["query"])
    expect(find_tool.schema[:parameters][:properties].keys).to eq(%i[query server])
    call = tools["mcp_call"]
    expect(call.schema[:parameters]).to include(required: ["tool"])
    expect(call.schema[:parameters][:properties][:args]).to include(type: "object")
    expect(call.label).to eq("mcp")
    expect(call.source).to eq("mcp")
    expect(engine.apply_staged_tools!).to be(false)
  end

  context "with no servers" do
    let(:servers) { {} }

    it "registers no tools" do
      expect(mcp_tools).to be_empty
    end
  end

  it "previews mcp_call as <server>/<tool> and its arguments, find_mcp_tools as its query" do
    preview = tools["mcp_call"].preview
    expect(preview.call({ name: "mcp_call", args: { "tool" => "fake/echo", "args" => { "text" => "hi there" } } }))
      .to eq("fake/echo text=hi there")
    expect(preview.call({ name: "mcp_call", args: { "tool" => "mcp_fake_echo", "args" => '{"text": "json"}' } }))
      .to eq("fake/echo text=json")
    expect(preview.call({ name: "mcp_call", args: { "tool" => "fake/nope" } })).to eq("fake/nope")
    expect(tools["find_mcp_tools"].preview.call({ name: "find_mcp_tools", args: { "query" => "add", "server" => "fake" } }))
      .to eq("add in fake")
  end

  describe "find_mcp_tools" do
    let(:tools_file) { File.join(tmpdir, "tools") }
    let(:fake) { { "command" => MCP_FAKE_COMMAND, "env" => { "FAKE_MCP_TOOLS" => tools_file } } }

    before do
      File.write(tools_file, %w[echo navigate_page new_page list_pages handle_dialog take_screenshot bad].join("\n"))
    end

    def names(text) = text.scan(%r{^(fake/\S+)(?: \(bad schema\))?: }).flatten

    it "answers the best matches, each with its name, description and inputSchema" do
      text = find("screenshot")
      expect(text).to start_with("Call one with mcp_call(tool: \"<server>/<tool>\", args: {…}).\n\n" \
                                 "fake/take_screenshot: Take a screenshot of the page or of an element on the page.\n" \
                                 "inputSchema: {\"type\":\"object\",\"properties\":{\"fullPage\":{\"type\":\"boolean\"}}}")
    end

    it "weighs a word by how few tools have it, and a name hit 3 times a description one" do
      # page is in nearly every tool, browser in three: url and open decide.
      expect(names(find("open url browser page"))).to eq(%w[fake/new_page fake/list_pages fake/navigate_page
                                                            fake/handle_dialog fake/take_screenshot])
      # In three names and two descriptions: the names first, plurals too.
      expect(names(find("pages")).take(3)).to contain_exactly("fake/navigate_page", "fake/new_page", "fake/list_pages")
    end

    it "answers at most 5, and a search with no match lists the tool names" do
      expect(names(find("the a")).size).to eq(5)
      expect(find("zebra")).to eq("No MCP tool matches \"zebra\".\n\nMCP tools by server (call one as <server>/<tool>; " \
                                  "search for its inputSchema):\nfake: echo, navigate_page, new_page, list_pages, " \
                                  "handle_dialog, take_screenshot, bad (bad schema)")
    end

    it "lists every server's tool names, without schemas, for an empty query" do
      expect(find("  ")).to start_with("MCP tools by server").and(end_with("\nfake: echo, navigate_page, new_page, list_pages, " \
                                                                          "handle_dialog, take_screenshot, bad (bad schema)"))
    end

    it "searches one server when asked, and names the servers for an unknown one" do
      expect(names(find("echo", "fake"))).to eq(%w[fake/echo])
      expect(find("echo", "nope")).to eq("Error: no MCP server nope. Servers: fake")
    end

    it "shows a tool with a bad inputSchema as such (one notice), and mcp_call refuses it" do
      expect(load_events.select { |e| e[:type] == :hook_notice }.map { |e| e[:text] })
        .to eq(["MCP tool fake/bad can't be called: schema must be {type: \"object\", properties: {…}}"])
      expect(find("inputschema object")).to include("fake/bad (bad schema): Its inputSchema is not an object.\n" \
                                                    "It can't be called: schema must be")
      expect(mcp("bad")).to eq("Error: fake/bad can't be called: schema must be {type: \"object\", properties: {…}}")
    end

    it "/mcp lists them all, the bad schema marked, and counts the ones mcp_call can call" do
      commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                                 default_model: "Gemma-4B-it", registry: engine.command_registry)
      cards = []
      engine.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
      engine.running_anytime { commands.run("/mcp") }
      expect(cards.last[:body]).to start_with("**fake**: running (pid #{server_pid}), 6 tools, ~")
      expect(cards.last[:body]).to include("\n- `fake/bad` (bad schema)\n- `fake/echo`\n")
    end

    it "describes the servers, never their tools" do
      description = tools["find_mcp_tools"].schema[:description]
      expect(description).to end_with("\nServers:\n- fake") # a first run: known by name only
      expect(description).not_to include("navigate_page")
    end
  end

  describe "mcp_call" do
    it "takes mcp_<server>_<tool>, looked up by its sanitized name" do
      expect(call_tool("mcp_call", { "tool" => "mcp_fake_echo", "args" => { "text" => "by name" } })).to eq("echo: by name")
      # The server doesn't know it (it answers -32602): a JSON-RPC error, with the schema.
      expect(call_tool("mcp_call", { "tool" => "mcp_fake_weird_name_v2" }))
        .to eq("Error: unknown tool (-32602)\n\nfake/Weird-Name.v2's inputSchema: {\"type\":\"object\",\"properties\":{}}")
    end

    it "answers a tool it doesn't know with the closest ones" do
      expect(mcp("echo_text")).to start_with("Error: no MCP tool fake/echo_text. Closest: fake/echo, ")
      expect(call_tool("mcp_call", { "tool" => "zebra" })).to eq("Error: no MCP tool zebra. Search with find_mcp_tools.")
    end

    it "types the arguments by the tool's inputSchema, and takes them as JSON text" do
      expect(mcp("add", { "a" => "2", "b" => "3.5" })).to eq("5.5")
      expect(call_tool("mcp_call", { "tool" => "fake/add", "args" => '{"a": 1, "b": "2"}' })).to eq("3")
      expect(mcp("mixed", nil)).to start_with("first\n")
    end

    it "answers arguments that aren't an object with the tool's inputSchema" do
      expect(call_tool("mcp_call", { "tool" => "fake/echo", "args" => "hello" }))
        .to eq("Error: args must be an object.\n\nfake/echo's inputSchema: {\"type\":\"object\",\"properties\":" \
               "{\"text\":{\"type\":\"string\",\"description\":\"what to echo\"}},\"required\":[\"text\"]}")
    end

    it "gives guardrails the tool it acts as (today's name), its arguments and the question's label" do
      targets = tools["mcp_call"].targets
      expect(targets.call({ name: "mcp_call", args: { "tool" => "fake/add", "args" => { "a" => "1", "b" => 2 } } }))
        .to eq(acts_as: "mcp_fake_add", args: { "a" => 1, "b" => 2 }, label: "fake: add")
      # Not indexed: named from what the model gave, so a rule on mcp_fake_* still sees it.
      expect(targets.call({ name: "mcp_call", args: { "tool" => "fake/nope" } }))
        .to eq(acts_as: "mcp_fake_nope", args: {}, label: "fake: nope")
      expect(targets.call({ name: "mcp_call", args: { "tool" => "nope" } })).to eq({})
    end

    context "with a rule on one server's tools" do
      before do
        rule = { "id" => "fake-ask", "tool" => "mcp_fake_*", "verdict" => "ask", "reason" => "a fake tool", "scopes" => %w[once] }
        File.write(Samagotchi::ConfigFile.global_path, YAML.dump("guardrails" => { "rules" => [rule] }))
      end

      it "asks for an mcp_call to that server, by <server>: <tool>, and not for a search" do
        gate = engine.instance_variable_get(:@kernel).guardrail_gate
        call = { name: "mcp_call", args: { "tool" => "fake/echo", "args" => { "text" => "hi" } } }
        verdict = gate.evaluate(call, iteration: 1, params: "")
        expect(verdict).to be_ask
        expect(verdict.rule).to eq("fake-ask")
        expect(gate.evaluate({ name: "find_mcp_tools", args: { "query" => "echo" } }, iteration: 1, params: "")).not_to be_ask
        engine.interface = :worker
        thread = Thread.new { engine.request_approval(verdict) }
        Timeout.timeout(2) { sleep(0.005) until engine.pending_question }
        pending = engine.pending_question
        expect(pending[:approval]).to include(tool: "mcp_call", acts_as: "mcp_fake_echo", label: "fake: echo")
        expect(pending[:question].lines.first).to eq("fake: echo: text=hi\n")
        engine.cancel_question("dismissed", id: pending[:id])
        thread.join(2)
      end
    end

    context "while a first-run server is starting" do
      let(:fake) { { "command" => MCP_FAKE_COMMAND, "env" => { "FAKE_MCP_MODE" => "slow", "FAKE_MCP_DELAY" => "1" } } }

      it "searches say to try again, and a call waits for it" do
        settings["startup_timeout"] = 10
        @engine = Samagotchi::Engine.new(client: client)
        @engine.start_init_tasks!
        expect(find("echo")).to eq("No MCP tool matches \"echo\".\n\nMCP tools by server (call one as <server>/<tool>; " \
                                   "search for its inputSchema):\nfake (starting, try again)")
        expect(mcp("echo", { "text" => "waited" })).to eq("echo: waited")
        expect(names = find("echo")).to include("fake/echo: Echo the text back.")
        expect(names).not_to include("starting")
      end

      context "beside one that started" do
        let(:servers) { { "fake" => fake, "quick" => { "command" => MCP_FAKE_COMMAND } } }

        it "a miss named <server>/ waits only for that server, a miss of a starting one's tool for it" do
          settings["startup_timeout"] = 10
          fake["env"]["FAKE_MCP_DELAY"] = "3"
          @engine = Samagotchi::Engine.new(client: client)
          @engine.start_init_tasks!
          expect(wait_until(timeout: 5) { find("", "quick").include?("quick: echo") }).to be(true)

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          expect(mcp("nope", server: "quick")).to start_with("Error: no MCP tool quick/nope.")
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
          expect(find("", "fake")).to include("fake (starting, try again)")
          expect(mcp("echo", { "text" => "waited" })).to eq("echo: waited")
        end
      end

      context "with a deny rule on its tools" do
        before do
          rule = { "id" => "fake-deny", "tool" => "mcp_fake_*", "verdict" => "deny", "reason" => "not fake" }
          File.write(Samagotchi::ConfigFile.global_path, YAML.dump("guardrails" => { "rules" => [rule] }))
        end

        it "gives guardrails the tool by the name the model gave, so the rule denies a call made before the index fills" do
          settings["startup_timeout"] = 10
          @engine = Samagotchi::Engine.new(client: client)
          @engine.start_init_tasks!
          expect(find("echo")).to include("fake (starting, try again)")
          targets = tools["mcp_call"].targets
          expect(targets.call({ name: "mcp_call", args: { "tool" => "fake/echo", "args" => { "text" => "x" } } }))
            .to eq(acts_as: "mcp_fake_echo", args: { "text" => "x" }, label: "fake: echo")
          expect(targets.call({ name: "mcp_call", args: { "tool" => "mcp_fake_echo" } })).to eq(acts_as: "mcp_fake_echo", args: {})
          gate = @engine.instance_variable_get(:@kernel).guardrail_gate
          verdict = gate.evaluate({ name: "mcp_call", args: { "tool" => "fake/echo", "args" => { "text" => "x" } } },
                                  iteration: 1, params: "")
          expect(verdict).to be_deny
          expect(verdict.rule).to eq("fake-deny")
        end
      end
    end

    it "refuses a tool whose name isn't the one guardrails were given (a bare tool name)" do
      expect(tools["mcp_call"].targets.call({ name: "mcp_call", args: { "tool" => "echo" } })).to eq({})
      expect(call_tool("mcp_call", { "tool" => "echo", "args" => { "text" => "x" } })).to start_with("Error: no MCP tool echo.")
    end
  end

  it "calls a tool: text joined, other content as placeholders, isError as Error:" do
    expect(mcp("echo", { "text" => "BANANA42" })).to eq("echo: BANANA42")
    expect(mcp("add", { "a" => 2, "b" => 3.5 })).to eq("5.5")
    expect(mcp("mixed"))
      .to eq("first\n[image 1: image/png]\ninline\n[resource link: file:///y.txt]\nlast")
    expect(mcp("fail")).to start_with("Error: it broke\n\nfake/fail's inputSchema: ")
  end

  describe "images" do
    it "attaches an image block's picture (decoded), the text saying where it was" do
      result = run_mcp("mixed")
      expect(result[:output]).to eq("[mcp_call]\nfirst\n[image 1: image/png]\ninline\n[resource link: file:///y.txt]\nlast")
      expect(result[:images].map { |ref| ref.slice(:name, :width, :height, :source) })
        .to eq([{ name: "mixed-1.png", width: 3, height: 2, source: "tool" }])
      expect(File.binread(File.join(session_dir, result[:images].first[:file]))).to eq(File.binread(tiny_png))
    end

    it "keeps the text and says so when the model can't see images" do
      blind = Samagotchi::VisionContext.new(session_dir: session_dir,
                                            capability: Samagotchi::VisionSupport::Answer.new(value: false, reason: "no"))
      result = run_mcp("mixed", vision: blind)
      expect(result[:output]).to end_with("last\nmixed-1.png is an image; this model can't see images")
      expect(result).not_to have_key(:images)
    end

    it "writes a neutral image line, never claiming it was attached" do
      result = run_mcp("mixed")
      expect(result[:output]).to include("[image 1: image/png]")
      expect(result[:output]).not_to include("attached")
    end

    it "attaches a resource block carrying an image blob" do
      result = run_mcp("blob")
      expect(result[:output]).to eq("[mcp_call]\nhere\n[image 1: image/png]")
      expect(result[:images].map { |ref| ref.slice(:name, :width, :height, :source) })
        .to eq([{ name: "blob-1.png", width: 3, height: 2, source: "tool" }])
      expect(File.binread(File.join(session_dir, result[:images].first[:file]))).to eq(File.binread(tiny_png))
    end

    it "attaches an image whose path is the whole answer, when it is in the temp dir" do
      shot = File.join(tmpdir, "screenshot.png")
      FileUtils.cp(tiny_png, shot)
      result = run_mcp("path", { "path" => shot })
      expect(result[:output]).to eq("[mcp_call]\n#{shot}\n[image 1: screenshot.png]")
      expect(result[:images].map { |ref| ref[:name] }).to eq(["screenshot.png"])
    end

    context "when the server runs elsewhere" do
      let(:servers) { { "fake" => fake.merge("cwd" => tmpdir) } }

      it "leaves a path outside the temp dir and the server's cwd as text (and a text file, and a relative path)" do
        notes = File.join(tmpdir, "notes.png")
        File.write(notes, "not really a png")
        [tiny_png, notes, "screenshot.png"].each do |path|
          result = run_mcp("path", { "path" => path })
          expect(result[:output]).to eq("[mcp_call]\n#{path}")
          expect(result).not_to have_key(:images)
        end
      end

      it "checks a path inside a sentence as a whole-text one: under a root, an image by its bytes" do
        notes = File.join(tmpdir, "notes.png")
        File.write(notes, "not really a png")
        text = "Saved to #{notes} and #{tiny_png}; see /nowhere/x.gif"
        result = run_mcp("path", { "path" => text })
        expect(result[:output]).to eq("[mcp_call]\n#{text}")
        expect(result).not_to have_key(:images)
      end
    end

    it "attaches image paths inside a sentence, each once, past the sentence's full stop" do
      shot = File.join(tmpdir, "screenshot.png")
      second = File.join(tmpdir, "b.JPEG")
      spaced = File.join(tmpdir, "page 2.jpg") # a space: only a whole-text path can have one
      [shot, second, spaced].each { |path| FileUtils.cp(tiny_png, path) }
      text = "Saved screenshot to #{shot}. Also (#{shot}), \"#{second}\" and #{spaced}."
      result = run_mcp("path", { "path" => text })
      expect(result[:output])
        .to eq("[mcp_call]\n#{text}\n[image 1: screenshot.png]\n[image 2: b.JPEG]")
      expect(result[:images].map { |ref| ref[:name] }).to eq(%w[screenshot.png b.JPEG])
    end

    context "when the image is in the server's cwd" do
      let(:servers) { { "fake" => fake.merge("cwd" => File.dirname(tiny_png)) } }

      it "attaches it" do
        allow(Dir).to receive(:tmpdir).and_return("/nonexistent-tmp")
        expect(run_mcp("path", { "path" => tiny_png })[:images].size).to eq(1)
      end
    end

    context "with attach_image_paths: false" do
      let(:servers) { { "fake" => fake.merge("attach_image_paths" => false) } }

      it "leaves the path as text" do
        shot = File.join(tmpdir, "screenshot.png")
        FileUtils.cp(tiny_png, shot)
        expect(run_mcp("path", { "path" => shot })).not_to have_key(:images)
      end
    end
  end

  it "times out a call by the settings' timeout" do
    settings["timeout"] = 0.3
    expect(mcp("slow")).to eq("Error: tools/call timed out after 0.3s")
  end

  it "stops waiting when the turn is cancelled" do
    allow(engine).to receive(:active_cancel_controller).and_return(double(cancelled?: true))
    expect(mcp("slow")).to eq("Error: tools/call was cancelled")
  end

  describe "a server that exits" do
    let(:pids_file) { File.join(tmpdir, "pids") }
    let(:fake) { { "command" => MCP_FAKE_COMMAND, "env" => { "FAKE_MCP_PIDS" => pids_file } } }
    let(:notices) { [] }

    def pids = File.readlines(pids_file).map(&:to_i)

    before { engine.subscribe(observer: ->(e) { notices << e[:text] if e[:type] == :hook_notice }) }

    it "restarts on its next call, with one notice" do
      expect(mcp("crash")).to eq("Error: MCP server fake is not running (the server exited (status 4))")
      Timeout.timeout(2) { sleep(0.05) until notices.any? }
      expect(notices).to eq(["MCP server fake stopped: the server exited (status 4); it restarts on its next call"])
      expect(mcp("echo", { "text" => "back" })).to eq("echo: back")
      expect(mcp("add", { "a" => 1, "b" => 2 })).to eq("3")
      expect(pids.size).to eq(2)
      expect(alive?(pids.first)).to be(false)
      expect(engine.apply_staged_tools!).to be(false)
    end

    it "restarts at most 3 times a session; then its calls fail at once, and the notice says so" do
      4.times do |i|
        expect(mcp("echo", { "text" => "x" })).to eq("echo: x") if i.positive? # the restart
        expect(mcp("crash")).to start_with("Error: MCP server fake is not running")
        Timeout.timeout(2) { sleep(0.05) until notices.size == i + 1 }
      end
      expect(notices.last)
        .to eq("MCP server fake stopped: the server exited (status 4); it was restarted 3 times, its tools fail until chi restarts")
      expect(mcp("echo", { "text" => "x" }))
        .to eq("Error: MCP server fake is not running (the server exited (status 4); restarted 3 times this session)")
      expect(pids.size).to eq(4)
    end

    it "stops the restarted process when the Engine shuts down" do
      mcp("crash")
      expect(mcp("echo", { "text" => "x" })).to eq("echo: x")
      expect(alive?(pids.last)).to be(true)
      engine.shutdown
      expect(alive?(pids.last)).to be(false)
      expect(mcp("echo", { "text" => "x" })).to eq("Error: service mcp:fake is stopped")
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
         "MCP server gone didn't start: can't start /nonexistent/mcp-server: No such file or directory; " \
         "its calls fail until chi restarts", :warn],
        ["hung didn't start",
         "MCP server hung didn't start: initialize timed out after 2s; its calls fail until chi restarts", :warn]
      )
      finished = @init_events.select { |e| e[:type] == :plugin_init_finished }
      expect(finished.map { |e| [e[:label], e[:ok], e[:summary]] }).to include(
        ["Starting MCP server fake (first run, saving its tools)", true, "fake ready, 10 tools"]
      )
      expect(mcp("echo", { "text" => "ok" })).to eq("echo: ok")
      expect(mcp("echo", { "text" => "x" }, server: "gone"))
        .to eq("Error: MCP server gone didn't start: can't start /nonexistent/mcp-server: No such file or directory")
      expect(find("")).to include("gone (failed: can't start /nonexistent/mcp-server: No such file or directory)\n",
                                  "hung (failed: initialize timed out after 2s)")
    end
  end

  context "with a server's tools: filter" do
    let(:servers) { { "fake" => fake.merge("tools" => ["echo", "a*"]) } }

    it "indexes only those" do
      expect(find("")).to end_with("\nfake: echo, add")
      expect(mcp("fail")).to start_with("Error: no MCP tool fake/fail.")
    end
  end

  context "with two servers whose tools come out as the same mcp_<server>_<tool>" do
    let(:servers) { { "fake" => fake, "fake-" => fake.merge("tools" => ["echo"]) } }

    it "calls neither (rules and approvals couldn't tell them apart), says so once, and marks them in a search" do
      clash = "MCP tools fake/echo and fake-/echo can't be called: both are mcp_fake_echo to guardrail rules"
      expect(load_events.select { |e| e[:type] == :hook_notice }.map { |e| e[:text] }).to eq([clash])
      expect(mcp("echo", { "text" => "one" })).to eq("Error: fake/echo can't be called: name clash with fake-/echo (mcp_fake_echo)")
      expect(mcp("echo", { "text" => "two" }, server: "fake-"))
        .to eq("Error: fake-/echo can't be called: name clash with fake/echo (mcp_fake_echo)")
      expect(call_tool("mcp_call", { "tool" => "mcp_fake_echo", "args" => { "text" => "x" } }))
        .to eq("Error: mcp_fake_echo names fake/echo and fake-/echo; call one as <server>/<tool>")
      expect(find("echo")).to include("fake/echo (name clash with fake-/echo): ", "fake-/echo (name clash with fake/echo): ")
      expect(mcp("add", { "a" => 1, "b" => 2 })).to eq("3")
    end
  end

  context "with a property schema that isn't an object" do
    let(:tools_file) { File.join(tmpdir, "tools") }
    let(:fake) { { "command" => MCP_FAKE_COMMAND, "env" => { "FAKE_MCP_TOOLS" => tools_file } } }

    before { File.write(tools_file, "echo\nodd_prop\n") }

    it "marks that tool (bad schema) and keeps the server" do
      expect(engine.plugin_failures.any?).to be(false)
      expect(find("")).to end_with("\nfake: echo, odd_prop (bad schema)")
      expect(mcp("echo", { "text" => "ok" })).to eq("echo: ok")
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
    tokens = chat_tokens(%w[echo add fail mixed slow crash Weird-Name.v2 changed path blob])
    expect(tokens).to be > 100
    expect(cards.last[:body]).to start_with("**fake**: running (pid #{server_pid}), 10 tools, ~#{tokens} tokens\n- `fake/")
    listed = cards.last[:body].scan(%r{^- `(fake/\S+)`$}).flatten
    expect(listed.size).to eq(10)
    expect(listed).to eq(listed.sort) # not the server's tools/list order (echo first)
    expect(listed).to include("fake/Weird-Name.v2") # the name mcp_call takes
    expect(fixed_tokens).to be_between(50, 1000)
    expect(cards.last[:body]).to end_with("\n\n#{mcp_total(tokens)}")
  end

  context "with two servers, one that doesn't start" do
    let(:servers) { { "fake" => fake.merge("tools" => %w[echo add]), "gone" => { "command" => ["/nonexistent/mcp-server"] } } }

    it "/mcp totals only the tools mcp_call reaches, and the load log records each server's estimate" do
      log = []
      allow(Samagotchi::Log).to receive(:info).and_call_original
      allow(Samagotchi::Log).to receive(:info).with(:plugins, "mcp_tools_estimated", any_args) { |*, **fields| log << fields }
      commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                                 default_model: "Gemma-4B-it", registry: engine.command_registry)
      cards = []
      engine.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
      engine.running_anytime { commands.run("/mcp") }
      tokens = chat_tokens(%w[add echo])
      expect(cards.last[:body]).to include("**fake**: running (pid #{server_pid}), 2 tools, ~#{tokens} tokens\n",
                                           "**gone**: failed: can't start")
      expect(cards.last[:body]).to end_with(mcp_total(tokens))
      expect(log).to eq([{ bundle: "mcp", server: "fake", tools: 2, tokens: tokens }])
    end
  end

  it "stops the server process when the Engine shuts down" do
    pid = server_pid
    expect(alive?(pid)).to be(true)
    engine.shutdown
    expect(alive?(pid)).to be(false)
    expect(mcp("echo", { "text" => "x" })).to eq("Error: service mcp:fake is stopped")
  end
end
