# frozen_string_literal: true

require "json"
require "samagotchi/client_id"

RSpec.describe Samagotchi::ClientId do
  # Every id chi makes, as a producer writes it: whether it is a human's input.
  let(:known) do
    {
      nil => true,
      "spawn:first" => true,
      "card:answer" => true,
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
      "relay:1234abcd" => false,
      "review:p_0123abcd" => true
    }
  end

  it "keeps the ids older and newer chis send each other" do
    expect([described_class::WEB_PREFIX, described_class::WEB_RESTART, described_class::TUI_PREFIX,
            described_class::CLI_SEND, described_class::CLI_ANSWER, described_class::CLI_RESTART,
            described_class::DELEGATE_PREFIX, described_class::CHILD_PREFIX, described_class::CONTEXT_PREFIX,
            described_class::TASK_PREFIX, described_class::SYSTEM_PREFIX, described_class::REMINDER, described_class::PLUGIN,
            described_class::RELAY_PREFIX, described_class::REVIEW_PREFIX])
      .to eq(%w[web: web:restart tui: cli:send cli:answer cli:restart delegate: child: context: task: system:
                system:reminder plugin relay: review:])
  end

  describe "the sender rows" do
    it "has a row for every id ClientId names, and every row is one of them" do
      constants = described_class.constants.map { |name| described_class.const_get(name) }.grep(String)
      expect(described_class::ROWS.map(&:match)).to match_array(constants)
    end

    it "finds the whole id first, then the longest prefix; NONE for nil, UNKNOWN for anything else" do
      expect(described_class.sender("system:reminder").origin).to eq("reminder")
      expect(described_class.sender("system:schedule:s1").wake).to eq(:schedule)
      expect(described_class.sender("system:other").wake).to eq(:automatic)
      expect(described_class.sender(nil)).to equal(described_class::NONE)
      expect(["", "webby", "plugin:x", "spawn:other"].map { |id| described_class.sender(id) }).to all(equal(described_class::UNKNOWN))
    end

    it "takes no sender as a human's, never the owner's" do
      expect([described_class.human?(nil), described_class.owner?(nil)]).to eq([true, false])
    end

    it "takes a worker's own first prompt and a person's card answer as the owner's, not interactive" do
      [described_class::FIRST_PROMPT, described_class::CARD_ANSWER].each do |id|
        expect([described_class.human?(id), described_class.owner?(id), described_class.interactive?(id)]).to eq([true, true, false])
      end
    end

    it "names a client case in the shared labels matrix for every row" do
      matrix = JSON.parse(File.read(File.expand_path("shared/labels_matrix.json", __dir__)))
      ids = matrix.dig("client_labels", "cases").map { |entry| entry["client_id"] }.compact
      described_class::ROWS.each do |row|
        expect(ids.any? { |id| row.prefix? ? id.start_with?(row.match) : id == row.match }).to be(true), row.match
      end
    end
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

  describe ".owner?" do
    it "counts the owner's web, TUI and chi send inputs, but not participants or automatic senders" do
      expect(%w[web:tab tui:4242 cli:send].map { |id| described_class.owner?(id) }).to all(be(true))
      expect(["review:p_0123abcd", "delegate:1234abcd", "task:t1", "plugin"]
               .map { |id| described_class.owner?(id) }).to all(be(false))
    end
  end

  describe ".delegate" do
    it "makes a delegating parent's id from its first 8 characters" do
      expect(described_class.delegate("0123abcd-ffff")).to eq("delegate:0123abcd")
      expect(described_class.origin(described_class.delegate("0123abcd-ffff"))).to eq("delegate")
    end
  end

  describe ".review" do
    it "makes and tells a participant's id; a participant's is no interactive owner's" do
      expect(described_class.review("p_0123abcd")).to eq("review:p_0123abcd")
      expect(described_class.review?("review:p_0123abcd")).to be(true)
      expect([nil, "web:x", "reviewer", "cli:send"].map { |id| described_class.review?(id) }).to all(be(false))
      expect(described_class.interactive?("review:p_0123abcd")).to be(false)
    end
  end

  describe ".origin" do
    it "names the turns chi runs on its own by their sender, and every other sender client" do
      origins = { "delegate:ab12cd34" => "delegate", "child:ab12cd34" => "delegate_report", "context:gh" => "context",
                  "task:t1" => "task", "system:reminder" => "reminder", "system:other" => "client", "web:x" => "client",
                  "cli:send" => "client", "plugin" => "client", nil => "client", "review:p_0123abcd" => "review" }
      expect(origins.keys.to_h { |id| [id, described_class.origin(id)] }).to eq(origins)
    end
  end

  describe ".wake_kind" do
    it "gives a person's ids the send row by allowlist, the unattended senders theirs, anything else the safe one" do
      kinds = { "cli:send" => :send, "web:x" => :send, described_class::WEB_UNNAMED => :send, "tui:1" => :send,
                described_class.schedule("s1") => :schedule, described_class::PLUGIN => :plugin,
                described_class.delegate("0123abcd") => :delegate, described_class.review("p_1") => :participant,
                nil => :automatic, "" => :automatic, "webby" => :automatic, "system:reminder" => :automatic,
                "relay:ab12cd34" => :automatic }
      expect(kinds.keys.to_h { |id| [id, described_class.wake_kind(id)] }).to eq(kinds)
    end
  end
end
