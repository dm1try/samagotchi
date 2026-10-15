# frozen_string_literal: true

require "samagotchi/session_model_settings"
require "samagotchi/session"
require_relative "support/fake_provider_server"
require_relative "support/effective_model_configs"

# SessionModelSettings on its own: the choice and the session are read at
# use, the session's own values come first, and a model that doesn't
# resolve gives each reader its fallback.
RSpec.describe Samagotchi::SessionModelSettings do
  include_context "effective model configs"

  let(:holder) { { choice: Samagotchi::ModelChoice.new(name: "box:qwen-small", typed: "box:qwen-small"), session: nil } }
  let(:settings) { described_class.new(registry: registry, choice: -> { holder[:choice] }, session: -> { holder[:session] }) }

  def new_session = Samagotchi::Session.new_session(mode: "assist", model_name: "box:qwen-small", working_directory: project)

  it "reads the model's values without a session, and refuses to set an own value" do
    expect([settings.thinking_override, settings.thinking_summary, settings.turn_thinking, settings.llm_context_session_args])
      .to eq([nil, "low (models: qwen-small)", :low, {}])
    expect { settings.thinking_override = :low }.to raise_error(ArgumentError, "no session yet")
    expect { settings.reasoning_history_override = :all }.to raise_error(ArgumentError, "no session yet")
  end

  it "reads the session at use: its own level first, set on it" do
    holder[:session] = new_session
    settings.thinking_override = :medium

    expect([holder[:session].thinking, settings.thinking_summary, settings.turn_thinking]).to eq([:medium, "medium (session)", :medium])

    holder[:session] = new_session
    expect(settings.thinking_summary).to eq("low (models: qwen-small)")
  end

  it "reads the choice at use" do
    expect(settings.chat_model?).to be(false)

    holder[:choice] = Samagotchi::ModelChoice.new(name: "oai:gpt-x", typed: "oai:gpt-x")
    expect([settings.chat_model?, settings.sampling_summary, settings.served_expected_by("gpt-x-0613")])
      .to eq([true, "temperature=0.3 (models: gpt-x)", "oai"])
  end

  it "gives each reader its fallback when the model doesn't resolve, and raises from effective_model" do
    allow(registry).to receive(:resolve).and_raise(RuntimeError, "registry broken")

    expect([settings.turn_sampling, settings.turn_thinking, settings.steer_cut_after, settings.thinking_summary,
            settings.turn_llm_context, settings.turn_price, settings.served_expected?("x")])
      .to eq([{}, :default, Samagotchi::SteerCut.cut_after, nil, nil, nil, false])
    expect { settings.effective_model }.to raise_error(RuntimeError, "registry broken")
  end
end
