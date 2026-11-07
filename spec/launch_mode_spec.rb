# frozen_string_literal: true

require "samagotchi/launch_mode"

RSpec.describe Samagotchi::LaunchMode do
  def resolve(**options) = described_class.resolve(options)

  it "attaches plain chi, -p, --resume ID and --attach ID" do
    expect(resolve).to eq(:attached)
    expect(resolve(prompt: "hi")).to eq(:attached)
    expect(resolve(resume: "s1")).to eq(:attached)
    expect(resolve(attach: "s1")).to eq(:attached)
  end

  it "attaches with --model, --no-interrupt, --memory and --mute, which reach the worker" do
    expect(resolve(model: "m", no_interrupt: true, memories: ["a"], muted: ["b"])).to eq(:attached)
  end

  it "attaches -v, which shows the session's debug records there" do
    expect(resolve(verbose: true)).to eq(:attached)
    expect(resolve(verbose: true, attach: "s1")).to eq(:attached)
  end

  it "runs --non-interactive's one turn in this process, --resume ID too" do
    expect(resolve(prompt: "hi", non_interactive: true)).to eq(:one_shot)
    expect(resolve(prompt: "hi", resume: "s1", non_interactive: true)).to eq(:one_shot)
  end

  it "leaves --attach with --non-interactive to attached_conflict" do
    expect(resolve(attach: "s1", non_interactive: true)).to eq(:attached)
  end
end
