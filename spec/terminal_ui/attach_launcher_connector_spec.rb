# frozen_string_literal: true

require "stringio"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attach_launcher"

# AttachLauncher.run with a connector: the session is found or started by
# the connector, whose AttachLink the loop runs on; this machine's .connect
# isn't asked.
RSpec.describe Samagotchi::TerminalUI::AttachLauncher, ".run with a connector" do
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1") }
  let(:via) { Samagotchi::ChiInvocation.new(remote: "studio") }
  let(:strategy) { Samagotchi::Guardrails::ParentPolicy.strategy("soft") }
  let(:link) { instance_double(Samagotchi::TerminalUI::LocalLink, client: client, parent_strategy: strategy, via: via) }
  let(:connector) { double("connector", connect: link) }
  let(:surface) { instance_double(Samagotchi::TerminalUI::PlainSurface) }

  before do
    allow($stdin).to receive(:tty?).and_return(true)
    allow(Samagotchi::Guardrails::ParentApprovals).to receive(:parent_process?).and_return(false)
    allow(described_class).to receive_messages(open_surface: surface, close_surface: nil)
    allow(described_class).to receive(:connect)
  end

  it "runs the loop on the connector's link, with the launch's own keywords" do
    attached = instance_double(Samagotchi::TerminalUI::AttachedLoop, run: :detached)
    allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new).and_return(attached)

    expect(described_class.run(attach: "s-1", model: "m", connector: connector)).to eq(:detached)

    expect(described_class).not_to have_received(:connect)
    expect(Samagotchi::TerminalUI::AttachedLoop).to have_received(:new)
      .with(link: link, screen: surface, client_id: "tui:#{Process.pid}", first_prompt: nil, first_command: "/model m",
            no_interrupt: false, default_input: false, wait_at_eof: false, as_parent: false)
  end

  it "reports a question left waiting with the link's parent strategy and its spelling" do
    pending_question = { id: "q1", question: "Which file?", options: %w[A B] }
    attached = instance_double(Samagotchi::TerminalUI::AttachedLoop, run: :unanswered, unanswered: pending_question)
    allow(Samagotchi::TerminalUI::AttachedLoop).to receive(:new).and_return(attached)
    allow(described_class).to receive(:report_unanswered)

    expect(described_class.run(attach: "s-1", connector: connector)).to eq(:unanswered)

    expect(described_class).to have_received(:report_unanswered)
      .with(pending_question, session_id: "s-1", state_dir: Samagotchi::Session.default_state_dir, strategy: strategy, via: via)
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachLauncher, ".report_unanswered with a strategy and a spelling" do
  it "uses them instead of reading the session here" do
    allow(Samagotchi::ParentReport).to receive(:strategy_for)
    err = StringIO.new
    described_class.report_unanswered({ id: "q1", question: "Which file?", options: %w[A B] }, session_id: "s-1", err: err,
                                                                                                 strategy: Samagotchi::Guardrails::ParentPolicy.strategy("soft"),
                                                                                                 via: Samagotchi::ChiInvocation.new(remote: "studio"))

    expect(Samagotchi::ParentReport).not_to have_received(:strategy_for)
    expect(err.string).to include("answer: chi --remote studio answer s-1 --question q1 --option N")
  end
end
