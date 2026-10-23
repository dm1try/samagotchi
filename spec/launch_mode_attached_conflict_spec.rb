# frozen_string_literal: true

require "samagotchi/launch_mode"

# LaunchMode.attached_conflict: bin/chi's refusals for an attached run whose
# flags don't go together (exit 1, "Error: " before the words).
RSpec.describe Samagotchi::LaunchMode, ".attached_conflict" do
  def conflict(**options) = described_class.attached_conflict(options)

  it "says nothing when the flags go together" do
    expect(conflict(attach: "s1")).to be_nil
    expect(conflict(shared: true, resume: "s1", prompt: "hi")).to be_nil
    expect(conflict(shared: true, verbose: false, non_interactive: false)).to be_nil
  end

  it "refuses --attach with --shared, and with --resume" do
    expect(conflict(attach: "s1", shared: true)).to eq("use either --attach ID or --shared")
    expect(conflict(attach: "s1", resume: "s2")).to eq("--attach takes the session id; --resume goes with --shared")
  end

  it "names the in-process flag an attached run can't take, --non-interactive first" do
    expect(conflict(shared: true, non_interactive: true)).to eq("--attach/--shared can't be combined with --non-interactive")
    expect(conflict(attach: "s1", verbose: true)).to eq("--attach/--shared can't be combined with --verbose")
    expect(conflict(shared: true, verbose: true, non_interactive: true)).to end_with("--non-interactive")
  end

  it "checks --attach with --shared before the others" do
    expect(conflict(attach: "s1", shared: true, resume: "s2", verbose: true)).to eq("use either --attach ID or --shared")
  end

  it "words the scratch leftover and a Bridge that didn't come" do
    expect(described_class::SCRATCH_LEFTOVER)
      .to eq("that's a leftover scratch session; it is deleted at the next sweep (chi sessions clean)")
    expect(format(described_class::BRIDGE_LATE, "s1")).to eq("the worker for session s1 did not start its Bridge in time")
  end
end
