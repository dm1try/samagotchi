# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/model_profile"

# A corrupt Gemma 4 generation (a tool call never closed, or a fresh thought
# header after answer text: what a poisoned llama.cpp prompt cache produced,
# ggml-org/llama.cpp#27148) is not an answer: it is logged, asked once more
# without the prompt cache, and a second one fails the turn. Its half tool
# call never runs.
RSpec.describe Samagotchi::KernelLoop, "malformed generation" do
  subject(:kernel) { described_class.new(client: client, profile: Samagotchi::ModelProfile.gemma4) }

  let(:client) { instance_double(Samagotchi::Client) }
  let(:events) { [] }
  # The stored message of the 2026-10-05 cross-talk (slot-crosstalk evidence).
  let(:leaked) do
    "<|channel>thought\n<channel|><|tool_call>call:execute{command:<|\"|>sleep 15 && head -1 fruits.txt<|\"|>," \
      "description:<|\"|>Run sleep 15<|\"|>\n<|channel>thought\n<channel|>The files I saw are:\n- `fruits.txt`\n\n" \
      "The line count for `fruits.txt` is 7."
  end

  # Streams each response with the slot and counts llama.cpp sends.
  def script(*responses)
    calls = []
    allow(client).to receive(:context_window).and_return(100_000)
    allow(client).to receive(:complete) do |prompt, on_chunk: nil, **kwargs|
      calls << { prompt: prompt, cache_prompt: kwargs.fetch(:cache_prompt, :unset) }
      text = responses.length > 1 ? responses.shift : responses.first
      on_chunk&.call(content: text, payload: { "content" => text, "id_slot" => 2 })
      on_chunk&.call(content: "", payload: { "stop" => true, "id_slot" => 2,
                                             "timings" => { "cache_n" => 5000, "prompt_n" => 30 } },
                     finish_reason: "stop")
      text
    end
    calls
  end

  def run
    kernel.run([{ role: "user", content: "hi" }], on_stream_event: ->(e) { events << e })
  end

  before { allow(Samagotchi::Log).to receive(:warn) }

  it "asks again without the prompt cache and answers from the retry" do
    calls = script(leaked, "<|channel>thought\n<channel|>apple")

    result = run

    expect(result.output).to eq("apple")
    expect(result.conversation).to eq([{ role: "user", content: "hi" },
                                       { role: "model", content: "<|channel>thought\n<channel|>apple" }])
    expect(calls.map { |c| c[:cache_prompt] }).to eq([:unset, false])
    expect(events.find { |e| e[:type] == :empty_answer_retry }).to include(iteration: 1, attempt: 1, of: 1, malformed: true)
    expect(events.map { |e| e[:type] }).not_to include(:tool_call_started)
  end

  it "logs generation_malformed with the slot, the cache count, the finish reason and the raw tail" do
    script(leaked, "fine")

    run

    expect(Samagotchi::Log).to have_received(:warn).with(
      :model, "generation_malformed",
      hash_including(iteration: 1, reason: "unclosed tool call", id_slot: 2, cache_n: 5000, finish_reason: "stop",
                     payload: a_string_ending_with("is 7."))
    )
  end

  it "fails the turn when the retry is malformed too, saving no answer and running no tool" do
    script(leaked)
    runner = kernel.send(:tool_runner)
    allow(runner).to receive(:run)

    expect { run }.to raise_error(Samagotchi::LLM::MalformedGeneration) { |error|
      expect(error.summary).to include("malformed")
      expect(error.partial_conversation).to eq([{ role: "user", content: "hi" }])
    }
    expect(runner).not_to have_received(:run)
  end

  it "catches a second thought header after answer text" do
    calls = script("<|channel>thought\nok<channel|>The answer is 4.<|channel>thought\n<channel|>Other text", "4")

    expect(run.output).to eq("4")
    expect(calls.length).to eq(2)
    expect(Samagotchi::Log).to have_received(:warn)
      .with(:model, "generation_malformed", hash_including(reason: "thought header after the answer"))
  end

  it "goes back to the prompt cache after the retry" do
    calls = script(leaked, "<|channel>thought\n<channel|><|tool_call>call:unknown_tool{a:<|\"|>b<|\"|>}<tool_call|>",
                   "<|channel>thought\n<channel|>done")

    expect(run.output).to eq("done")
    expect(calls.map { |c| c[:cache_prompt] }).to eq([:unset, false, :unset])
  end

  it "leaves a well-formed tool call and answer alone" do
    calls = script("<|channel>thought\nhm<channel|><|tool_call>call:unknown_tool{a:<|\"|>b<|\"|>}<tool_call|>",
                   "<|channel>thought\n<channel|>done")

    expect(run.output).to eq("done")
    expect(calls.map { |c| c[:cache_prompt] }).to eq(%i[unset unset])
    expect(Samagotchi::Log).not_to have_received(:warn).with(:model, "generation_malformed", anything)
  end
end
