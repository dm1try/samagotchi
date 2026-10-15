# frozen_string_literal: true

require "samagotchi/tool_output_cut"

RSpec.describe Samagotchi::ToolOutputCut do
  describe ".head" do
    it "keeps the head and ends with the cut line, the whole within the cap" do
      text = described_class.head("x" * 300, 100)
      expect(text).to end_with("[cut: #{text.index("\n[cut")} of 300 chars; read it in parts]")
      expect(text.length).to be <= 100
    end
  end

  describe "HEAD_CUT" do
    # LLMContextStale marks a partial read by it.
    it "matches the line head_line writes" do
      expect("abc#{described_class.head_line(3, 99)}").to match(described_class::HEAD_CUT)
    end
  end

  it "cuts an unknown tool's output by the head" do
    expect(described_class.policy("some_plugin_tool")).to eq(:head)
    expect(described_class.apply("y" * 200, cap: 80, tool: "some_plugin_tool")).to eq(described_class.head("y" * 200, 80))
  end
end
