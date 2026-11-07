# frozen_string_literal: true

require "samagotchi/turn_stages/warmup"

# The stage keeps nothing of a turn (the PromptWarmup keeps the pin): it
# reads the turn's TurnContext settings and lets the turn go. What a warm-up
# sends is engine_warmup_spec's.
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

  it "warms up from the turn's settings and holds nothing of the turn after" do
    stage.after(turn, result)

    expect(kernel).to have_received(:warmup_prompt).with(anything, llm_context: nil, vision: :vision)
    expect(prompt_warmup).to have_received(:start).with(hash_including(prompt: "PROMPT", model: "m", slot: 2))
    expect(kernel).to have_received(:warmed_up!)
    expect(stage.instance_variables.map { |name| stage.instance_variable_get(name) })
      .not_to include(satisfy { |value| value.equal?(turn) || value.equal?(settings) })
  end

  context "when the next turn starts at once" do
    let(:waiting) { true }

    it "sends nothing" do
      stage.after(turn, result)

      expect(prompt_warmup).not_to have_received(:start)
    end
  end
end
