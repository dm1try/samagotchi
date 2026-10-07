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
      expect(described_class.joined(batch(%w[shots write broken]), ids: %w[t4 t5 t6])).to eq(
        role: "tool_response",
        content: "[shots]\none\n\n---\n\n[write]\nwrote\n\n---\n\n[broken] Error",
        images: [shot], image_counts: [1, 0, 0],
        tool_params: ["all", nil, nil], tool_labels: ["chrome: shots", nil, nil], tool_diffs: [nil, { path: "x" }, nil],
        tool_ids: %w[t4 t5 t6]
      )
    end

    it "leaves out what no call has" do
      expect(described_class.joined(batch(%w[broken]), ids: %w[t1])).to eq(role: "tool_response", content: "[broken] Error",
                                                                           tool_ids: %w[t1])
    end
  end

  describe ".single" do
    it "is one call's entry with its id: the capped output and its own fields" do
      shots, write = batch(%w[shots write])

      expect(described_class.single(shots, tool_call_id: "c1", ids: %w[t1])).to eq(
        role: "tool_response", content: "[shots]\none", tool_call_id: "c1", images: [shot],
        tool_params: "all", tool_labels: "chrome: shots", tool_ids: %w[t1]
      )
      expect(described_class.single(write, tool_call_id: "c2", ids: %w[t2])).to eq(
        role: "tool_response", content: "[write]\nwrote", tool_call_id: "c2", tool_diffs: { path: "x" }, tool_ids: %w[t2]
      )
    end
  end

  it "names the saved-only keys (never sent to the model)" do
    expect(described_class::SAVED_KEYS).to eq(%i[tool_params tool_labels tool_diffs tool_ids edits])
  end

  describe ".split" do
    it "splits a joined entry into its runs: a part without a lead goes on the run before it" do
      runs = described_class.split("[read] a\n\n---\n\n[execute]\nb\n\n---\n\nmore\n\n---\n\n[write]")

      expect(runs.map(&:name)).to eq(%w[read execute write])
      expect(runs.map(&:lead)).to eq(["[read] ", "[execute]\n", "[write]"])
      expect(runs.map(&:body)).to eq(["a", "b\n\n---\n\nmore", ""])
    end

    it "gives a first part without a lead no name, and joins back to the content with limit -1" do
      content = "plain\n\n---\n\n[read] a\n\n---\n\n"
      runs = described_class.split(content, -1)

      expect(runs.map(&:name)).to eq([nil, "read"])
      expect(runs.map(&:text).join(described_class::SEPARATOR)).to eq(content)
    end
  end

  describe ".runs" do
    it "takes one run as the whole content, a separator inside it included" do
      runs = described_class.runs("[read] a\n\n---\n\n[x] b", 1)

      expect(runs.map(&:name)).to eq(%w[read])
      expect(runs.first.body).to eq("a\n\n---\n\n[x] b")
      expect(described_class.runs("plain", 1).map(&:text)).to eq(["plain"])
    end
  end

  describe ".runs_named" do
    it "gives the runs when each part opens with its call's lead" do
      runs = described_class.runs_named("[read] a\n\n---\n\n[edit] b", %w[read edit])

      expect(runs.map(&:body)).to eq(%w[a b])
      expect(described_class.runs_named("[read] a\n\n---\n\n[x] b", %w[read])&.map(&:name)).to eq(%w[read])
    end

    it "refuses a split whose count matches but whose names don't: a ran-as line and a separator in an output" do
      content = "[read] a\n\n---\n\nran as: read path=b\n[read]\nb\n\n---\n\n[x] inside b"

      expect(described_class.split(content).size).to eq(2)
      expect(described_class.runs_named(content, %w[read read])).to be_nil
      expect(described_class.runs_named("[read] a", %w[edit])).to be_nil
      expect(described_class.runs_named("[read] a", %w[read read])).to be_nil
    end
  end
end
