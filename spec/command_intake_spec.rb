# frozen_string_literal: true

require "samagotchi/command_intake"
require "samagotchi/session_commands"

RSpec.describe Samagotchi::CommandIntake do
  # Every id chi makes: whether a message from it may run as a session command.
  let(:table) do
    {
      nil => true,
      "web:ab12cd34" => true,
      "web:restart" => true,
      "tui:4242" => true,
      "cli:send" => true,
      "cli:answer" => true,
      "cli:restart" => false,
      "delegate:1234abcd" => false,
      "child:1234abcd" => false,
      "context:pr-123" => false,
      "task:3f9a2c1d" => false,
      "system:reminder" => false,
      "system:schedule:0123456789abcdef" => false,
      "plugin" => false,
      "relay:1234abcd" => false,
      "review:p_0123abcd" => false,
      "other" => false
    }
  end

  it "allows a person's input and chi answer's, nobody automatic, and no participant" do
    expect(table.keys.to_h { |id| [id, described_class.allowed?(id)] }).to eq(table)
  end

  it "tells a shell line (!<cmd>, !rollback) by its first character after any blank" do
    expect(["!touch x", "  !ls", "!rollback", "!touch x\nand more", "!"].map { |t| described_class.shell_line?(t) }).to all(be(true))
    expect(["/model x", "run !ls", "", nil, "hi !"].map { |t| described_class.shell_line?(t) }).to all(be(false))
  end

  it "tells a shell line by SessionCommands' own prefix" do
    expect(described_class::SHELL_PREFIX).to eq(Samagotchi::SessionCommands::SHELL_BANG_PREFIX)
  end

  it "refuses a shell line from a sender that may not send commands only" do
    expect(described_class.refused?("!ls", "delegate:1234abcd")).to be(true)
    expect(described_class.refused?("!ls", "system:schedule:x")).to be(true)
    expect(described_class.refused?("/model x", "delegate:1234abcd")).to be(false)
    expect(described_class.refused?("!ls", "cli:send")).to be(false)
    expect(described_class.refused?("!ls", nil)).to be(false)
  end
end
