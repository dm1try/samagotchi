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

  def strategy(name) = described_class.strategy(name)

  def pending_of(pending) = Samagotchi::PendingQuestion.from_file(pending)

  # A Hash here is the question's record (symbol or string keys).
  def refusal(pending, indices, name)
    described_class.refusal(pending_of(pending), indices, strategy: strategy(name))
  end

  def message(reason, pending, name, typed: false)
    described_class.message(reason, pending: pending_of(pending), strategy: strategy(name), typed: typed)
  end

  describe "the strategies" do
    it "lets hard pick deny and answer, standard spend too, soft permit too; never permit_wide" do
      expect(described_class.allowed_effects(strategy("hard"))).to eq(%w[answer deny])
      expect(described_class.allowed_effects(strategy("standard"))).to eq(%w[answer deny spend])
      expect(described_class.allowed_effects(strategy("soft"))).to eq(%w[answer deny spend permit])
    end

    it "takes an unknown name as hard, the strictest" do
      expect(strategy("always")).to eq(strategy("hard"))
      expect(strategy(nil)).to eq(strategy("hard"))
    end

    it "reads guardrails.parent_answers from config.yml only: soft by default, an invalid value hard" do
      env = { "SAMAGOTCHI_GUARDRAILS_PARENT_ANSWERS" => "hard" }
      expect(Samagotchi::Config.resolve("guardrails.parent_answers", file_data: {}, env: env)).to eq("soft")
      file = ->(value) { { "guardrails" => { "parent_answers" => value } } }
      expect(Samagotchi::Config.resolve("guardrails.parent_answers", file_data: file.call("standard"), env: {})).to eq("standard")
      expect(Samagotchi::Config.resolve("guardrails.parent_answers", file_data: file.call("loose"), env: {})).to eq("hard")
    end

    it "names the new key for the two it replaced, in the unknown-key warning" do
      problems = Samagotchi::Config.validate_yaml_sections({ "guardrails" => { "parent_approvals" => "once" },
                                                             "turn" => { "parent_continue" => false } })
      expect(problems).to contain_exactly(include("'guardrails.parent_approvals': replaced by 'guardrails.parent_answers'"),
                                          include("'turn.parent_continue': replaced by 'guardrails.parent_answers'"))
    end
  end

  describe "an approval" do
    it "lets a deny through whatever the setting: the Deny option, no option (text alone)" do
      %w[hard standard soft].each do |name|
        expect(refusal(approval, [3], name)).to be_nil
        expect(refusal(approval, [], name)).to be_nil
      end
    end

    it "refuses every allow under hard and standard, and all but the once scope under soft" do
      %w[hard standard].each do |name|
        expect(refusal(approval, [0], name)).to eq(:permit)
        [1, 2].each { |index| expect(refusal(approval, [index], name)).to eq(:permit_wide) }
      end
      expect(refusal(approval, [0], "soft")).to be_nil
      [1, 2].each { |index| expect(refusal(approval, [index], "soft")).to eq(:permit_wide) }
    end

    it "checks the scope by index, never by label" do
      relabeled = approval.merge(options: ["Allow once", "Allow once", "Allow once", "Deny"])
      expect(refusal(relabeled, [1], "soft")).to eq(:permit_wide)
      no_once = approval.merge(options: ["Allow once", "Deny"], approval: { scopes: %w[session] })
      expect(refusal(no_once, [0], "soft")).to eq(:permit_wide)
    end

    it "refuses a mix of deny and allow (a multi-select answer), and any unknown strategy as hard" do
      expect(refusal(approval, [3, 0], "standard")).to eq(:permit)
      expect(refusal(approval, [3, 1], "soft")).to eq(:permit_wide)
      expect(refusal(approval, [0], "always")).to eq(:permit)
      expect(refusal(approval, [0], nil)).to eq(:permit)
    end

    it "fails closed when the scopes are missing, empty or malformed: only the last option, Deny, passes" do
      [nil, [], "once", [nil], [1], %w[once session rule extra]].each do |scopes|
        pending = approval.merge(approval: { tool: "execute", scopes: scopes })
        [0, 1, 2].each do |index|
          expect(refusal(pending, [index], "soft")).to eq(:permit_wide), "scopes #{scopes.inspect}, option #{index}"
        end
        expect(refusal(pending, [3], "soft")).to be_nil
      end
      expect(refusal(approval.except(:approval), [0], "soft")).to eq(:permit_wide)
      expect(refusal(approval.merge(approval: "x"), [0], "standard")).to eq(:permit_wide)
    end

    it "treats a last option that isn't Deny, or an index it can't place, as an allow" do
      pending = approval.merge(options: ["Allow once", "Allow always"], approval: {})
      expect(refusal(pending, [1], "soft")).to eq(:permit_wide)
      expect(refusal(approval, [nil], "soft")).to eq(:permit_wide)
      expect(refusal(approval, [9], "standard")).to eq(:permit_wide)
    end

    it "reads string keys (a session file) and an approval without a kind" do
      pending = { "kind" => "approval", "options" => approval[:options], "approval" => { "scopes" => %w[once session rule] } }
      expect(refusal(pending, [0], "soft")).to be_nil
      expect(refusal(pending, [1], "soft")).to eq(:permit_wide)
      expect(refusal(approval.except(:kind), [1], "standard")).to eq(:permit_wide)
    end

    it "reads the tags the asker set over its scopes" do
      tagged = approval.merge(effects: %w[permit permit permit_wide deny])
      expect(refusal(tagged, [1], "soft")).to be_nil
      expect(refusal(tagged, [2], "soft")).to eq(:permit_wide)
      expect(described_class.effects_of(pending_of(approval))).to eq(%w[permit permit_wide permit_wide deny])
    end

    it "tells the parent to deny and tell its user, never how to allow it" do
      expect(message(:permit, approval, "standard")).to eq(
        "allowing a tool call is up to the user: deny it (--option Deny --text WHY), and tell your user"
      )
      expect(message(:permit_wide, approval, "standard")).to eq(message(:permit, approval, "standard"))
      expect(message(:permit_wide, approval, "soft")).to eq(
        "only Allow once (guardrails.parent_answers: soft) can be given here: " \
        "deny it (--option Deny --text WHY), and tell your user"
      )
      expect(message(:user_only, approval, "soft")).to start_with("this call changes chi's own config")
      expect(message(:permit, approval, "standard", typed: true)).to end_with("deny it (n; WHY), and tell your user")
      %i[permit permit_wide user_only].each { |reason| expect(message(reason, approval, "soft")).not_to include("--attach", "web") }
    end
  end

  describe "an approval that touches chi's own config (user_only)" do
    let(:config) do
      approval.merge(options: ["Allow once", "Allow this call for the session", "Deny"],
                     approval: { tool: "write", scopes: %w[once session], source: "core", rule: "chi-config" })
    end

    it "is refused for any allow, with once or off; a deny still goes" do
      %w[hard standard soft].each { |name| expect(refusal(config, [0], name)).to eq(:user_only) }
      expect(refusal(config, [2], "soft")).to be_nil
      expect(refusal(config, [], "soft")).to be_nil
    end

    it "takes the flag the worker set, and works it out when it is unset (an older worker's question)" do
      expect(refusal(approval.merge(user_only: true), [0], "soft")).to eq(:user_only)
      expect(described_class.user_only?(pending_of(config))).to be(true)
      expect(described_class.user_only?(pending_of(config.merge(user_only: false)))).to be(false)
    end

    it "on a relayed card, the child's flag or this process's own look" do
      relayed = config.merge(user_only: false, relay: { id: "r1" })
      expect(described_class.user_only?(pending_of(relayed))).to be(true)
      expect(described_class.user_only?(pending_of(approval.merge(user_only: true, relay: { id: "r1" })))).to be(true)
    end

    it "says only the user can allow it" do
      expect(message(:user_only, config, "soft")).to include("only the user can allow")
    end
  end

  describe "the step-limit question (kind continue)" do
    it "lets a parent Continue under soft and standard, not hard; Stop always goes" do
      expect(refusal(continue_question, [0], "soft")).to be_nil
      expect(refusal(continue_question, [0], "standard")).to be_nil
      expect(refusal(continue_question, [0], "hard")).to eq(:spend)
      expect(refusal(continue_question, [1], "hard")).to be_nil
      expect(refusal(continue_question, [], "hard")).to be_nil
    end

    it "derives Continue and Stop from the labels when untagged, and reads the tags when set" do
      expect(described_class.effects_of(pending_of(continue_question))).to eq(%w[spend deny])
      tagged = continue_question.merge(effects: %w[spend deny])
      expect(refusal(tagged, [0], "hard")).to eq(:spend)
    end

    it "tells the parent to stop it or tell its user" do
      expect(message(:spend, continue_question, "hard")).to eq(
        "a parent agent may only stop this turn here (guardrails.parent_answers: hard): answer Stop " \
        "(--option Stop --text WHY), or tell your user it waits"
      )
    end
  end

  it "has nothing to say about an untagged question that isn't an approval" do
    question = { id: "q1", kind: "hook", options: %w[Yes No] }
    expect(refusal(question, [0], "hard")).to be_nil
    expect(refusal(question.except(:kind), [0], "standard")).to be_nil
    expect(described_class.effects_of(pending_of(question))).to eq(%w[answer answer])
  end

  it "fails closed on an unknown tag" do
    question = { id: "q1", kind: "hook", options: %w[Yes No], effects: %w[launch answer] }
    expect(refusal(question, [0], "soft")).to eq(:permit_wide)
    expect(refusal(question, [1], "standard")).to be_nil
  end

  it "lists the options a parent may pick" do
    soft = strategy("soft")
    expect(described_class.allowed_options(pending_of(approval), strategy: soft)).to eq(["Allow once", "Deny"])
    expect(described_class.allowed_options(pending_of(approval), strategy: strategy("standard"))).to eq(["Deny"])
    expect(described_class.allowed_options(pending_of(approval.merge(user_only: true)), strategy: soft)).to eq(["Deny"])
    expect(described_class.allowed_options(pending_of(continue_question), strategy: strategy("hard")))
      .to eq(["Stop"])
  end

  # P3: a session's own parent_answers may only tighten config.yml's.
  describe "a session's own level (tighten-only)" do
    before { allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers") { @config || "soft" } }

    it "picks the stricter of two by name; a tie keeps the first" do
      %w[hard standard soft].product(%w[hard standard soft]).each do |a, b|
        expected = [a, b].min_by { |name| described_class::ORDER.index(name) }
        expect(described_class.stricter(strategy(a), strategy(b)).name).to eq(expected)
      end
      session_hard = strategy("hard").with(origin: :session)
      expect(described_class.stricter(strategy("hard"), session_hard)).to equal(strategy("hard"))
    end

    it "tells a set value that isn't a level from none and the levels" do
      expect([nil, "", "default", " Soft ", "hard"].map { |v| described_class.unknown_level?(v) }).to all(be(false))
      expect(%w[sofft loose].map { |v| described_class.unknown_level?(v) }).to all(be(true))
    end

    it "reads a session value: nil unset, a level, anything else hard" do
      expect(described_class.session_level(nil)).to be_nil
      expect(described_class.session_level("")).to be_nil
      expect(described_class.session_level("default")).to be_nil
      expect(described_class.session_level("standard")).to eq("standard")
      expect(described_class.session_level(" Soft ")).to eq("soft")
      expect(described_class.session_level("loose")).to eq("hard")
    end

    it "is config's own strategy object with no session value, a tie or a looser one" do
      @config = "standard"
      expect(described_class.effective(nil)).to equal(described_class.current)
      expect(described_class.current).to eq(described_class.effective(nil))
      expect(described_class.effective("standard")).to equal(described_class.current)
      expect(described_class.effective("soft")).to equal(described_class.current)
      expect(described_class.effective("soft").label).to eq("guardrails.parent_answers: standard")
    end

    it "is the session's when stricter, labelled as the session's" do
      @config = "soft"
      effective = described_class.effective("hard")
      expect(effective.name).to eq("hard")
      expect(effective.allowed).to eq(%w[answer deny])
      expect(effective.label).to eq("parent_answers: hard (this session)")
      expect(described_class.effective("loose").name).to eq("hard")
      expect(described_class::STRATEGIES["hard"].origin).to eq(:config)
    end

    it "reads a session's value (for_session); none is config's" do
      @config = "soft"
      session = Struct.new(:parent_answers).new("standard")
      expect(described_class.for_session(session).name).to eq("standard")
      expect(described_class.for_session(nil)).to equal(described_class.current)
    end

    it "tells a loosening of a session's value: unset is the loosest, an invalid value hard" do
      expect(described_class.looser?("hard", "standard")).to be(true)
      expect(described_class.looser?("soft", nil)).to be(true)
      expect(described_class.looser?("standard", nil)).to be(true)
      expect(described_class.looser?(nil, "soft")).to be(false)
      expect(described_class.looser?(nil, nil)).to be(false)
      expect(described_class.looser?("soft", "hard")).to be(false)
      expect(described_class.looser?("standard", "standard")).to be(false)
      expect(described_class.looser?("loose", "standard")).to be(true)
      expect(described_class.looser?("loose", "hard")).to be(false)
    end
  end
end
