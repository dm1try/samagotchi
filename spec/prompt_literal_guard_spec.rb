# frozen_string_literal: true

require "samagotchi/prompt_literal_guard"
require "samagotchi/model_profile"

RSpec.describe Samagotchi::PromptLiteralGuard do
  let(:gemma) { Samagotchi::ModelProfile.gemma4 }
  let(:qwen) { Samagotchi::ModelProfile.qwen36 }

  it "escapes Gemma's thought channel in a user or tool text and restores it" do
    text = "see <|channel>thought x<channel|> and <|tool_call>"
    escaped = described_class.escape(text, profile: gemma, role: "tool_response")

    expect(escaped).to eq("see [[SAMAGOTCHI_LITERAL_THOUGHT_CHANNEL_OPEN]] x[[SAMAGOTCHI_LITERAL_THOUGHT_CHANNEL_CLOSE]] " \
                          "and [[SAMAGOTCHI_LITERAL_TOOL_CALL_OPEN]]")
    expect(described_class.restore(escaped, profile: gemma)).to eq(text)
  end

  it "leaves the Gemma channel alone for Qwen and for a model's own text" do
    text = "<|channel>thought x<channel|> <think>"
    expect(described_class.escape(text, profile: qwen, role: "user")).to eq("<|channel>thought x<channel|> [[SAMAGOTCHI_LITERAL_THINK_OPEN]]")
    expect(described_class.escape(text, profile: gemma, role: "model")).to eq(text)
  end
end
