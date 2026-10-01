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

  describe "one turn's budget" do
    let(:events) { [] }
    let(:emit) { ->(event) { events << event } }
    let(:conversation) { [{ role: "user", content: "hi" }] }
    let(:note) { Samagotchi::TurnNote.empty_retry }

    it "retries while attempts are left and the turn isn't cancelled" do
      retry_budget = described_class.new(limit: 1)

      expect(retry_budget).to be_left
      expect(retry_budget.retry_empty?(iteration: 1, cancelled: true)).to be(false)
      expect(retry_budget.retry_empty?(iteration: 1, cancelled: false)).to be(true)
      retry_budget.nudge!(conversation, note, emit: emit, iteration: 1)
      expect(retry_budget).not_to be_left
      expect(retry_budget.retry_empty?(iteration: 2, cancelled: false)).to be(false)
      expect(described_class.new(limit: 0).retry_empty?(iteration: 1, cancelled: false)).to be(false)
    end

    it "doesn't retry a length stop with the context full, and logs why" do
      retry_budget = described_class.new(limit: 1)
      allow(Samagotchi::Log).to receive(:info)

      expect(retry_budget.retry_empty?(iteration: 2, cancelled: false, finish_reason: "length",
                                       used_tokens: 950, window_tokens: 1000)).to be(false)
      expect(Samagotchi::Log).to have_received(:info).with(:turn, "empty_answer_not_retried", iteration: 2, why: "context full")
      expect(retry_budget.retry_empty?(iteration: 2, cancelled: false, finish_reason: "length",
                                       used_tokens: 100, window_tokens: 1000)).to be(true)
      expect(retry_budget.retry_empty?(iteration: 2, cancelled: false, finish_reason: "stop",
                                       used_tokens: 950, window_tokens: 1000)).to be(true)
      expect(retry_budget.retry_empty?(iteration: 2, cancelled: false, finish_reason: "length")).to be(true)
    end

    it "nudges: counts the attempt, emits it, appends the note" do
      retry_budget = described_class.new(limit: 2)

      expect(retry_budget).not_to be_used
      expect(retry_budget.nudge!(conversation, note, emit: emit, iteration: 3, thinking_chars: 7)).to be(true)

      expect(retry_budget).to be_used
      expect(events).to eq([{ type: :empty_answer_retry, iteration: 3, attempt: 1, of: 2, thinking_chars: 7 }])
      expect(conversation.last).to eq(note)
    end

    it "asks the next request, once, at the retry sampling" do
      retry_budget = described_class.new(limit: 1)

      expect(retry_budget.request_sampling({ top_p: 0.9 })).to eq(top_p: 0.9)
      retry_budget.nudge!(conversation, note, emit: emit, iteration: 1)
      expect(retry_budget.request_sampling({ top_p: 0.9 })).to eq(top_p: 0.9, temperature: 0.6)
      expect(retry_budget.request_sampling({ top_p: 0.9 })).to eq(top_p: 0.9)
    end

    it "takes the retry sampling once, for a loop that builds its own options" do
      retry_budget = described_class.new(limit: 1)
      retry_budget.nudge!(conversation, note, emit: emit, iteration: 1)

      expect(retry_budget.take_sampling!).to be(true)
      expect(retry_budget.take_sampling!).to be(false)
    end

    it "drops the last spent nudge" do
      other = Samagotchi::TurnNote.cut_retry("loop-guard", "")
      conversation.push(other, { role: "model", content: "x" }, note)

      described_class.new(limit: 1).drop_nudge!(conversation)

      expect(conversation).to eq([{ role: "user", content: "hi" }, other, { role: "model", content: "x" }])
    end

    it "reads its limit from retry.empty_answer by default" do
      ENV["SAMAGOTCHI_RETRY_EMPTY_ANSWER"] = "2"
      expect(described_class.new.limit).to eq(2)
    ensure
      ENV.delete("SAMAGOTCHI_RETRY_EMPTY_ANSWER")
    end
  end

  it "nudges with a hidden turn note" do
    expect(Samagotchi::TurnNote.empty_retry).to eq(
      role: "system", kind: "turn_note", retry_nudge: true,
      content: "[SYSTEM: your last reply had no visible answer. Answer the user's last message now, briefly.]"
    )
  end
end
