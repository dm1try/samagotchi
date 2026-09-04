# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "spec_helper"

RSpec.describe Samagotchi::TerminalUI do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:agent) { described_class.new(mode: :assist, client: client) }

  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  describe "analytics REPL commands" do
    it "treats both /stats and /analytics as the stats command" do
      expect(agent.send(:stats_command?, "/stats")).to be(true)
      expect(agent.send(:stats_command?, "/analytics")).to be(true)
      expect(agent.send(:stats_command?, "  /analytics  ")).to be(true)
      expect(agent.send(:stats_command?, "hello")).to be(false)
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
  end

  # Regression for the interactive /stats bug: the REPL drives KernelLoop
  # directly, bypassing Engine#run_turn, so it never emitted the :turn_started
  # event the collector needs. Without begin_interactive_turn, turns and output
  # tokens stayed 0 even though the server reported completion tokens.
  describe "interactive REPL turn lifecycle (KernelLoop bypass)" do
    let(:session) { double(id: "interactive-sess") }
    let(:metrics) { agent.instance_variable_get(:@engine).metrics }

    def feed_generation(metrics, prompt_n:, predicted_n:)
      metrics.call(type: :generation_started)
      metrics.call(
        type: :generation_chunk,
        payload: { "timings" => { "prompt_n" => prompt_n, "predicted_n" => predicted_n } }
      )
      metrics.call(type: :generation_completed)
    end

    it "opens a turn so turns and output tokens are counted" do
      agent.send(:begin_interactive_turn, session)
      feed_generation(metrics, prompt_n: 120, predicted_n: 10)
      agent.send(:end_interactive_turn, canceled: false)

      snap = metrics.snapshot
      expect(snap[:turns]).to eq(1)
      expect(snap[:tokens_in]).to eq(120)
      expect(snap[:tokens_out]).to eq(10)
      expect(snap[:tokens_total]).to eq(130)
      expect(snap[:cancellations]).to eq(0)
    end

    it "counts a turn_canceled when an interrupted turn is aborted or Ctrl-c'd" do
      agent.send(:begin_interactive_turn, session)
      agent.send(:end_interactive_turn, canceled: true)
      expect(metrics.snapshot[:cancellations]).to eq(1)
    end

    it "keeps an interrupted/continued turn as a single logical turn, then opens a new one" do
      # Turn 1 (a tool-call loop that the user interrupts, then resumes).
      agent.send(:begin_interactive_turn, session)
      feed_generation(metrics, prompt_n: 120, predicted_n: 10)
      # Continue path calls begin again; must be a no-op while the turn is open.
      agent.send(:begin_interactive_turn, session)
      feed_generation(metrics, prompt_n: 200, predicted_n: 25)
      agent.send(:end_interactive_turn, canceled: false)

      snap = metrics.snapshot
      expect(snap[:turns]).to eq(1)           # one logical turn, not two
      expect(snap[:tokens_out]).to eq(35)      # 10 + 25 summed across generations
      expect(snap[:tokens_in]).to eq(200)      # running max of the growing prompt

      # The flag reset on completion, so the next turn opens fresh.
      agent.send(:begin_interactive_turn, session)
      feed_generation(metrics, prompt_n: 300, predicted_n: 40)
      agent.send(:end_interactive_turn, canceled: false)
      expect(metrics.snapshot[:turns]).to eq(2)
    end
  end
end
