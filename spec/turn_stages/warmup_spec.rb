# frozen_string_literal: true

require "samagotchi/turn_stages/warmup"

# The stage reads the turn's TurnContext settings and warms up only when the
# next turn's start is the one it can prefill. What a warm-up sends is
# engine_warmup_spec's.
RSpec.describe Samagotchi::TurnStages::Warmup do
  let(:prompt_warmup) { instance_double(Samagotchi::PromptWarmup, start: true) }
  let(:kernel) { double("kernel", warmup_prompt: ["PROMPT", []], last_slot: 2, warmed_up!: nil) }
  let(:client) { double("client", warm_up: nil) }
  let(:model) { double("model", client: client, chat?: false, entry: double("entry", remote?: false)) }
  let(:settings) { Struct.new(:llm_context, :vision, :model_name).new(nil, :vision, "m") }
  let(:turn) { Struct.new(:session, :context).new(Struct.new(:messages).new([]), Struct.new(:settings).new(settings)) }
  let(:result) { double("result", canceled?: false, resumable?: false) }
  let(:waiting) { false }
  let(:stage) do
    described_class.new(prompt_warmup: prompt_warmup, kernel: kernel, turn_state: double("turn_state", carried_steers?: false),
                        model_settings: double("model_settings", turn_llm_context: nil), model: -> { model },
                        system_prompt: ->(_model) { "SYS" }, reminders_due: -> { false }, next_turn_waiting: -> { waiting })
  end

  before { allow(Samagotchi::PromptWarmup).to receive(:enabled?).and_return(true) }

  it "warms up from the turn's settings on the last slot" do
    stage.after(turn, result)

    expect(kernel).to have_received(:warmup_prompt).with(anything, llm_context: nil, vision: :vision)
    expect(prompt_warmup).to have_received(:start).with(hash_including(prompt: "PROMPT", model: "m", slot: 2))
    expect(kernel).to have_received(:warmed_up!)
  end

  it "sends nothing after a canceled turn" do
    stage.after(turn, double("result", canceled?: true, resumable?: false))

    expect(prompt_warmup).not_to have_received(:start)
    expect(kernel).not_to have_received(:warmup_prompt)
  end

  it "sends nothing after a resumable turn (its continue offer differs)" do
    stage.after(turn, double("result", canceled?: false, resumable?: true))

    expect(prompt_warmup).not_to have_received(:start)
    expect(kernel).not_to have_received(:warmup_prompt)
  end

  context "when the next turn starts at once" do
    let(:waiting) { true }

    it "sends nothing" do
      stage.after(turn, result)

      expect(prompt_warmup).not_to have_received(:start)
      expect(kernel).not_to have_received(:warmup_prompt)
    end
  end
end
