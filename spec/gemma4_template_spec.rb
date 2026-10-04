# frozen_string_literal: true

require "json"
require "samagotchi/prompt"
require "samagotchi/thinking"
require "samagotchi/tool_declarations"

# The gemma4 native prompt against Gemma 4's own chat template, as a
# llama.cpp server renders it (gemma-4-26B-A4B-it, POST /apply-template with
# chat_template_kwargs.enable_thinking). The renders are in
# fixtures/gemma4_template_renders.json; to capture them again, post the
# OpenAI-shaped twin of each conversation below (assistant tool_calls with
# content "" and the thought as reasoning_content, role "tool" results) to a
# Gemma 4 server's /apply-template.
RSpec.describe "Gemma 4 native prompt vs the chat template" do
  let(:profile) { Samagotchi::ModelProfile.gemma4 }
  let(:renders) { JSON.parse(File.read(File.expand_path("fixtures/gemma4_template_renders.json", __dir__))) }

  def conversation(think:, upto: nil)
    messages = [
      { role: "system", content: "#{think ? "<|think|>\n" : ""}You are chi. Use tools when needed." },
      { role: "user", content: "What is in notes.txt?" },
      { role: "model", content: "<|channel>thought\nI should read it.\n<channel|><|tool_call>call:read{path:<|\"|>notes.txt<|\"|>}<tool_call|>" },
      { role: "tool_response", content: "[read]\n1: buy milk" },
      { role: "model", content: "It says to buy milk." },
      { role: "user", content: "Thanks." }
    ]
    upto ? messages.first(upto) : messages
  end

  def render(messages, level)
    prefill = Samagotchi::Thinking.native(level, profile).prefill
    Samagotchi::Prompt.format_with_images(messages, profile: profile, prefill: Samagotchi::Prompt.prefill_for(messages, profile, prefill)).first
  end

  it "ends turns with <turn|> and stops on it" do
    expect(profile.turn_end).to eq("<turn|>")
    expect(profile.stop_sequences).to eq(["<turn|>", "<|tool_response>"])
  end

  it "matches the template with thinking off, ending on a user turn (empty thought cue)" do
    expect(render(conversation(think: false), :off)).to eq(renders.fetch("off_end_user"))
  end

  it "matches the template with thinking off, ending on a tool response (the model's turn goes on)" do
    expect(render(conversation(think: false, upto: 4), :off)).to eq(renders.fetch("off_end_tool"))
  end

  it "matches the template with thinking on, ending on a user turn" do
    expect(render(conversation(think: true), :high)).to eq(renders.fetch("on_end_user"))
  end

  # The template opens a thought after a tool response when thinking is on;
  # chi leaves it to the model (a prefilled open thought would stream as
  # answer text: each generation's splitter starts outside a thought).
  it "matches the template with thinking on, ending on a tool response, save the forced thought" do
    expect(render(conversation(think: true, upto: 4), :high))
      .to eq(renders.fetch("on_end_tool").delete_suffix("<|channel>thought\n"))
  end

  it "answers a batch with one tool_response block per call" do
    messages = [
      { role: "system", content: "You are chi. Use tools when needed." },
      { role: "user", content: "x" },
      { role: "model", content: "<|tool_call>call:read{path:<|\"|>a<|\"|>}<tool_call|><|tool_call>call:bash{command:<|\"|>ls<|\"|>}<tool_call|>" },
      { role: "tool_response", content: "[read]\nA\n\n---\n\n[bash]\nB" }
    ]
    expect(render(messages, :off)).to eq(renders.fetch("batch"))
  end

  it "drops an answer's thought once a later user turn starts, as the template does" do
    messages = [
      { role: "user", content: "hi" },
      { role: "model", content: "<|channel>thought\ngreet\n<channel|>Hello." },
      { role: "user", content: "again" }
    ]
    expect(render(messages, :high)).to eq("<|turn>user\nhi<turn|>\n<|turn>model\nHello.<turn|>\n<|turn>user\nagain<turn|>\n<|turn>model\n")
  end

  it "closes the model's turn after a tool response when another role follows" do
    messages = [
      { role: "user", content: "q" },
      { role: "model", content: "<|tool_call>call:read{path:<|\"|>a<|\"|>}<tool_call|>" },
      { role: "tool_response", content: "[read] Error: nope" },
      { role: "user", content: "stop" }
    ]
    expect(render(messages, :high)).to eq(
      "<|turn>user\nq<turn|>\n<|turn>model\n<|tool_call>call:read{path:<|\"|>a<|\"|>}<tool_call|>" \
      "<|tool_response>response:read{value:<|\"|>Error: nope<|\"|>}<tool_response|><turn|>\n" \
      "<|turn>user\nstop<turn|>\n<|turn>model\n"
    )
  end

  it "declares tools as the template does" do
    schemas = [
      { name: "read", description: "Read a file",
        parameters: { type: "object", properties: { path: { type: "string", description: "File path" },
                                                    offset: { type: "integer", description: "Start line" },
                                                    flag: { type: "boolean", description: "" } },
                      required: ["path"] } },
      { name: "noargs", description: "No args", parameters: { type: "object", properties: {} } }
    ]
    declared = renders.fetch("tools")[/<\|tool>.*<tool\|>/m]
    expect(Samagotchi::ToolDeclarations.gemma_declarations(schemas)).to eq(declared)
  end
end
