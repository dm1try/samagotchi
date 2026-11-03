# frozen_string_literal: true

require "samagotchi/system_one/record"

# One rule's record: the judgments of that rule joined with their last label,
# exactly as SystemOne::Log#entries returns them. The gate System 1 must pass
# before it answers for the user: enough clean allows at or above the
# threshold, and no false allow among the rule's last 20 labelled asks
# (docs/guardrails.md, "System 1").
RSpec.describe Samagotchi::SystemOne::Record do
  def ask(rule: "git-push", p: 0.9, answer: "allow_once")
    { "kind" => "judgment", "rule" => rule, "p" => p, "answer" => answer }
  end

  def asks(count, **fields)
    Array.new(count) { ask(**fields) }
  end

  def record(list) = described_class.new(list, rule: "git-push")

  describe "by repository" do
    def in_repo(count, repo, **fields) = asks(count, **fields).map { |entry| entry.merge("repo" => repo) }
    def in_a(list) = described_class.new(list, rule: "git-push", repo: "/a/.git")

    it "counts only that repo's lines toward a clean record" do
      expect(in_a(in_repo(5, "/a/.git")).qualifies?(threshold: 0.8, min_record: 5)).to be true
      expect(in_a(in_repo(4, "/a/.git") + in_repo(5, "/b/.git")).qualifies?(threshold: 0.8, min_record: 5)).to be false
    end

    it "counts a line with no repo for nothing" do
      expect(in_a(asks(5)).qualifies?(threshold: 0.8, min_record: 5)).to be false
    end

    it "keeps another repo's false allow out of the window" do
      expect(in_a(in_repo(5, "/a/.git") + in_repo(1, "/b/.git", answer: "deny")).qualifies?(threshold: 0.8, min_record: 5)).to be true
    end

    it "looks at the repo's own window" do
      expect(in_a(in_repo(5, "/a/.git") + in_repo(1, "/a/.git", answer: "deny")).qualifies?(threshold: 0.8, min_record: 5)).to be false
    end

    it "keeps the other rules out, and with no repo counts every line" do
      other = in_repo(5, "/a/.git", rule: "git-rebase")
      expect(in_a(other).entries).to eq([])
      expect(record(in_repo(3, "/a/.git") + in_repo(2, "/b/.git") + asks(1)).entries.size).to eq(6)
    end

    it "reads which rules go by repo from the config: git-merge by default, a list replaces it" do
      expect(described_class.per_repo?("git-merge")).to be true
      expect(described_class.per_repo?("git-push")).to be false
      allow(Samagotchi::Config).to receive(:get).with("guardrails.system_one.repo_rules").and_return("git-push|x")
      expect(described_class.per_repo?("git-merge")).to be false
      expect(described_class.per_repo?("git-push")).to be true
    end
  end

  it "qualifies at exactly min_record clean allows" do
    expect(record(asks(5)).qualifies?(threshold: 0.8, min_record: 5)).to be true
    expect(record(asks(4)).qualifies?(threshold: 0.8, min_record: 5)).to be false
  end

  it "counts a wider allow as clean, and an allow under the threshold as nothing" do
    expect(record(asks(5, answer: "allow_wide")).qualifies?(threshold: 0.8, min_record: 5)).to be true
    expect(record(asks(4) + asks(1, p: 0.8)).qualifies?(threshold: 0.8, min_record: 5)).to be true
    expect(record(asks(4) + asks(1, p: 0.79)).qualifies?(threshold: 0.8, min_record: 5)).to be false
  end

  it "is blocked by a false allow inside the last 20 labelled asks" do
    expect(record(asks(5) + [ask(p: 0.95, answer: "deny")]).qualifies?(threshold: 0.8, min_record: 5)).to be false
    expect(record(asks(5) + [ask(p: 0.95, answer: "should_have_asked")]).qualifies?(threshold: 0.8, min_record: 5)).to be false
    # A deny the judge did not rate highly is not a false allow.
    expect(record(asks(5) + [ask(p: 0.4, answer: "deny")]).qualifies?(threshold: 0.8, min_record: 5)).to be true
  end

  it "lets a false allow older than the last 20 labelled asks through" do
    old = ask(p: 0.95, answer: "deny")
    expect(record([old] + asks(20)).qualifies?(threshold: 0.8, min_record: 5)).to be true
    expect(record([old] + asks(19)).qualifies?(threshold: 0.8, min_record: 5)).to be false
  end

  it "counts asks with no label, no probability or a `none` answer for neither" do
    expect(record(asks(30, answer: nil) + asks(5)).qualifies?(threshold: 0.8, min_record: 5)).to be true
    expect(record(asks(4) + [ask(p: nil, answer: "allow_once")]).qualifies?(threshold: 0.8, min_record: 5)).to be false
    expect(record(asks(5) + [ask(p: 0.9, answer: "none")]).qualifies?(threshold: 0.8, min_record: 5)).to be true
    # The window is the last 20 labelled asks: an unlabelled one takes no slot.
    expect(record(asks(30, answer: nil) + [ask(p: 0.95, answer: "deny")] + asks(5)).qualifies?(threshold: 0.8, min_record: 5)).to be false
  end

  it "ignores other rules' asks" do
    expect(record(asks(5) + asks(10, rule: "chi-config")).qualifies?(threshold: 0.8, min_record: 5)).to be true
    expect(record(asks(10, rule: "chi-config")).qualifies?(threshold: 0.8, min_record: 5)).to be false
  end

  it "summarises the rule's asks for a listing" do
    list = asks(3) + asks(1, answer: "allow_wide") + asks(1, p: 0.95, answer: "deny") +
           asks(1, answer: nil) + asks(1, p: nil, answer: "none") + asks(2, rule: "chi-config")
    expect(record(list).summary).to eq({ rule: "git-push", asks: 7, labelled: 6, allow_once: 3, allow_wide: 1,
                                         deny: 1, should_have_asked: 0, none: 1, no_label: 1, no_p: 1 })
  end
end
