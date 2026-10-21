# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/turn_settings"

RSpec.describe Samagotchi::LLM::TurnSettings do
  it "loads no tools unless the Engine says the turn's host does" do
    settings = described_class.new(vision: nil, sampling: {}, thinking: :high, reasoning_history: :all, model_name: "m",
                                   window_setting: nil, llm_context: nil, price: nil)

    expect(settings.loads_tools).to be(false)
    expect(described_class.none.loads_tools).to be(false)
    expect(settings.with(loads_tools: true).loads_tools).to be(true)
  end
end
