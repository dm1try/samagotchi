# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/model_profile"

# The native loop's empty-answer retry (EmptyAnswerRetry): the empty
# generation (with its thinking) is dropped, a hidden nudge goes on the tail
# and the model is asked again, at 0.6 unless a temperature is configured.
RSpec.describe Samagotchi::KernelLoop, "empty answer retry" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:nudge) { Samagotchi::TurnNote.empty_retry }
  let(:events) { [] }
  subject(:kernel) { described_class.new(client: client, profile: Samagotchi::ModelProfile.qwen36) }

  def script(*responses)
    calls = []
    allow(client).to receive(:complete) do |prompt, **kwargs|
      calls << { prompt: prompt, sampling: kwargs[:sampling] }
      responses.length > 1 ? responses.shift : responses.first
    end
    calls
  end

  def run(**options)
    kernel.run([{ role: "user", content: "hi" }], on_stream_event: ->(e) { events << e }, **options)
  end

  it "drops the empty generation, nudges and answers in the same turn" do
    calls = script("<think>Let me write the reply. Let me write the reply.</think>", "PONG")

    result = run

    expect(result.output).to eq("PONG")
    expect(result.conversation).to eq([{ role: "user", content: "hi" }, nudge, { role: "model", content: "PONG" }])
    expect(calls[1][:prompt]).to include(nudge[:content])
    expect(calls[1][:prompt]).not_to include("Let me write the reply")
    expect(calls.map { |c| c[:sampling] }).to eq([nil, { temperature: 0.6 }])
    expect(events.find { |e| e[:type] == :empty_answer_retry }).to include(iteration: 1, attempt: 1, of: 1)
  end

  it "keeps a configured temperature for the retry" do
    kernel.sampling = { temperature: 0.2 }
    calls = script("", "PONG")

    run

    expect(calls.map { |c| c[:sampling] }).to eq([{ temperature: 0.2 }, { temperature: 0.2 }])
  end

  it "ends as today after the retry is used up, without the spent nudge" do
    script("<think>loop</think>")

    result = run

    expect(result.output).to eq("")
    expect(result.conversation.map { |m| m[:role] }).to eq(%w[user model])
    expect(result.conversation).not_to include(nudge)
  end

  it "does nothing with retry.empty_answer 0" do
    ENV["SAMAGOTCHI_RETRY_EMPTY_ANSWER"] = "0"
    calls = script("", "late")

    expect(run.output).to eq("")
    expect(calls.length).to eq(1)
  ensure
    ENV.delete("SAMAGOTCHI_RETRY_EMPTY_ANSWER")
  end

  it "lets queued input go in place of the nudge" do
    calls = script("", "answered")
    queue = [[], ["user line"], []]

    result = run(pending_input: -> { queue.shift || [] })

    expect(result.output).to eq("answered")
    expect(result.conversation.map { |m| m[:content] }).to eq(["hi", "user line", "answered"])
    expect(calls.length).to eq(2)
    expect(events.map { |e| e[:type] }).not_to include(:empty_answer_retry)
  end

  it "runs the Qwen incomplete-tool-call recovery first, uncounted" do
    calls = script("<tool_call><function=execute><parameter=command>true", "</parameter></function></tool_call>", "", "done")

    result = run(max_iterations: 6)

    expect(result.output).to eq("done")
    expect(calls[1][:prompt]).to include("Continue the previous assistant message")
    expect(events.count { |e| e[:type] == :empty_answer_retry }).to eq(1)
  end
end
