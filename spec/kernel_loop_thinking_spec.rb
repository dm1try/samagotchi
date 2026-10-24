# frozen_string_literal: true

require "json"
require "samagotchi/kernel_loop"
require "samagotchi/model_profile"

# The native loop with a thinking level: Qwen with thinking off gets an
# empty thought after the assistant cue on every generation of the turn, and
# the turn's model messages keep it, so the next generation's prompt starts
# with what the server has cached. Where the server's chat template opens a
# thought after the cue (Qwen3.5+), every other level gets the open thought.
RSpec.describe Samagotchi::KernelLoop, "thinking level" do
  subject(:kernel) { described_class.new(client: client, profile: Samagotchi::ModelProfile.qwen36) }

  let(:client) { instance_double(Samagotchi::Client) }
  let(:events) { [] }
  let(:empty_thought) { "<think>\n\n</think>\n\n" }
  let(:tool_call) { "<tool_call>\n<function=read>\n<parameter=path>\nnope.txt\n</parameter>\n</function>\n</tool_call>" }

  def script(*responses)
    prompts = []
    allow(client).to receive(:complete) do |prompt, **_kwargs|
      prompts << prompt
      responses.length > 1 ? responses.shift : responses.first
    end
    prompts
  end

  def run
    kernel.run([{ role: "user", content: "hi" }], on_stream_event: ->(e) { events << e })
  end

  it "prefills the empty thought after the cue for off, and keeps it in the turn's model messages" do
    kernel.turn_settings = kernel.turn_settings.with(thinking: :off)
    prompts = script(tool_call, "PONG")

    result = run

    expect(prompts).to all(end_with("<|im_start|>assistant\n#{empty_thought}"))
    # The second prompt carries the first generation as it was generated.
    expect(prompts[1]).to include("<|im_start|>assistant\n#{empty_thought}#{tool_call}")
    expect(result.output).to eq("PONG")
    expect(result.conversation.last).to eq(role: "model", content: "#{empty_thought}PONG", at: message_at)
    expect(events.select { |e| e[:type] == :generation_completed }.map { |e| e[:thinking_chars] }).to eq([0, 0])
  end

  it "leaves the prompt tail alone for default and an effort" do
    %i[default low].each do |level|
      kernel.turn_settings = kernel.turn_settings.with(thinking: level)
      prompts = script("PONG")

      expect(run.conversation.last).to eq(role: "model", content: "PONG", at: message_at)
      expect(prompts.last).to end_with("<|im_start|>assistant\n")
    end
  end

  it "strips the empty thought from the history of the next turn" do
    kernel.turn_settings = kernel.turn_settings.with(thinking: :off)
    script("PONG")
    first = run
    prompts = script("again")

    kernel.run(first.conversation + [{ role: "user", content: "more" }])

    expect(prompts.last).to include("<|im_start|>assistant\nPONG<|im_end|>")
  end

  describe "where the server's template opens a thought" do
    def props(body) = Samagotchi::Client::ServerProps.new(body: body, status: :ok)
    let(:qwen36_props) { JSON.parse(File.read(File.expand_path("fixtures/llama_cpp/props_qwen36_unsloth.json", __dir__))) }
    let(:first) { "reading it first\n</think>\n\n#{tool_call}" }
    let(:second) { "it is missing\n</think>\n\nPONG" }

    # Each response streamed in two chunks, the reasoning's close in the second.
    def stream(*responses)
      prompts = []
      allow(client).to receive(:complete) do |prompt, **kwargs|
        prompts << prompt
        response = responses.shift
        cut = (response.index("</think>") || response.length) - 3
        [response[0...cut], response[cut..]].each { |piece| kwargs[:on_chunk]&.call(content: piece, payload: {}) }
        response
      end
      prompts
    end

    def lane(name) = events.select { |e| e[:type] == :generation_chunk }.map { |e| e[name].to_s }.join

    before { allow(client).to receive(:server_props).with(model: anything).and_return(props(qwen36_props)) }

    it "opens the thought at default, streams the reasoning as thinking and keeps it out of the answer" do
      prompts = stream(first, second)

      result = run

      expect(prompts).to all(end_with("<|im_start|>assistant\n<think>\n"))
      # Append-only within the turn: the next prompt is this one, its reply, then the tool response.
      expect(prompts[1]).to start_with(prompts[0] + first)
      expect(result.output).to eq("PONG")
      expect(result.conversation.last).to eq(role: "model", content: "<think>\n#{second}", at: message_at)
      expect(lane(:thinking)).to include("reading it first", "it is missing")
      expect(lane(:text).strip).to eq("PONG")
    end

    it "counts a reply that only thought (closing the prefill's thought) as empty, and asks again" do
      prompts = stream("nothing to say yet\n</think>\n\n", second)

      result = run

      expect(prompts.size).to eq(2)
      expect(result.output).to eq("PONG")
    end

    def tools_run = events.select { |e| e[:type] == :tool_call_started }.map { |e| e[:tool] }

    it "runs no tool call written inside the closed thought" do
      prompts = stream("I could #{tool_call} but no need\n</think>\n\nPONG")

      expect(run.output).to eq("PONG")
      expect([prompts.size, tools_run]).to eq([1, []])
    end

    it "asks for no recovery when the thought only mentions an open <tool_call>" do
      prompts = stream("a <tool_call> block would do it, but no\n</think>\n\nPONG")

      expect(run.output).to eq("PONG")
      expect(prompts.size).to eq(1)
    end

    it "still runs a call written in a thought never closed" do
      prompts = stream("reading it first\n#{tool_call}", second)

      expect(run.output).to eq("PONG")
      expect([prompts.size, tools_run]).to eq([2, ["read"]])
    end

    it "opens it for an effort too, and keeps the empty thought for off" do
      kernel.turn_settings = kernel.turn_settings.with(thinking: :high)
      high = stream(second)
      run
      kernel.turn_settings = kernel.turn_settings.with(thinking: :off)
      off = script("PONG")
      run

      expect(high.last).to end_with("assistant\n<think>\n")
      expect(off.last).to end_with("assistant\n#{empty_thought}")
    end

    it "leaves the prompt as before with no template: a router's own /props" do
      allow(client).to receive(:server_props).with(model: anything).and_return(props({ "role" => "router" }))
      prompts = script("PONG")

      expect(run.output).to eq("PONG")
      expect(prompts.last).to end_with("<|im_start|>assistant\n")
    end
  end
end
