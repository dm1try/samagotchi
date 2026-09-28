# frozen_string_literal: true

require "samagotchi/empty_answer_retry"

RSpec.describe Samagotchi::EmptyAnswerRetry do
  def limit_with(value)
    original = ENV.fetch("SAMAGOTCHI_RETRY_EMPTY_ANSWER", nil)
    value.nil? ? ENV.delete("SAMAGOTCHI_RETRY_EMPTY_ANSWER") : ENV["SAMAGOTCHI_RETRY_EMPTY_ANSWER"] = value
    described_class.limit
  ensure
    original.nil? ? ENV.delete("SAMAGOTCHI_RETRY_EMPTY_ANSWER") : ENV["SAMAGOTCHI_RETRY_EMPTY_ANSWER"] = original
  end

  it "is 1 by default, 0 turns it off, and it is capped at 3" do
    expect(limit_with(nil)).to eq(1)
    expect(limit_with("0")).to eq(0)
    expect(limit_with("9")).to eq(3)
    expect(limit_with("-2")).to eq(0)
  end

  it "is read from the config file, with no CLI flag" do
    entry = Samagotchi::Config.find_by_key("retry.empty_answer")

    expect(entry.env_key).to eq("SAMAGOTCHI_RETRY_EMPTY_ANSWER")
    expect(entry).not_to be_cli_exposed
    expect(Samagotchi::Config.resolve("retry.empty_answer", file_data: { "retry" => { "empty_answer" => 2 } }, env: {})).to eq(2)
  end

  it "retries at 0.6 unless a temperature is configured (nil included)" do
    expect(described_class.sampling({})).to eq(temperature: 0.6)
    expect(described_class.sampling(nil)).to eq(temperature: 0.6)
    expect(described_class.sampling({ top_p: 0.9 })).to eq(top_p: 0.9, temperature: 0.6)
    expect(described_class.sampling({ temperature: 0.2 })).to eq(temperature: 0.2)
    expect(described_class.sampling({ temperature: nil })).to eq(temperature: nil)
  end

  it "calls a context at 90 % full" do
    expect(described_class.context_full?(900, 1000)).to be(true)
    expect(described_class.context_full?(899, 1000)).to be(false)
    expect(described_class.context_full?(nil, 1000)).to be(false)
    expect(described_class.context_full?(900, nil)).to be(false)
  end

  it "nudges with a hidden turn note" do
    expect(Samagotchi::TurnNote.empty_retry).to eq(
      role: "system", kind: "turn_note",
      content: "[SYSTEM: your last reply had no visible answer. Answer the user's last message now, briefly.]"
    )
  end
end
