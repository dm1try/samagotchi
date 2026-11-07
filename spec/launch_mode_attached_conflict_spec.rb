# frozen_string_literal: true

require "samagotchi/launch_mode"

# LaunchMode.attached_conflict: bin/chi's refusals for an attached run whose
# flags don't go together (exit 1, "Error: " before the words).
RSpec.describe Samagotchi::LaunchMode, ".attached_conflict" do
  def conflict(**options) = described_class.attached_conflict(options)

  it "says nothing when the flags go together" do
    expect(conflict(attach: "s1")).to be_nil
    expect(conflict(resume: "s1", prompt: "hi")).to be_nil
    expect(conflict(verbose: false, non_interactive: false)).to be_nil
  end

  it "refuses --attach with --resume" do
    expect(conflict(attach: "s1", resume: "s2")).to eq("use either --attach ID or --resume ID")
  end

  it "names the in-process flag an attached run can't take, --non-interactive first" do
    expect(conflict(attach: "s1", non_interactive: true)).to eq("--attach can't be combined with --non-interactive")
    expect(conflict(attach: "s1", verbose: true, non_interactive: true)).to end_with("--non-interactive")
  end

  it "words a Bridge that didn't come" do
    expect(format(described_class::BRIDGE_LATE, "s1")).to eq("the worker for session s1 did not start its Bridge in time (chi home doctor shows a worker that failed to boot)")
  end
end
