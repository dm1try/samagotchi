# frozen_string_literal: true

require "spec_helper"
require "samagotchi/guardrails/parent_policy"
require "samagotchi/pending_question"

# What a parent agent (chi answer) may answer on a session's question: the
# one check the CLI makes before posting and the worker makes again.
RSpec.describe Samagotchi::Guardrails::ParentPolicy do
  let(:approval) do
    { id: "a1", kind: "approval",
      options: ["Allow once", "Allow this call for the session", "Allow rule spike-ask in this directory", "Deny"],
      approval: { tool: "execute", scopes: %w[once session rule] } }
  end
  let(:continue_question) { { id: "c1", kind: "continue", options: %w[Continue Stop] } }

  def strategy(setting, parent_continue: true)
    described_class.legacy(parent_approvals: setting, parent_continue: parent_continue)
  end

  def pending_of(pending) = Samagotchi::PendingQuestion.from_file(pending)

  # A Hash here is the question's record (symbol or string keys).
  def refusal(pending, indices, setting, parent_continue: true)
    described_class.refusal(pending_of(pending), indices, strategy: strategy(setting, parent_continue: parent_continue))
  end

  def message(reason, pending, setting, parent_continue: true, typed: false)
    described_class.message(reason, pending: pending_of(pending), strategy: strategy(setting, parent_continue: parent_continue),
                                    typed: typed)
  end

  describe "an approval" do
    it "lets a deny through whatever the setting: the Deny option, no option (text alone)" do
      %w[off once].each do |setting|
        expect(refusal(approval, [3], setting)).to be_nil
        expect(refusal(approval, [], setting)).to be_nil
      end
    end

    it "refuses every allow with off, and all but the once scope with once" do
      expect(refusal(approval, [0], "off")).to eq(:permit)
      [1, 2].each { |index| expect(refusal(approval, [index], "off")).to eq(:permit_wide) }
      expect(refusal(approval, [0], "once")).to be_nil
      [1, 2].each { |index| expect(refusal(approval, [index], "once")).to eq(:permit_wide) }
    end

    it "checks the scope by index, never by label" do
      relabeled = approval.merge(options: ["Allow once", "Allow once", "Allow once", "Deny"])
      expect(refusal(relabeled, [1], "once")).to eq(:permit_wide)
      no_once = approval.merge(options: ["Allow once", "Deny"], approval: { scopes: %w[session] })
      expect(refusal(no_once, [0], "once")).to eq(:permit_wide)
    end

    it "refuses a mix of deny and allow (a multi-select answer), and any unknown setting as off" do
      expect(refusal(approval, [3, 0], "off")).to eq(:permit)
      expect(refusal(approval, [3, 1], "once")).to eq(:permit_wide)
      expect(refusal(approval, [0], "always")).to eq(:permit)
      expect(refusal(approval, [0], nil)).to eq(:permit)
    end

    it "fails closed when the scopes are missing, empty or malformed: only the last option, Deny, passes" do
      [nil, [], "once", [nil], [1], %w[once session rule extra]].each do |scopes|
        pending = approval.merge(approval: { tool: "execute", scopes: scopes })
        [0, 1, 2].each do |index|
          expect(refusal(pending, [index], "once")).to eq(:permit_wide), "scopes #{scopes.inspect}, option #{index}"
        end
        expect(refusal(pending, [3], "once")).to be_nil
      end
      expect(refusal(approval.except(:approval), [0], "once")).to eq(:permit_wide)
      expect(refusal(approval.merge(approval: "x"), [0], "off")).to eq(:permit_wide)
    end

    it "treats a last option that isn't Deny, or an index it can't place, as an allow" do
      pending = approval.merge(options: ["Allow once", "Allow always"], approval: {})
      expect(refusal(pending, [1], "once")).to eq(:permit_wide)
      expect(refusal(approval, [nil], "once")).to eq(:permit_wide)
      expect(refusal(approval, [9], "off")).to eq(:permit_wide)
    end

    it "reads string keys (a session file) and an approval without a kind" do
      pending = { "kind" => "approval", "options" => approval[:options], "approval" => { "scopes" => %w[once session rule] } }
      expect(refusal(pending, [0], "once")).to be_nil
      expect(refusal(pending, [1], "once")).to eq(:permit_wide)
      expect(refusal(approval.except(:kind), [1], "off")).to eq(:permit_wide)
    end

    it "reads the tags the asker set over its scopes" do
      tagged = approval.merge(effects: %w[permit permit permit_wide deny])
      expect(refusal(tagged, [1], "once")).to be_nil
      expect(refusal(tagged, [2], "once")).to eq(:permit_wide)
      expect(described_class.effects_of(pending_of(approval))).to eq(%w[permit permit_wide permit_wide deny])
    end

    it "tells the parent to deny and tell its user, never how to allow it" do
      expect(message(:permit, approval, "off")).to eq(
        "allowing a tool call is up to the user: deny it (--option Deny --text WHY), and tell your user"
      )
      expect(message(:permit_wide, approval, "off")).to eq(message(:permit, approval, "off"))
      expect(message(:permit_wide, approval, "once")).to eq(
        "only Allow once (guardrails.parent_approvals: once) can be given here: " \
        "deny it (--option Deny --text WHY), and tell your user"
      )
      expect(message(:user_only, approval, "once")).to start_with("this call changes chi's own config")
      expect(message(:permit, approval, "off", typed: true)).to end_with("deny it (n; WHY), and tell your user")
      %i[permit permit_wide user_only].each { |reason| expect(message(reason, approval, "once")).not_to include("--attach", "web") }
    end
  end

  describe "an approval that touches chi's own config (user_only)" do
    let(:config) do
      approval.merge(options: ["Allow once", "Allow this call for the session", "Deny"],
                     approval: { tool: "write", scopes: %w[once session], source: "core", rule: "chi-config" })
    end

    it "is refused for any allow, with once or off; a deny still goes" do
      %w[off once].each { |setting| expect(refusal(config, [0], setting)).to eq(:user_only) }
      expect(refusal(config, [2], "once")).to be_nil
      expect(refusal(config, [], "once")).to be_nil
    end

    it "takes the flag the worker set, and works it out when it is unset (an older worker's question)" do
      expect(refusal(approval.merge(user_only: true), [0], "once")).to eq(:user_only)
      expect(described_class.user_only?(pending_of(config))).to be(true)
      expect(described_class.user_only?(pending_of(config.merge(user_only: false)))).to be(false)
    end

    it "on a relayed card, the child's flag or this process's own look" do
      relayed = config.merge(user_only: false, relay: { id: "r1" })
      expect(described_class.user_only?(pending_of(relayed))).to be(true)
      expect(described_class.user_only?(pending_of(approval.merge(user_only: true, relay: { id: "r1" })))).to be(true)
    end

    it "says only the user can allow it" do
      expect(message(:user_only, config, "once")).to include("only the user can allow")
    end
  end

  describe "the step-limit question (kind continue)" do
    it "lets a parent Continue unless turn.parent_continue is false; Stop always goes" do
      expect(refusal(continue_question, [0], "off")).to be_nil
      expect(refusal(continue_question, [0], "off", parent_continue: false)).to eq(:spend)
      expect(refusal(continue_question, [1], "off", parent_continue: false)).to be_nil
      expect(refusal(continue_question, [], "off", parent_continue: false)).to be_nil
    end

    it "derives Continue and Stop from the labels when untagged, and reads the tags when set" do
      expect(described_class.effects_of(pending_of(continue_question))).to eq(%w[spend deny])
      tagged = continue_question.merge(effects: %w[spend deny])
      expect(refusal(tagged, [0], "off", parent_continue: false)).to eq(:spend)
    end

    it "tells the parent to stop it or tell its user" do
      expect(message(:spend, continue_question, "off", parent_continue: false)).to eq(
        "a parent agent may only stop this turn here (turn.parent_continue: false): answer Stop " \
        "(--option Stop --text WHY), or tell your user it waits"
      )
    end
  end

  it "has nothing to say about an untagged question that isn't an approval" do
    question = { id: "q1", kind: "hook", options: %w[Yes No] }
    expect(refusal(question, [0], "off", parent_continue: false)).to be_nil
    expect(refusal(question.except(:kind), [0], "off")).to be_nil
    expect(described_class.effects_of(pending_of(question))).to eq(%w[answer answer])
  end

  it "fails closed on an unknown tag" do
    question = { id: "q1", kind: "hook", options: %w[Yes No], effects: %w[launch answer] }
    expect(refusal(question, [0], "once")).to eq(:permit_wide)
    expect(refusal(question, [1], "off")).to be_nil
  end

  it "lists the options a parent may pick" do
    once = strategy("once")
    expect(described_class.allowed_options(pending_of(approval), strategy: once)).to eq(["Allow once", "Deny"])
    expect(described_class.allowed_options(pending_of(approval), strategy: strategy("off"))).to eq(["Deny"])
    expect(described_class.allowed_options(pending_of(approval.merge(user_only: true)), strategy: once)).to eq(["Deny"])
    expect(described_class.allowed_options(pending_of(continue_question), strategy: strategy("off", parent_continue: false)))
      .to eq(["Stop"])
  end
end
