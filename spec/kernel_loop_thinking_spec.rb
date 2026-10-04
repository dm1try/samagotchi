# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/model_profile"

# The native loop with a thinking level: Qwen with thinking off gets an
# empty thought after the assistant cue on every generation of the turn, and
# the turn's model messages keep it, so the next generation's prompt starts
# with what the server has cached.
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
    expect(result.conversation.last).to eq(role: "model", content: "#{empty_thought}PONG")
    expect(events.select { |e| e[:type] == :generation_completed }.map { |e| e[:thinking_chars] }).to eq([0, 0])
  end

  it "leaves the prompt tail alone for default and an effort" do
    %i[default low].each do |level|
      kernel.turn_settings = kernel.turn_settings.with(thinking: level)
      prompts = script("PONG")

      expect(run.conversation.last).to eq(role: "model", content: "PONG")
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
end
