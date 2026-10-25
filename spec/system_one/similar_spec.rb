# frozen_string_literal: true

require "securerandom"
require "samagotchi/system_one"

# The few-shot examples an ask gets with its own facts: the earlier asks the
# user actually answered, the most alike first — same rule and same repo,
# then the same rule, then whatever shares the most words with this call
# (docs/guardrails.md, "System 1"). No embeddings: a token overlap, and ties
# broken by the newest ask so the order is always the same for the same log.
RSpec.describe Samagotchi::SystemOne::Similar do
  # A line as SystemOne::Log#entries returns it: the judgment, joined with
  # the user's last answer (nil when they never answered).
  def ask(rule: "git-push", repo: "samagotchi", call: "git push origin main", answer: "allow_once")
    { "kind" => "judgment", "id" => SecureRandom.uuid, "rule" => rule, "repo_name" => repo,
      "call" => call, "call_digest" => "d" * 64, "p" => 0.9, "answer" => answer }
  end

  def select(entries, rule: "git-push", repo: "samagotchi", text: "git push origin main")
    described_class.select(entries: entries, rule: rule, repo_name: repo, call_text: text)
  end

  it "takes at most five, and nothing when no ask was answered" do
    expect(select(Array.new(8) { ask }).size).to eq(5)
    expect(select(Array.new(8) { ask(answer: nil) })).to eq([])
    expect(select([ask(answer: "none"), ask(answer: "should_have_asked")]).map { |example| example["answer"] })
      .to eq(["should_have_asked"])
    expect(select([])).to eq([])
    expect(select(nil)).to eq([])
  end

  it "skips an ask with no label and one labelled none" do
    entries = [ask(answer: nil), ask(answer: "none"), ask(answer: "deny", call: "git push other")]
    expect(select(entries).map { |example| example["answer"] }).to eq(["deny"])
  end

  it "skips a judgment whose rule is missing" do
    expect(select([{ "kind" => "judgment", "call" => "git push", "answer" => "allow_once" }])).to eq([])
  end

  it "puts the same rule in the same repo first, then the same rule, then any other rule" do
    entries = [
      ask(rule: "git-push", repo: "other-repo", call: "git push origin main"),
      ask(rule: "shell-touches-chi", repo: "samagotchi", call: "git push origin main"),
      ask(rule: "git-push", repo: "samagotchi", call: "git push origin feature"),
      ask(rule: "git-rebase", repo: "samagotchi", call: "git push origin main")
    ]
    ranked = select(entries).map { |example| [example["rule"], example["repo"]] }
    expect(ranked).to eq([%w[git-push samagotchi], %w[git-push other-repo],
                          %w[git-rebase samagotchi], %w[shell-touches-chi samagotchi]])
  end

  it "ranks inside a tier by how many words the logged call shares with this one" do
    entries = [
      ask(call: "git push origin feature"),
      ask(call: "git push"),
      ask(call: "echo unrelated things")
    ]
    expect(select(entries).map { |example| example["call"] })
      .to eq(["git push origin feature", "git push", "echo unrelated things"])
  end

  it "breaks a tie with the newest ask first" do
    entries = [ask(call: "git push a"), ask(call: "git push b"), ask(call: "git push c")] # oldest first
    expect(select(entries, text: "git push").map { |example| example["call"] })
      .to eq(["git push c", "git push b", "git push a"])
  end

  it "is the same order every time for the same log" do
    entries = Array.new(12) { |i| ask(rule: i.even? ? "git-push" : "git-rebase", call: "git push branch#{i}") }
    first = select(entries)
    expect(select(entries)).to eq(first)
  end

  it "carries the rule, the repo, the call as logged and the answer" do
    example = select([ask(rule: "git-push", repo: "samagotchi", call: "git push origin main", answer: "allow_wide")]).first
    expect(example).to eq({ "rule" => "git-push", "repo" => "samagotchi", "call" => "git push origin main",
                            "answer" => "allow_wide" })
  end

  it "leaves out a repo the ask had no repo for" do
    expect(select([ask(repo: nil)]).first).to eq({ "rule" => "git-push", "call" => "git push origin main",
                                                   "answer" => "allow_once" })
  end

  it "ranks the same rule in this repo above the same rule in another, or in none" do
    entries = [ask(repo: "other-repo"), ask(repo: nil), ask(repo: "samagotchi")]
    expect(select(entries).map { |example| example["repo"] }).to eq(["samagotchi", nil, "other-repo"])
  end
end
