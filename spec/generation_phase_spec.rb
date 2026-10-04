# frozen_string_literal: true

require "samagotchi/generation_phase"

RSpec.describe Samagotchi::GenerationPhase do
  let(:now) { [100.0] }
  let(:phase) { described_class.new(clock: -> { now.first }) }

  def at(seconds)
    now[0] = 100.0 + seconds
  end

  def thinking_for(seconds)
    phase.started!
    phase.chunk!(thinking: "hmm", text: "")
    at(seconds)
    phase.chunk!(thinking: "still", text: "")
  end

  it "is cuttable after min_age of thinking only" do
    thinking_for(25)
    expect(phase.cuttable?(20)).to be(true)
    expect(phase.age).to eq(25.0)
  end

  it "counts min_age from the first thinking delta, not the generation start (the wait for a first token)" do
    phase.started!
    at(15)
    phase.chunk!(thinking: "hmm", text: "")
    at(25)
    phase.chunk!(thinking: "more", text: "")
    expect(phase.cuttable?(20)).to be(false)
    expect(phase.age).to eq(10.0)
    at(35.5)
    phase.chunk!(thinking: "more", text: "")
    expect(phase.cuttable?(20)).to be(true)
  end

  it "starts the thinking clock again on a retry" do
    thinking_for(25)
    phase.retrying!
    phase.chunk!(thinking: "again", text: "")
    expect(phase.cuttable?(20)).to be(false)
  end

  it "is not cuttable while younger than min_age" do
    thinking_for(5)
    expect(phase.cuttable?(20)).to be(false)
  end

  it "is not cuttable once thinking stopped streaming (no fresh delta)" do
    thinking_for(25)
    at(25 + described_class::FRESH_SECONDS + 0.1)
    expect(phase.cuttable?(20)).to be(false)
  end

  it "is not cuttable after visible text" do
    thinking_for(25)
    phase.chunk!(thinking: "", text: "The answer")
    expect(phase.cuttable?(20)).to be(false)
  end

  it "ignores blank text (a newline before Gemma's thought channel)" do
    phase.started!
    phase.chunk!(thinking: "", text: "\n")
    phase.chunk!(thinking: "hmm", text: "")
    at(25)
    phase.chunk!(thinking: "more", text: "")
    expect(phase.cuttable?(20)).to be(true)
  end

  it "is not cuttable after a tool-call chunk" do
    thinking_for(25)
    phase.chunk!(thinking: "", text: "", tool_call: true)
    expect(phase.cuttable?(20)).to be(false)
  end

  it "is not cuttable with no thinking seen" do
    phase.started!
    at(25)
    expect(phase.cuttable?(20)).to be(false)
  end

  it "forgets what it saw on a retry" do
    thinking_for(25)
    phase.chunk!(thinking: "", text: "text")
    phase.retrying!
    expect(phase.cuttable?(20)).to be(false)
    phase.chunk!(thinking: "again", text: "")
    at(50)
    phase.chunk!(thinking: "again", text: "")
    expect(phase.cuttable?(20)).to be(true)
  end

  it "is not cuttable once finished, nor before any generation" do
    expect(phase.cuttable?(0)).to be(false)
    expect(phase.age).to be_nil
    phase.started!
    expect(phase.age).to be_nil
    thinking_for(25)
    phase.finished!
    expect(phase.cuttable?(20)).to be(false)
  end

  it "starts each generation afresh" do
    thinking_for(25)
    phase.chunk!(thinking: "", text: "answer")
    phase.started!
    phase.chunk!(thinking: "new", text: "")
    expect(phase.cuttable?(20)).to be(false)
    at(50)
    phase.chunk!(thinking: "new", text: "")
    expect(phase.cuttable?(20)).to be(true)
  end
end
