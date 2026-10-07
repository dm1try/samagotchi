# frozen_string_literal: true

require "samagotchi/tool_response"

RSpec.describe Samagotchi::ToolResponse do
  # Stands in for ToolRunner: answers each call with its scripted run.
  let(:runner) do
    runs = self.runs
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:run) do |call, **options|
        @calls << [call, options]
        runs.fetch(call[:name])
      end
    end.new
  end
  let(:shot) { { file: "a.png", name: "a.png" } }
  let(:runs) do
    {
      "shots" => { output: "[shots]\none shot", capped_output: "[shots]\none", activity: { tool: "shots" },
                   images: [shot], shown_params: "all", shown_label: "chrome: shots" },
      "write" => { output: "[write]\nwrote", capped_output: "[write]\nwrote", activity: { tool: "write" },
                   diff: { path: "x" } },
      "broken" => { output: "[broken] Error: RuntimeError: x", capped_output: "[broken] Error", activity: nil }
    }
  end
  let(:events) { [] }

  def batch(names, &block)
    calls = names.map { |name| { name: name } }
    described_class.run_batch(runner, calls, iteration: 2, emit: ->(event) { events << event },
                                             on_stream_event: :sink, cap: 50, &block)
  end

  describe ".run_batch" do
    it "runs each call between the dispatch events and yields each run with its index" do
      yielded = []

      runs = batch(%w[shots write]) { |run, index| yielded << [run[:output], index] }

      expect(events).to eq([{ type: :tool_dispatch_started, iteration: 2, call_count: 2 },
                            { type: :tool_dispatch_completed, iteration: 2, call_count: 2 }])
      expect(runner.calls.map(&:last)).to eq([
        { iteration: 2, call_index: 1, call_count: 2, on_stream_event: :sink, max_tool_output_chars: 50 },
        { iteration: 2, call_index: 2, call_count: 2, on_stream_event: :sink, max_tool_output_chars: 50 }
      ])
      expect(yielded).to eq([["[shots]\none shot", 0], ["[write]\nwrote", 1]])
      expect(runs.size).to eq(2)
    end
  end

  describe ".activities" do
    it "leaves out a call with no activity (a dispatcher that raised)" do
      expect(described_class.activities(batch(%w[shots broken write]))).to eq([{ tool: "shots" }, { tool: "write" }])
    end
  end

  describe ".joined" do
    it "is one entry: the capped outputs joined, every image in call order, per-call fields in call order" do
      expect(described_class.joined(batch(%w[shots write broken]))).to eq(
        role: "tool_response",
        content: "[shots]\none\n\n---\n\n[write]\nwrote\n\n---\n\n[broken] Error",
        images: [shot], image_counts: [1, 0, 0],
        tool_params: ["all", nil, nil], tool_labels: ["chrome: shots", nil, nil], tool_diffs: [nil, { path: "x" }, nil]
      )
    end

    it "leaves out what no call has" do
      expect(described_class.joined(batch(%w[broken]))).to eq(role: "tool_response", content: "[broken] Error")
    end
  end

  describe ".single" do
    it "is one call's entry with its id: the capped output and its own fields" do
      shots, write = batch(%w[shots write])

      expect(described_class.single(shots, tool_call_id: "c1")).to eq(
        role: "tool_response", content: "[shots]\none", tool_call_id: "c1", images: [shot],
        tool_params: "all", tool_labels: "chrome: shots"
      )
      expect(described_class.single(write, tool_call_id: "c2")).to eq(
        role: "tool_response", content: "[write]\nwrote", tool_call_id: "c2", tool_diffs: { path: "x" }
      )
    end
  end

  it "names the saved-only keys (never sent to the model)" do
    expect(described_class::SAVED_KEYS).to eq(%i[tool_params tool_labels tool_diffs])
  end
end
