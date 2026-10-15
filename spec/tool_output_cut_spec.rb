# frozen_string_literal: true

require "samagotchi/tool_output_cut"
require "samagotchi/tool_output_files"

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
    expect(described_class.apply("y" * 200, cap: 80, tool: "some_plugin_tool")).to eq([described_class.head("y" * 200, 80), nil])
  end

  describe "an execute result" do
    let(:saved) { Samagotchi::ToolOutputFiles::Saved.new(path: "/state/s/tool_output/execute-abc.txt", bytes: 1, lines: 1) }

    def lines(prefix, count) = (1..count).map { |i| "#{prefix} #{i}" }.join("\n")

    it "gives a short stderr all it needs and stdout the rest" do
      output = "[execute]\nstdout:\n#{lines("out", 2000)}\nstderr:\n#{lines("err", 3)}\nexit: 0"
      text, = described_class.apply(output, cap: 4000, tool: "execute", save: ->(_) { saved })

      expect(text).to end_with("out 2000\nstderr:\nerr 1\nerr 2\nerr 3\nexit: 0")
      expect(text.scan(/^\[cut: /).size).to eq(1)
      expect(text.length).to be <= 4000
    end

    it "cuts a text with no stdout/stderr blocks (a hand-over) as one" do
      output = "[execute]\nStill running at the 120s limit\n#{lines("x", 2000)}"
      text, = described_class.apply(output, cap: 3000, tool: "execute", save: ->(_) { saved })

      expect(text).to start_with("[execute]\nStill running")
      expect(text).to end_with("x 2000")
      expect(text).to include("the output it printed is saved in /state/s/tool_output/execute-abc.txt")
    end

    it "counts the lines left out in the whole output, the first line 1" do
      output = "[execute]\nstdout:\n#{lines("l", 1000)}\nexit: 0"
      text, = described_class.apply(output, cap: 2000, tool: "execute", save: ->(_) { saved })
      first, last = text.match(/lines (\d+)-(\d+) of the saved file/).captures.map(&:to_i)
      shown = text.lines

      expect(shown[shown.index { |l| l.start_with?("[cut") } - 1]).to eq(output.lines[first - 2])
      expect(shown[shown.index { |l| l.start_with?("[cut") } + 1]).to eq(output.lines[last])
    end
  end
end
