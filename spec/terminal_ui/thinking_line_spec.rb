# frozen_string_literal: true

require "samagotchi/terminal_ui/thinking_line"

RSpec.describe Samagotchi::TerminalUI::ThinkingLine do
  subject(:line) { described_class.new(clock: -> { 0.0 }, dwell: 0) }

  def chunk(content, text:, thinking:)
    { type: :generation_chunk, iteration: 1, content: content, text: text, thinking: thinking }
  end

  it "puts a Gemma thought in the thinking lane and its answer in writing, no markup" do
    line.chunk(chunk("<|channel>thought\nweighing options.", text: "", thinking: "\nweighing options."))
    expect([line.label, line.sentence]).to eq([:thinking, "weighing options."])

    line.chunk(chunk("<channel|>Hi there.", text: "Hi there.", thinking: ""))
    expect([line.label, line.sentence]).to eq([:writing, "Hi there."])
  end

  it "shows no tool call markup from a Gemma chunk whose text is empty" do
    line.chunk(chunk("Let me look.", text: "Let me look.", thinking: ""))
    line.chunk(chunk('<|tool_call>call:memory_read{name:<|"|>notes<|"|>}<tool_call|>', text: "", thinking: ""))

    expect([line.label, line.sentence]).to eq([:writing, "Let me look."])
  end

  it "keeps Qwen's lanes" do
    line.chunk(chunk("<think>checking the file.", text: "", thinking: "checking the file."))
    expect([line.label, line.sentence]).to eq([:thinking, "checking the file."])

    line.chunk(chunk("</think>Done.", text: "Done.", thinking: ""))
    expect([line.label, line.sentence]).to eq([:writing, "Done."])
  end
end
