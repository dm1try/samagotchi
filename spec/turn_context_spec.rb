# frozen_string_literal: true

require "samagotchi/turn_context"
require "samagotchi/cancellation_controller"

RSpec.describe Samagotchi::TurnContext do
  it "none is the owner's turn outside an Engine: no session, no controller, fresh git, the given settings" do
    none = described_class.none
    expect(none).to have_attributes(session: nil, origin: Samagotchi::TurnOrigin::NONE, author: nil, controller: nil,
                                    settings: Samagotchi::LLM::TurnSettings.none, surface: nil)
    expect(none.git).to be_a(Samagotchi::Guardrails::GitInfo)
    expect(none.git).not_to equal(described_class.none.git)
    expect(none).to be_frozen
  end

  it "says whether a participant wrote it, and whether its controller is cancelled" do
    controller = Samagotchi::CancellationController.new
    turn = described_class.none(author: "p:abc", controller: controller)
    expect([turn.participant?, turn.cancelled?]).to eq([true, false])
    controller.cancel!(:user)
    expect(turn.cancelled?).to be(true)
    expect([described_class.none.participant?, described_class.none.cancelled?]).to eq([false, false])
  end

  it "has no LLM context layers without settings or a strategy" do
    expect(described_class.none.llm_context_layers).to eq([])
    expect(described_class.none(settings: nil).llm_context_layers).to eq([])
  end

  it "reads the session's working-set pins at call time" do
    session = Struct.new(:working_set_pins).new([])
    turn = described_class.none(session: session)
    session.working_set_pins = [:pin]
    expect(turn.working_set_pins).to eq([:pin])
    expect(described_class.none.working_set_pins).to eq([])
  end
end
