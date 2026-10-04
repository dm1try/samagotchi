# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/prompt_cache"

RSpec.describe Samagotchi::LLM::PromptCache do
  let(:control) { { type: "ephemeral" } }
  let(:claude) { "anthropic/claude-sonnet-5.5" }

  def deep_freeze(obj)
    case obj
    when Hash then obj.each_value { |value| deep_freeze(value) }
    when Array then obj.each { |value| deep_freeze(value) }
    end
    obj.freeze
  end

  def text_part(text, marked: false)
    marked ? { type: "text", text: text, cache_control: control } : { type: "text", text: text }
  end

  it "marks the system message and the last user message, a String becoming one text part" do
    messages = deep_freeze([{ role: "system", content: "sys" }, { role: "user", content: "hi" }])

    expect(described_class.mark(messages, model: claude)).to eq([
      { role: "system", content: [text_part("sys", marked: true)] },
      { role: "user", content: [text_part("hi", marked: true)] }
    ])
  end

  it "marks a last tool message and leaves the assistant tool_calls message alone" do
    call = { role: "assistant", content: nil, tool_calls: [{ id: "c1", type: "function",
                                                             function: { name: "execute", arguments: "{}" } }] }
    messages = deep_freeze([{ role: "system", content: "sys" }, { role: "user", content: [text_part("go")] },
                            call, { role: "tool", tool_call_id: "c1", content: "out" }])

    marked = described_class.mark(messages, model: claude)

    expect(marked[1]).to equal(messages[1])
    expect(marked[2]).to equal(call)
    expect(marked[3]).to eq(role: "tool", tool_call_id: "c1", content: [text_part("out", marked: true)])
  end

  it "skips a trailing assistant message with empty content" do
    messages = deep_freeze([{ role: "user", content: "hi" }, { role: "assistant", content: "", tool_calls: [] }])

    marked = described_class.mark(messages, model: claude)

    expect(marked.first[:content]).to eq([text_part("hi", marked: true)])
    expect(marked.last).to equal(messages.last)
  end

  it "marks the last part of Array content that ends in text, leaving the caller's parts unchanged" do
    parts = [{ type: "image_url", image_url: { url: "data:image/png;base64,AA" } }, text_part("look")]
    messages = deep_freeze([{ role: "user", content: parts }])

    marked = described_class.mark(messages, model: claude)

    expect(marked.first[:content]).to eq([parts.first, text_part("look", marked: true)])
    expect(parts.last).to eq(text_part("look"))
  end

  it "marks the text part, not a trailing image" do
    parts = [text_part("[images from tool results]"), { type: "image_url", image_url: { url: "data:image/png;base64,AA" } }]
    messages = deep_freeze([{ role: "system", content: "sys" }, { role: "user", content: parts }])

    marked = described_class.mark(messages, model: claude)

    expect(marked.last[:content]).to eq([text_part("[images from tool results]", marked: true), parts.last])
  end

  it "marks the last part when no part is text" do
    image = { type: "image_url", image_url: { url: "data:image/png;base64,AA" } }
    messages = deep_freeze([{ role: "user", content: [image] }])

    expect(described_class.mark(messages, model: claude).first[:content]).to eq([image.merge(cache_control: control)])
  end

  it "keeps the key style of string-keyed parts" do
    messages = deep_freeze([{ role: "user", content: [{ "type" => "text", "text" => "hi" }] }])

    expect(described_class.mark(messages, model: claude).first[:content])
      .to eq([{ "type" => "text", "text" => "hi", "cache_control" => control }])
  end

  it "marks only the last message without a system message, and a single message once" do
    messages = deep_freeze([{ role: "user", content: "a" }, { role: "assistant", content: "b" }, { role: "user", content: "c" }])

    marked = described_class.mark(messages, model: claude)

    expect(marked.first(2)).to eq(messages.first(2))
    expect(marked.last[:content]).to eq([text_part("c", marked: true)])
    expect(described_class.mark(deep_freeze([{ role: "user", content: "x" }]), model: claude))
      .to eq([{ role: "user", content: [text_part("x", marked: true)] }])
  end

  it "keeps the breakpoints on the first system message and the last tool message past a trailing turn note" do
    messages = deep_freeze([{ role: "system", content: "sys" }, { role: "user", content: [text_part("go")] },
                            { role: "assistant", content: nil, tool_calls: [{ id: "c1" }] },
                            { role: "tool", tool_call_id: "c1", content: "out" },
                            { role: "system", content: "[turn note]" }])

    marked = described_class.mark(messages, model: claude)

    expect(marked[0][:content]).to eq([text_part("sys", marked: true)])
    expect(marked[3][:content]).to eq([text_part("out", marked: true)])
    expect(marked[4]).to equal(messages[4])
    expect(marked[1]).to equal(messages[1])
  end

  it "matches Claude ids in any spelling" do
    %w[anthropic/claude-sonnet-5.5 ~anthropic/claude-sonnet-latest claude-sonnet-5.5 Claude-Opus].each do |model|
      expect(described_class.claude?(model)).to be(true), model
    end
  end

  it "sends the system prompt as its stable part, marked, and its per-session tail at the cache_split" do
    messages = deep_freeze([{ role: "system", content: "base\nModel: m", cache_split: 5 }, { role: "user", content: "hi" }])

    expect(described_class.mark(messages, model: claude)).to eq([
      { role: "system", content: [text_part("base\n", marked: true), text_part("Model: m")] },
      { role: "user", content: [text_part("hi", marked: true)] }
    ])
  end

  it "marks the whole system prompt when the cache_split doesn't fall inside it" do
    [0, 13, 99, nil].each do |split|
      messages = deep_freeze([{ role: "system", content: "base\nModel: m", cache_split: split }, { role: "user", content: "hi" }])
      expect(described_class.mark(messages, model: claude).first).to eq({ role: "system", content: [text_part("base\nModel: m", marked: true)] })
    end
  end

  it "drops the cache_split from every message for other models, and keeps messages without one as they are" do
    messages = deep_freeze([{ role: "system", content: "base\nModel: m", cache_split: 5 }, { role: "user", content: "hi" }])

    expect(described_class.mark(messages, model: "deepseek/deepseek-v4.1-flash"))
      .to eq([{ role: "system", content: "base\nModel: m" }, { role: "user", content: "hi" }])
    plain = deep_freeze([{ role: "user", content: "hi" }])
    expect(described_class.without_split(plain)).to equal(plain)
  end

  it "leaves other models' messages as they are" do
    messages = deep_freeze([{ role: "system", content: "sys" }, { role: "user", content: "hi" }])

    %w[deepseek/deepseek-v4.1-flash incoai/Qwen3.8-27B-Splash].each do |model|
      expect(described_class.mark(messages, model: model)).to equal(messages)
    end
  end

  it "tells whether messages carry a breakpoint" do
    plain = [{ role: "user", content: "hi" }]

    expect(described_class.marked?(plain)).to be(false)
    expect(described_class.marked?(described_class.mark(plain, model: claude))).to be(true)
  end
end
