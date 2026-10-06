# frozen_string_literal: true

require "spec_helper"
require "samagotchi/broadcast/tags"
require "samagotchi/config"

RSpec.describe Samagotchi::Broadcast::Tags do
  def labels(tags) = tags.map(&:label)

  def note(text) = described_class.of_text(text, from: "note")

  describe ".of_text" do
    it "finds ticket ids, PR mentions and links, a link as its host and path" do
      tags = note("PAY-123 is back: https://www.notion.so/team/Checkout-v2-abc?pvs=4, see PR #42.")

      expect(labels(tags)).to eq(["ticket PAY-123", "pr #42", "link notion.so/team/Checkout-v2-abc"])
      expect(tags.map(&:from).uniq).to eq(["note"])
    end

    it "reads a GitHub pull request URL as a pr with its repo, and a link" do
      expect(labels(note("look at https://github.com/Acme/Shop/pull/212/files")))
        .to eq(["pr acme/shop#212", "link github.com/Acme/Shop/pull/212/files"])
    end

    it "takes no tag from a bare host, or from words the ticket pattern would take that are no ticket" do
      expect(note("files are UTF-8, hashes SHA-256, dates ISO-8601; https://github.com/ and http://localhost:8080/"))
        .to eq([])
    end

    it "has the default broadcast.ticket_pattern as its own default" do
      expect(Samagotchi::Config.find_by_key("broadcast.ticket_pattern").default).to eq(described_class::DEFAULT_TICKET_PATTERN)
    end

    it "uses a ticket pattern given, and the default for an invalid one, saying so" do
      warnings = []
      custom = described_class.ticket_regexp('\bT\d{4}\b')
      broken = described_class.ticket_regexp("([", warn: ->(line) { warnings << line })

      expect(labels(described_class.of_text("bug T1234 again", from: "note", ticket: custom))).to eq(["ticket T1234"])
      expect(broken.source).to eq(described_class::DEFAULT_TICKET_PATTERN)
      expect(warnings.first).to start_with("broadcast.ticket_pattern \"([\" is not a valid pattern")
    end
  end

  describe ".of_session" do
    it "finds a ticket in a lowercase branch, the user's messages and attached context" do
      tags = described_class.of_session(branch: "feat/pay-123-retry",
                                        messages: ["fix OPS-7 first", "spec in https://notion.so/team/prd"],
                                        sources: [["pr-42", "https://github.com/acme/shop/pull/42"], ["ci", nil]])

      expect(tags.map { |t| [t.label, t.from] }).to eq(
        [["ticket PAY-123", "branch"], ["ticket OPS-7", "messages"], ["link notion.so/team/prd", "messages"],
         ["pr acme/shop#42", "context pr-42"], ["link github.com/acme/shop/pull/42", "context pr-42"]]
      )
    end

    it "takes the number of a pr-<n> source with no PR URL in its hint" do
      tags = described_class.of_session(branch: nil, messages: [], sources: [["pr-7", "a PR"]])

      expect(tags.map { |t| [t.label, t.from] }).to eq([["pr #7", "context pr-7"]])
    end

    it "keeps the first place a tag was found" do
      tags = described_class.of_session(branch: "PAY-1", messages: ["PAY-1 again"], sources: [])

      expect(tags.map { |t| [t.label, t.from] }).to eq([["ticket PAY-1", "branch"]])
    end
  end

  describe ".match" do
    let(:session) do
      described_class.of_session(branch: "fix/pay-9", messages: ["see https://notion.so/a/b"],
                                 sources: [["pr-42", "https://github.com/acme/shop/pull/42"]])
    end

    it "finds a ticket first, then a pr, then a link, and words it both ways" do
      match = described_class.match(note("https://notion.so/a/b PR #42 PAY-9"), session)

      expect([match.reason, match.because]).to eq(["ticket PAY-9 matches (branch)", "ticket PAY-9 matches your branch"])
      expect(described_class.match(note("https://notion.so/a/b PR #42"), session).because)
        .to eq("pr #42 matches your attached context pr-42")
      expect(described_class.match(note("https://notion.so/a/b/"), session).because)
        .to eq("link notion.so/a/b is in your user's messages too")
    end

    it "matches a pr number in another repo only when either side names no repo" do
      expect(described_class.match(note("https://github.com/acme/shop/pull/42"), session)).not_to be_nil
      expect(described_class.match(note("https://github.com/acme/other/pull/42"), session)).to be_nil
    end

    it "is nil when nothing is shared" do
      expect(described_class.match(note("PAY-10 and https://notion.so/a/c"), session)).to be_nil
    end
  end
end
