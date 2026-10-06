# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/mcp_bundle"

# The mcp bundle's tools/list cache (start: lazy): a server's tools
# registered from the cache, without starting it.
RSpec.describe "The mcp bundle" do
  include_context "the mcp bundle in an Engine"

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
      expect(mcp_tools).to eq(%w[mcp_fake_add mcp_fake_echo mcp_fake_slow])
      expect(spawned).to eq(1)
      tokens = chat_tokens(mcp_tools)
      expect(mcp_card).to eq("**fake**: cached (not started), 3 tools, ~#{tokens} tokens\n- `mcp_fake_add`\n- `mcp_fake_echo`\n" \
                             "- `mcp_fake_slow`\n\nTotal: ~#{tokens} tokens of tool definitions in every request " \
                             "(estimated: their JSON as the chat API gets it, ÷ 4).")
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
      expect(mcp_tools).to eq(%w[mcp_fake_add mcp_fake_echo mcp_fake_slow])
      expect(call_tool("mcp_fake_echo", { "text" => "x" })).to eq("echo: x")
      expect(cache["tools"].map { |t| t["name"] }).to eq(%w[echo fail])
      expect(mcp_tools).to eq(%w[mcp_fake_add mcp_fake_echo mcp_fake_slow])
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
      expect(mcp_tools).to eq(%w[mcp_fake_changed mcp_fake_echo])
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
        expect(mcp_tools).to eq(%w[mcp_fake_add mcp_fake_echo mcp_fake_slow])
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
        expect(mcp_card).to start_with("**fake**: cached (not started), 1 tool, ~#{chat_tokens(%w[mcp_fake_echo])} tokens\n" \
                                       "- `mcp_fake_echo`\n\nTotal: ")
      end

      it "leaves the refresh to the worker that holds the lock" do
        File.open("#{cache_file}.lock", File::CREAT | File::RDWR) do |lock|
          lock.flock(File::LOCK_EX)
          next_engine
        end
        expect(spawned).to eq(1)
        expect(mcp_tools).to eq(%w[mcp_fake_add mcp_fake_echo mcp_fake_slow])
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
end
