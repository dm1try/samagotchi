# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "spec_helper"

RSpec.describe Samagotchi::TerminalUI do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:agent) { described_class.new(mode: :assist, client: client) }

  around do |example|
    original_model = ENV["SAMAGOTCHI_MODEL"]
    ENV["SAMAGOTCHI_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_MODEL"] = original_model
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
end
