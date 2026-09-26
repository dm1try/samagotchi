# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "spec_helper"
require "stringio"
require "json"
require_relative "support/recording_surface"

RSpec.describe Samagotchi::TerminalUI do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:agent) { described_class.new(mode: :assist, client: client) }

  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  describe "stats REPL commands" do
    it "treats /stats as the stats command" do
      expect(agent.send(:stats_command?, "/stats")).to be(true)
      expect(agent.send(:stats_command?, "  /stats  ")).to be(true)
      expect(agent.send(:stats_command?, "hello")).to be(false)
      expect(agent.send(:stats_command?, "/analytics")).to be(false)
    end

    it "renders the session metrics summary via format_session_metrics" do
      metrics = agent.instance_variable_get(:@engine).metrics
      metrics.call(type: :turn_started, session_id: "s", prompt: "x")
      metrics.call(type: :generation_chunk, payload: { "timings" => { "prompt_n" => 10, "predicted_n" => 5 } })
      metrics.call(type: :generation_completed)
      metrics.call(type: :turn_completed, result: double(respond_to?: false))

      output = agent.send(:format_session_metrics, metrics.snapshot)
      expect(output).to include("turns:")
      expect(output).to include("tokens in/out:")
      expect(output).to include("10/5")
    end

    it "shows the context window and where it came from in /stats" do
      metrics = agent.instance_variable_get(:@engine).metrics
      metrics.call(type: :generation_started, context_window_tokens: 128_000, context_window_source: :server)

      expect(agent.send(:format_session_metrics, metrics.snapshot)).to include("context window:   128000 tokens (server)")
    end

    it "shows the served model in /stats, with the name asked for when they differ" do
      metrics = agent.instance_variable_get(:@engine).metrics
      output = ->(snapshot) { agent.send(:format_session_metrics, metrics.snapshot.merge(snapshot)) }

      expect(output.call(served_model: "ornith-1.5", served_model_for: "unsloth/Qwen3.6"))
        .to include("served model:     ornith-1.5 (asked for unsloth/Qwen3.6)")
      expect(output.call(served_model: "z-ai/glm-5.2", served_model_for: "z-ai/glm-5.2:free").lines.map(&:chomp))
        .to include("served model:     z-ai/glm-5.2")
      expect(output.call(served_model: nil, served_model_for: nil)).not_to include("served model")
    end

    it "shows the served model in the status line once a turn reported another one" do
      engine = agent.instance_variable_get(:@engine)
      expect(agent.send(:status_model_segment)).to start_with("model=#{engine.effective_model_name}")

      engine.metrics.call(type: :generation_completed, served_model: "ornith-x",
                          requested_model: engine.send(:bare_model_name, engine.effective_model_name))

      expect(agent.send(:status_model_segment)).to start_with("model=ornith-x (served; asked ")
    end

    it "shows the prompt profile and where it came from in /stats" do
      metrics = agent.instance_variable_get(:@engine).metrics
      metrics.call(type: :generation_started, profile: "qwen36", profile_source: "config (models: ista)")

      expect(agent.send(:format_session_metrics, metrics.snapshot)).to include("prompt profile:   qwen36 (config (models: ista))")
    end
  end

  describe "idle activity hook" do
    around do |example|
      saved = Reline.pre_input_hook
      example.run
    ensure
      Reline.pre_input_hook = saved
    end

    it "survives a prompt with no prefill (it used to be reset to nil)" do
      hook = proc {}
      Reline.pre_input_hook = hook
      agent.send(:with_next_input_prefill) { :read }
      expect(Reline.pre_input_hook).to be(hook)
    end

    it "counts each key typed as activity while the REPL runs" do
      engine = agent.instance_variable_get(:@engine)
      allow(engine).to receive(:record_activity)

      agent.send(:with_activity_hook) { Samagotchi::TerminalUI::RelineSeam.key_handler.call }

      expect(engine).to have_received(:record_activity).once
      expect(Samagotchi::TerminalUI::RelineSeam.key_handler).to be_nil
    end

    it "is restored after a prefilled prompt" do
      hook = proc {}
      Reline.pre_input_hook = hook
      agent.instance_variable_set(:@next_input_prefill, "Hey Chi, ")
      agent.send(:with_next_input_prefill) { expect(Reline.pre_input_hook).not_to be(hook) }
      expect(Reline.pre_input_hook).to be(hook)
    end
  end

  describe "cards and notices between turns" do
    let(:surface) { RecordingSurface.new }
    let(:agent) { described_class.new(mode: :assist, client: client, surface: surface) }
    let(:engine) { agent.instance_variable_get(:@engine) }
    def lines = surface.lines.flat_map { |line| line.split("\n") }

    it "prints a card announced between turns at the open prompt, on the main thread, once" do
      engine.show_card(source: "sample-plugin", title: "Hello", body: "hi there",
                       actions: [{ label: "Again", command: "/hello again" }])
      expect(lines).to be_empty
      agent.send(:flush_pending_cards)
      expect(lines).to eq(["┌ Hello · sample-plugin", "│ hi there", "│ → /hello again  Again", "└"])
      agent.send(:flush_pending_cards)
      expect(lines.grep(/Hello/).size).to eq(1)
    end

    it "prints a plugin's notice between turns under its bundle's name, and a card shown again marked (updated)" do
      engine.send(:hook_notify, "saved", :info, "plugin.rb (bundle sample-plugin)")
      engine.show_card(source: "b", title: "One", id: "c1")
      agent.send(:flush_pending_cards)
      engine.show_card(source: "b", title: "Two", id: "c1")
      agent.send(:flush_pending_cards)
      expect(lines).to eq(["sample-plugin> saved", "┌ One · b", "└", "┌ Two (updated) · b", "└"])
    end

    it "prints a plugin's init task as a line when it starts and one when it is done; a failure is its card" do
      gate = Queue.new
      engine.add_init_task(bundle: "mcp", label: "Starting MCP server x", plugin_label: "x", provides_tools: true,
                           quiet: false, timeout: 5) { gate.pop }
      engine.add_init_task(bundle: "mcp", label: "Starting MCP server y", plugin_label: "x", provides_tools: true,
                           quiet: false, timeout: 5) { raise "gone" }
      engine.start_init_tasks!
      Timeout.timeout(2) { sleep(0.01) until engine.instance_variable_get(:@init_tasks).last.state == :failed }
      gate << "x ready, 3 tools"
      engine.instance_variable_get(:@init_tasks).each { |task| task.thread.join(2) }
      expect(lines).to be_empty
      agent.send(:flush_pending_cards)
      expect(lines).to contain_exactly("mcp> Starting MCP server x…", "mcp> Starting MCP server y…",
                                       "┌ Starting MCP server y: failed · mcp", "│ gone", "└", "mcp> ✓ x ready, 3 tools")
      expect(lines.last).to eq("mcp> ✓ x ready, 3 tools")
    end

    it "prints the load warnings announced before the first turn at the open prompt" do
      # As if the plugin had failed while the Engine loaded (the REPL
      # announced them as it started).
      engine.instance_variable_set(:@guardrail_failures_announced, false)
      engine.instance_variable_get(:@plugin_failures).add("plugin plugin.rb (bundle b)", "boom", required: false)
      engine.announce_load_events!
      agent.send(:flush_pending_cards)
      expect(lines).to eq(["plugins> plugin plugin.rb (bundle b) failed to load (boom)"])
    end

    it "says what a turn waits for while plugins' init tasks bring tools, until the model starts" do
      agent.init_wait_feedback({ tasks: [{ bundle: "mcp", id: "mcp-1", label: "Starting x" }] })
      expect(agent.send(:spinner_row_lines, "|", width: 80)).to eq(["chi> waiting for mcp: Starting x... |"])
      agent.generation_feedback_started({})
      expect(agent.send(:spinner_row_lines, "|", width: 80).first).to include("model> thinking... |")
    end

    it "prints a card replaced within one flush once, as its last" do
      engine.show_card(source: "b", title: "thinking", id: "c1")
      engine.show_card(source: "b", title: "other", id: "c2")
      engine.show_card(source: "b", title: "answer", id: "c1")
      agent.send(:flush_pending_cards)
      expect(lines).to eq(["┌ other · b", "└", "┌ answer · b", "└"])
    end

    it "prints an anytime command's cards as it shows them at the prompt (main thread), each version" do
      engine.command_registry.register("/side", "side", anytime: true, source: "b") do |_args|
        engine.show_card(source: "b", title: "thinking…", id: "c1")
        seen_during = lines.dup
        engine.show_card(source: "b", title: "the answer", id: "c1")
        "done #{seen_during.size}"
      end
      agent.send(:run_input_line, nil, "/side")
      expect(lines).to eq(["┌ thinking… · b", "└", "┌ the answer (updated) · b", "└", "", "model> done 2"])
    end

    it "leaves a turn's card to the turn's sink" do
      agent.send(:handle_card_event, { type: :card, id: "c1", source: "b", title: "mid", in_turn: true })
      agent.send(:handle_card_event, { type: :hook_notice, hook: "h", text: "in a turn", level: :info })
      agent.send(:flush_pending_cards)
      expect(lines).to be_empty
    end
  end

  describe "/recap command" do
    let(:engine) { agent.instance_variable_get(:@engine) }
    let(:recap_job) { double("recap", min_user_turns: 2) }

    before do
      allow(engine).to receive(:recap).and_return(recap_job)
      allow(engine).to receive(:turn_running?).and_return(false)
    end

    it "shows the saved recap and asks for a new one when the chat moved on" do
      allow(engine).to receive(:saved_recap).and_return({ text: "Did X.", covered: 4, turns_since: 1 })
      allow(engine).to receive(:request_recap).and_return(:started)
      expect(agent.send(:handle_recap_command)).to eq("recap (before the last turn)> Did X.\nwriting a recap…")
    end

    it "says there is nothing new since a current one" do
      allow(engine).to receive(:saved_recap).and_return({ text: "Did X.", covered: 4, turns_since: 0 })
      allow(engine).to receive(:request_recap).and_return(:nothing_new)
      expect(agent.send(:handle_recap_command)).to eq("recap> Did X.\n(nothing new since this recap)")
    end

    it "asks for none during a turn" do
      allow(engine).to receive(:turn_running?).and_return(true)
      allow(engine).to receive(:saved_recap).and_return(nil)
      allow(engine).to receive(:request_recap)
      expect(agent.send(:handle_recap_command)).to eq("no recap yet: a turn is running; one is written once the session is idle")
      expect(engine).not_to have_received(:request_recap)
    end

    it "says recap is off and where that is set when it is disabled" do
      allow(engine).to receive(:recap).and_return(nil)
      expect(agent.send(:handle_recap_command)).to include("recap: false in config.yml").and include("SAMAGOTCHI_RECAP_ENABLED")
    end

    describe "on the screen" do
      let(:surface) { RecordingSurface.new }
      let(:agent) { described_class.new(mode: :assist, client: client, surface: surface) }

      it "prints a recap written while idle at the open prompt, on the main thread" do
        agent.send(:handle_recap_ready, { type: :recap_ready, recap: "Did Y.", generation: 3, covered: 6 })
        expect(surface.lines.grep(/Did Y/)).to be_empty
        agent.send(:flush_pending_recap)
        expect(surface.lines.last).to eq("recap> Did Y.")
        agent.send(:flush_pending_recap)
        expect(surface.lines.grep(/Did Y/).size).to eq(1)
      end

      it "drops one that lands during a turn" do
        allow(engine).to receive(:turn_running?).and_return(true)
        agent.send(:handle_recap_ready, { type: :recap_ready, recap: "Did Y.", generation: 3, covered: 6 })
        allow(engine).to receive(:turn_running?).and_return(false)
        agent.send(:flush_pending_recap)
        expect(surface.lines.grep(/Did Y/)).to be_empty
      end

      it "shows the saved recap under the resumed session's line" do
        session = instance_double(Samagotchi::Session, id: "s-9", messages: [{ role: "user", content: "hi" }])
        agent.instance_variable_set(:@resume_session, session)
        allow(engine).to receive(:saved_recap).and_return({ text: "Did X.", covered: 1, turns_since: 0 })
        agent.send(:messages_for, session)
        expect(surface.lines).to eq(["Resumed session: s-9", "recap> Did X."])
      end
    end
  end

  describe "timing output" do
    it "adds compact elapsed time to a completed tool activity line" do
      output = agent.send(
        :format_tool_activity_line,
        { action: "reading file", tool: "read", params: "path=README.md", status: "ok" },
        duration_ms: 125
      )

      expect(output).to include("tool>")
      expect(output).to include("ok")
      expect(output).to include("(125ms)")
    end

    it "prints the completed interactive turn elapsed time" do
      session = double(id: "timed-turn")
      original_stdout = $stdout
      output = StringIO.new
      $stdout = output

      metrics = agent.instance_variable_get(:@engine).metrics
      metrics.call(type: :turn_started, session_id: session.id, prompt: nil)
      metrics.call(type: :turn_completed, result: nil)
      agent.send(:emit_interactive_turn_duration, canceled: false)

      expect(output.string).to match(/chi> turn completed \(\d+ms\)/)
    ensure
      $stdout = original_stdout
    end

    # Shared contract: spec/shared/timing_matrix.json. One source of truth for
    # the web (JS) and TUI (Ruby) suites — edit it to change either side's output.
    let(:timing_matrix) do
      path = File.expand_path("shared/timing_matrix.json", __dir__)
      JSON.parse(File.read(path))["cases"]
    end

    it "formats durations per the shared timing matrix" do
      timing_matrix.each do |case_entry|
        ms = case_entry["ms"]
        expected = case_entry["expected"]
        expect(agent.send(:format_elapsed_duration, ms)).to eq(expected),
          "timing for #{ms}ms expected #{expected.inspect}"
      end
    end
  end
end
