# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/web/push/attention"

# spec/fixtures/attention_cases.json: the rules a push and the tab's
# notification share (notify.test.js and push.test.js run the same rows).
RSpec.describe "Web::Push::Attention on the shared attention cases" do
  cases = JSON.parse(File.read(File.expand_path("../../fixtures/attention_cases.json", __dir__)))
  attention = Samagotchi::Web::Push::Attention

  # The hub's summary as SessionSummary.build makes it: symbol keys at the
  # top and in pending_question / pending_card, string keys in last_turn.
  summary = lambda do |json|
    next nil if json.nil?

    json.to_h do |name, value|
      value = value.transform_keys(&:to_sym) if %w[pending_question pending_card].include?(name) && value.is_a?(Hash)
      [name.to_sym, value]
    end
  end

  cases.fetch("attention").each do |row|
    it "#{row["name"]}: Attention.for and .closed_keys" do
      prev = summary.call(row["prev"])
      nxt = summary.call(row["next"])
      event = attention.for(prev, nxt)
      got = event && { "reason" => event.reason, "key" => event.key, "hold_ms" => event.hold && (event.hold * 1000).round }
      expect(got).to eq(row["attention"])
      expect(event.session_id).to eq(nxt[:id]) if event
      expect(attention.closed_keys(prev, nxt)).to eq(row["closed"])
    end
  end

  cases.fetch("open_keys").each do |row|
    it "#{row["name"]}: Attention.open_keys" do
      by_id = row["by_id"].transform_values { |json| summary.call(json) }
      expect(attention.open_keys(by_id)).to eq(row["open"])
    end
  end
end
