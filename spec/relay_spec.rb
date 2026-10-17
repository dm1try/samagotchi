# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/relay"
require "samagotchi/session"
require "samagotchi/guardrails/parent_approvals"

RSpec.describe Samagotchi::Relay do
  let(:tmpdir) { Dir.mktmpdir("relay") }
  let(:child) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w", parent_id: "p" * 36).tap do |s|
      s.last_prompt = "fix the flaky spec in spec/foo_spec.rb and run it until it passes ten times in a row please"
      s.save(state_dir: tmpdir)
    end
  end
  let(:short) { child.id[0, 8] }
  let(:pending) do
    { id: "q-1", status: "pending", kind: "approval", multi_select: false, allow_freeform: true,
      header: "Approve tool call?",
      question: "execute: git push origin main\n  in /w (repo w, branch main)\n  why: publishes (rule git-push, bundle guardrails)",
      options: ["Allow once", "Allow this call for the session", "Allow this call in this repo", "Deny"],
      approval: { tool: "execute", command: "git push origin main", rule: "git-push", source: "bundle guardrails",
                  scopes: %w[once session repo], preview: { added: 1, removed: 0, diff: "+x" } } }
  end

  after { FileUtils.rm_rf(tmpdir) }

  # A question as Session.load gives it back: a PendingQuestion, nested
  # keys strings.
  def as_saved(hash) = Samagotchi::PendingQuestion.from_file(JSON.parse(JSON.generate(hash)))

  # The card's fields as the parent's pending question.
  def as_pending(card) = Samagotchi::PendingQuestion.new(**card)

  it "reopens the child's approval with the same facts, the delegate named above its text" do
    card = described_class.card(child, as_saved(pending), relay_id: "r-1")

    expect(card[:kind]).to eq("approval")
    expect(card[:approval]).to eq(pending[:approval])
    expect(card[:approval][:preview]).to eq(added: 1, removed: 0, diff: "+x")
    expect(card[:header]).to eq("Approve delegate #{short}'s tool call?")
    expect(card[:question]).to eq(
      "delegate #{short} (\"fix the flaky spec in spec/foo_spec.rb and run it until it passes ten times in …\") asks:\n  " \
      "execute: git push origin main\n    in /w (repo w, branch main)\n    why: publishes (rule git-push, bundle guardrails)"
    )
    expect(card[:relay]).to include(id: "r-1", child_id: child.id, child_short: short, child_question_id: "q-1",
                                    chain: [short], more: 0)
    expect(card[:relay][:task]).to start_with("fix the flaky spec")
    expect(card).to include(multi_select: false, allow_freeform: true)
  end

  it "relabels the session scope for the child's session, by index; once, repo and Deny keep theirs" do
    card = described_class.card(child, as_saved(pending), relay_id: "r-1")
    expect(card[:options]).to eq(["Allow once", "Allow this call for delegate #{short}'s session",
                                  "Allow this call in this repo", "Deny"])
    # ParentApprovals reads it as it reads the child's: index 0 is once, the last denies.
    expect(Samagotchi::Guardrails::ParentApprovals.refusal(as_pending(card), [0], setting: "once")).to be_nil
    expect(Samagotchi::Guardrails::ParentApprovals.refusal(as_pending(card), [1], setting: "once")).to eq(:once_only)
    expect(Samagotchi::Guardrails::ParentApprovals.refusal(as_pending(card), [3], setting: "off")).to be_nil
  end

  it "stays protected when the child's call writes chi's config" do
    config = pending.merge(approval: pending[:approval].merge(rule: "chi-config"))
    card = described_class.card(child, as_saved(config), relay_id: "r-1")
    expect(Samagotchi::Guardrails::ParentApprovals.protected?(as_pending(card))).to be(true)
    expect(Samagotchi::Guardrails::ParentApprovals.refusal(as_pending(card), [0], setting: "once")).to eq(:protected)
  end

  it "lets the parent add a reason unless the child's question said no (an unset allow_freeform reads as true)" do
    expect(described_class.card(child, as_saved(pending.except(:allow_freeform)), relay_id: "r")[:allow_freeform]).to be(true)
    expect(described_class.card(child, as_saved(pending.merge(allow_freeform: false)), relay_id: "r")[:allow_freeform]).to be(false)
  end

  it "says how many more delegates wait" do
    expect(described_class.card(child, as_saved(pending), relay_id: "r", more: 1)[:header]).to end_with("(+1 more delegate waiting)")
    expect(described_class.card(child, as_saved(pending), relay_id: "r", more: 2)[:header]).to end_with("(+2 more delegates waiting)")
  end

  it "relays a relay card one hop further: the chain grows, the grandchild's own text and task stay" do
    grandchild_card = described_class.card(child, as_saved(pending), relay_id: "r-1")
    middle = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w").tap do |s|
      s.last_prompt = "the middle task"
    end
    from_middle = as_saved(grandchild_card.merge(id: "q-2", status: "pending"))
    card = described_class.card(middle, from_middle, relay_id: "r-2")

    m = middle.id[0, 8]
    expect(card[:relay]).to include(chain: [short, m], child_id: middle.id, child_question_id: "q-2")
    expect(card[:question]).to start_with("delegate #{m} → #{short} (\"fix the flaky spec")
    expect(card[:question]).to include("\n  execute: git push origin main\n")
    expect(card[:options][1]).to eq("Allow this call for delegate #{m} → #{short}'s session")
    expect(card[:approval]).to eq(pending[:approval])
  end
end
