# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "spec_helper"
require "stringio"
require "json"

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

  describe "/recap command" do
    let(:recap_job) { double("recap", generation: 3, min_user_turns: 2, inactivity: 180.0) }

    before { allow(agent.instance_variable_get(:@engine)).to receive(:recap).and_return(recap_job) }

    it "shows the latest recap as-is while the conversation hasn't moved on" do
      agent.send(:handle_recap_ready, { type: :recap_ready, recap: "Did X.", generation: 3 })
      expect(agent.send(:handle_recap_command)).to eq("session recap:\nDid X.")
    end

    it "labels the recap stale once a later turn bumped the generation" do
      agent.send(:handle_recap_ready, { type: :recap_ready, recap: "Did X.", generation: 3 })
      allow(recap_job).to receive(:generation).and_return(4)
      expect(agent.send(:handle_recap_command)).to eq("session recap (from before your latest turn):\nDid X.")
    end

    it "points at both config.yml and the env vars when recap is disabled" do
      allow(agent.instance_variable_get(:@engine)).to receive(:recap).and_return(nil)
      expect(agent.send(:handle_recap_command)).to include("config.yml").and include("SAMAGOTCHI_RECAP_BASE_URL")
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
