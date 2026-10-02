# frozen_string_literal: true

require "spec_helper"
require "samagotchi/cli/exit"
require "samagotchi/parent_report"
require "samagotchi/terminal_ui/attach_launcher"
require "samagotchi/send_command"

# One table of exit statuses (docs/sub-agent.md, docs/cli.md); the
# commands point at it instead of literals.
RSpec.describe Samagotchi::CLI::Exit do
  it "names every status a chi command exits with" do
    expect([described_class::OK, described_class::FAILED, described_class::USAGE, described_class::QUESTION,
            described_class::RUNNING, described_class::INTERRUPTED]).to eq([0, 1, 2, 3, 4, 130])
  end

  it "is the one the usage side and the parent reports use" do
    expect(Samagotchi::CLI::Command.const_defined?(:USAGE_EXIT, false)).to be(false)
    expect(Samagotchi::ParentReport.constants.grep(/\AEXIT_/)).to be_empty
  end

  it "maps a parent wait's ends and an attached run's" do
    result = Samagotchi::ReplyWait::Result.new(status: :waiting_for_answer)
    expect(Samagotchi::ParentReport.exit_status(result)).to eq(described_class::QUESTION)
    expect(Samagotchi::TerminalUI::AttachLauncher.exit_status(:unanswered)).to eq(described_class::QUESTION)
    expect(Samagotchi::TerminalUI::AttachLauncher.exit_status(:failed)).to eq(described_class::FAILED)
  end
end
