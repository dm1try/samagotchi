# frozen_string_literal: true

require "samagotchi/model_settings"

# One config.yml models: entry as a value object (ConfigFile.model_settings
# holds them), and ConfigFile.model_setting's lookup over them.
RSpec.describe Samagotchi::ModelSettings do
  before { Samagotchi::ConfigFile.reset_warnings! }

  describe ".parse" do
    it "reads string or symbol keys, downcases the profile and leaves unset fields nil" do
      settings = described_class.parse("m", { "profile" => " Qwen36 ", vision: false, "thinking" => "off",
                                              window_tokens: 32_768, "sampling" => { "temperature" => 0.6 },
                                              "llm_context_strategy" => "stale", llm_context_budget_tokens: "64k" })
      expect(settings).to have_attributes(profile: "qwen36", vision: false, thinking: :off, window_tokens: 32_768,
                                          sampling: { temperature: 0.6 }, llm_context_strategy: [:stale],
                                          llm_context_apply: nil, llm_context_budget_tokens: 64_000)
    end

    it "is all nil for an empty map, and nil for one that is not a map or has no key" do
      expect(described_class.parse("m", {})).to eq(described_class.new)
      expect(described_class.parse("m", "qwen36")).to be_nil
      expect(described_class.parse("", { "profile" => "qwen36" })).to be_nil
    end

    it "warns about a bad value, naming the entry, and leaves it unset" do
      settings = nil
      expect { settings = described_class.parse("odd", { "window_tokens" => -1, "profile" => "gemma4" }) }
        .to output(/models: odd.*window_tokens/).to_stderr
      expect(settings).to have_attributes(window_tokens: nil, profile: "gemma4")
    end
  end
end
