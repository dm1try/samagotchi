# frozen_string_literal: true

require "samagotchi/system_prompt"
require "samagotchi/model_profile"
require "samagotchi/tools/registry"

# SystemPrompt#reset! runs off the turn thread (a plugin's tools_changed! /
# prompt_changed!, a /stats on a Bridge thread re-resolving the profile) and,
# through the profile lookup, inside a build on the turn thread itself. A
# reset that lands while #build runs must not fail that build, nor change its
# bytes: it only keeps the result from being cached, so the next build reads
# the sources again.
RSpec.describe Samagotchi::SystemPrompt, "#reset! during #build" do
  let(:model) { Samagotchi::SystemPrompt::ModelIdentity.new(ref: "box:m", host: "box", key: "m") }
  let(:section_calls) { [] }
  # Called while the prompt is built (Plugin::PromptSections): the seam the
  # specs pause a build at.
  let(:sections) { -> { section_calls << :called and @in_build&.call and [] } }

  def builder
    @builder ||= described_class.new(profile: -> { Samagotchi::ModelProfile.qwen36 },
                                     tools: -> { Samagotchi::Tools::Registry.new },
                                     session: -> {}, thinking: -> {}, model: -> { model }, sections: sections)
  end

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("(index)") }

  # The bytes a build with no reset gives, on a fresh builder.
  def clean_build(**args)
    described_class.new(profile: -> { Samagotchi::ModelProfile.qwen36 }, tools: -> { Samagotchi::Tools::Registry.new },
                        session: -> {}, thinking: -> {}, model: -> { model }, sections: -> { [] }).build(**args)
  end

  it "survives a reset from another thread between its steps, with the same bytes, and builds again next time" do
    reached = Queue.new
    proceed = Queue.new
    @in_build = lambda do
      @in_build = nil
      reached << true
      proceed.pop
    end
    turn = Thread.new { builder.build(chat: true) }
    reached.pop
    builder.reset!
    proceed << true
    prompt = turn.value

    expect(prompt).to eq(clean_build(chat: true))
    expect(builder.stable_length(prompt)).to eq(prompt.index("Model: this session runs on"))
    expect(builder.prompt_sections).to eq([])

    expect(builder.build(chat: true)).to eq(prompt)
    expect(section_calls.size).to eq(2)
    builder.build(chat: true)
    expect(section_calls.size).to eq(2)
  end

  it "survives a reset on its own thread (the profile lookup re-resolving) and is not cached" do
    @in_build = lambda do
      @in_build = nil
      builder.reset!
    end

    prompt = builder.build
    expect(prompt).to eq(clean_build)
    expect(builder.memory_index).not_to be_nil

    builder.build
    expect(section_calls.size).to eq(2)
  end

  it "keeps a build's result cached when no reset came" do
    builder.build
    builder.build
    expect(section_calls.size).to eq(1)
  end
end
