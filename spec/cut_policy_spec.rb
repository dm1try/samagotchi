# frozen_string_literal: true

require "samagotchi/cut_policy"
require "samagotchi/cancellation_controller"
require "samagotchi/empty_answer_retry"

RSpec.describe Samagotchi::CutPolicy do
  let(:controller) { Samagotchi::CancellationController.new }
  let(:events) { [] }
  let(:conversation) { [{ role: "user", content: "hi" }] }
  let(:cut) { { by: "loop-guard", reason: "its thinking kept repeating itself" } }

  def decide(budget:, cut: self.cut, injected: false)
    described_class.decide(cut: cut, cancel_controller: controller, empty_retry: budget, conversation: conversation,
                           iteration: 2, emit: ->(event) { events << event }, inject: -> { injected },
                           finish_reason: "stopped", thinking_chars: 7)
  end

  it "is :stopped after a Stop, with nothing emitted or injected" do
    controller.cancel!(:user)
    injections = 0

    outcome = described_class.decide(cut: cut.merge(steer: true), cancel_controller: controller,
                                     empty_retry: Samagotchi::EmptyAnswerRetry.new(limit: 1), conversation: conversation,
                                     iteration: 2, emit: ->(event) { events << event }, inject: -> { injections += 1 },
                                     finish_reason: "stopped", thinking_chars: 7)

    expect(outcome).to be_stopped
    expect([events, injections, conversation.size]).to eq([[], 0, 1])
  end

  it "goes on, spending no attempt, when queued input went in" do
    retry_budget = Samagotchi::EmptyAnswerRetry.new(limit: 1)

    expect(decide(budget: retry_budget, injected: true)).to be_again
    expect([events, retry_budget.attempts, conversation.size]).to eq([[], 0, 1])
  end

  it "goes on as is after a steer's cut with nothing queued, under its :steer_cut row" do
    retry_budget = Samagotchi::EmptyAnswerRetry.new(limit: 0)

    expect(decide(cut: { by: "steer", steer: true, source: "chi_send" }, budget: retry_budget)).to be_again
    expect(events).to eq([{ type: :steer_cut, iteration: 2, source: "chi_send" }])
    expect([retry_budget.attempts, conversation.size, controller.cancelled?]).to eq([0, 1, false])
  end

  it "nudges while the budget lasts" do
    retry_budget = Samagotchi::EmptyAnswerRetry.new(limit: 1)

    expect(decide(budget: retry_budget)).to be_again
    expect(events).to eq([{ type: :empty_answer_retry, iteration: 2, attempt: 1, of: 1, finish_reason: "stopped",
                            thinking_chars: 7, stopped_by: "loop-guard" }])
    expect(Samagotchi::TurnNote.retry_nudge?(conversation.last)).to be(true)
    expect(retry_budget.take_sampling!).to be(true)
  end

  it "is :hook past the budget: the spent nudge goes and the turn controller is cancelled with the cut" do
    retry_budget = Samagotchi::EmptyAnswerRetry.new(limit: 1)
    decide(budget: retry_budget)
    events.clear

    outcome = decide(budget: retry_budget)

    expect(outcome).to eq(described_class::HOOK)
    expect(events).to eq([])
    expect(conversation).to eq([{ role: "user", content: "hi" }])
    expect([controller.reason, controller.stopped_by]).to eq([:hook, "loop-guard"])
  end
end
