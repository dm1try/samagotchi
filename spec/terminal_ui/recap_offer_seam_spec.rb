# frozen_string_literal: true

require "samagotchi/terminal_ui"

# The REPL tells its Engine's recap when a continue offer is open, so a
# recap written at the offer says the last turn stopped unfinished.
RSpec.describe Samagotchi::TerminalUI, "recap at a continue offer", :recap do
  it "hands the recap a seam that reads the REPL's TurnFlow" do
    ui = described_class.new(client: instance_double(Samagotchi::Client))
    recap = ui.instance_variable_get(:@engine).recap
    expect(recap).not_to be_nil
    seam = recap.instance_variable_get(:@awaiting_continue)
    turn_flow = ui.instance_variable_get(:@turn_flow)

    expect(seam.call).to be(false)
    turn_flow.instance_variable_set(:@offer, { context: {} })
    expect(turn_flow.awaiting_continue?).to be(true)
    expect(seam.call).to be(true)
  end
end
