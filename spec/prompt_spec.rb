# frozen_string_literal: true

require "samagotchi/prompt"

RSpec.describe Samagotchi::Prompt do
  describe ".format" do
    it "formats a system turn" do
      result = described_class.format([{ role: "system", content: "Be helpful" }])
      expect(result).to include("<|turn>system\nBe helpful<end_of_turn>")
    end

    it "formats a user turn" do
      result = described_class.format([{ role: "user", content: "Hello" }])
      expect(result).to include("<|turn>user\nHello<end_of_turn>")
    end

    it "formats a model turn" do
      result = described_class.format([{ role: "model", content: "Hi there" }])
      expect(result).to include("<|turn>model\nHi there<end_of_turn>")
    end

    it "formats a tool_response turn using <|tool_response> tokens (not a regular turn)" do
      result = described_class.format([{ role: "tool_response", content: "[execute]\nstdout:\nhi" }])
      expect(result).to include("<|tool_response>\n[execute]\nstdout:\nhi<tool_response|>")
      expect(result).not_to include("<|turn>tool_response")
    end

    it "places tool_response block between the preceding model turn and the generation cue" do
      msgs = [
        { role: "model",         content: "<|tool_call>call:execute{command: \"echo hi\"}<tool_call|>" },
        { role: "tool_response", content: "[execute]\nstdout:\nhi" }
      ]
      result = described_class.format(msgs)
      model_pos         = result.index("<|turn>model\n<|tool_call>")
      tool_response_pos = result.index("<|tool_response>")
      cue_pos           = result.rindex("<|turn>model\n")
      expect(model_pos).to be < tool_response_pos
      expect(tool_response_pos).to be < cue_pos
    end

    it "always ends with the model turn starter to cue generation" do
      result = described_class.format([{ role: "user", content: "go" }])
      expect(result).to end_with("<|turn>model\n")
    end

    it "formats a full multi-turn conversation in order" do
      msgs = [
        { role: "system", content: "sys" },
        { role: "user",   content: "hello" },
        { role: "model",  content: "hi" },
        { role: "user",   content: "bye" }
      ]
      result = described_class.format(msgs)
      expect(result).to include("<|turn>system\nsys<end_of_turn>")
      expect(result).to include("<|turn>user\nhello<end_of_turn>")
      expect(result).to include("<|turn>model\nhi<end_of_turn>")
      expect(result).to include("<|turn>user\nbye<end_of_turn>")
      expect(result).to end_with("<|turn>model\n")
    end

    it "preserves turn order" do
      msgs = [
        { role: "user",  content: "first" },
        { role: "model", content: "second" }
      ]
      result = described_class.format(msgs)
      expect(result.index("<|turn>user")).to be < result.index("<|turn>model\nsecond")
    end

    it "produces an empty turn list followed by the model cue when given no messages" do
      result = described_class.format([])
      expect(result).to eq("<|turn>model\n")
    end
  end
end
