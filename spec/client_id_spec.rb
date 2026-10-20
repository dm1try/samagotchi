# frozen_string_literal: true

require "samagotchi/client_id"

RSpec.describe Samagotchi::ClientId do
  # Every id chi makes, as a producer writes it: whether it is a human's input.
  let(:known) do
    {
      nil => true,
      "web:ab12cd34" => true,
      "web:restart" => true,
      "tui:4242" => true,
      "cli:send" => true,
      "cli:answer" => false,
      "cli:restart" => false,
      "delegate:1234abcd" => false,
      "child:1234abcd" => false,
      "context:pr-123" => false,
      "task:3f9a2c1d" => false,
      "system:reminder" => false,
      "plugin" => false,
      "relay:1234abcd" => false
    }
  end

  it "keeps the ids older and newer chis send each other" do
    expect([described_class::WEB_PREFIX, described_class::WEB_RESTART, described_class::TUI_PREFIX,
            described_class::CLI_SEND, described_class::CLI_ANSWER, described_class::CLI_RESTART,
            described_class::DELEGATE_PREFIX, described_class::CHILD_PREFIX, described_class::CONTEXT_PREFIX,
            described_class::TASK_PREFIX, described_class::SYSTEM_PREFIX, described_class::REMINDER, described_class::PLUGIN,
            described_class::RELAY_PREFIX])
      .to eq(%w[web: web:restart tui: cli:send cli:answer cli:restart delegate: child: context: task: system:
                system:reminder plugin relay:])
  end

  describe ".interactive?" do
    it "is a web tab or a chi TUI only: they see a command's reply and can answer it" do
      expect(%w[web:tab1 web:restart tui:4242].map { |id| described_class.interactive?(id) }).to all(be(true))
      expect([nil, "cli:send", "delegate:1234abcd", "plugin", "system:reminder", "child:1", "webby"]
               .map { |id| described_class.interactive?(id) }).to all(be(false))
    end
  end

  describe ".human?" do
    it "counts a human's input only: web, tui, chi send and no client id" do
      expect(known.keys.to_h { |id| [id, described_class.human?(id)] }).to eq(known)
    end

    it "does not count an id it doesn't know" do
      expect(%w[other other:1 cli:other webby tui plugin:x].map { |id| described_class.human?(id) }).to all(be(false))
    end
  end

  describe ".origin" do
    it "names the turns chi runs on its own by their sender, and every other sender client" do
      origins = { "delegate:ab12cd34" => "delegate", "child:ab12cd34" => "delegate_report", "context:gh" => "context",
                  "task:t1" => "task", "system:reminder" => "reminder", "system:other" => "client", "web:x" => "client",
                  "cli:send" => "client", "plugin" => "client", nil => "client" }
      expect(origins.keys.to_h { |id| [id, described_class.origin(id)] }).to eq(origins)
    end
  end
end
