# frozen_string_literal: true

require "tmpdir"
require "yaml"
require "samagotchi/guardrails"

# The coordinator bundle's git-merge rule (guardrails/merge.yml), against the
# real Rules and Targets: what it asks about and what it leaves alone. Here and
# not in the bundle's own spec: a bundle's spec reaches only the stable names.
RSpec.describe "The coordinator bundle's git-merge rule" do
  let(:dir) { File.expand_path("../../lib/samagotchi/bundles/coordinator", __dir__) }
  let(:rule_doc) { YAML.safe_load_file(File.join(dir, "guardrails", "merge.yml")) }
  let(:rules) { Samagotchi::Guardrails::Rules.new(Samagotchi::Guardrails::Rules.parse(rule_doc["rules"], source: "bundle coordinator")) }
  let(:repo) { File.realpath(Dir.mktmpdir("merge-rule")).tap { |d| system("git", "-C", d, "init", "-q") } }

  after { FileUtils.rm_rf(repo) }

  def verdict(command)
    v = Samagotchi::Guardrails::Verdict.new(call: { name: "execute", content: command })
    v.context = Samagotchi::Guardrails::Context.new(cwd: repo, git: Samagotchi::Guardrails::GitInfo.new)
    v.targets = Samagotchi::Guardrails::Targets.for(v.call, v.context)
    rules.check(v)
  end

  it "asks in every mode, naming the rule, with once and the rule's own grant" do
    v = verdict("git merge --ff-only feat/x")
    expect([v.decision, v.rule, v.source, v.scopes]).to eq([:ask, "git-merge", "bundle coordinator", %w[once rule]])
    expect(rules.rules.map(&:modes)).to eq([nil])
    expect(v.reason).to include("covers every later merge in this repo")
  end

  ["git merge x", "git merge", "cd a && git merge x", "git -C ../a merge x", "git --git-dir=/a/.git merge x", "git -c a=b merge x",
   "sh -c 'git merge x'", "git merge --abort && git merge y", "git merge x; echo done", "git merge x | tee /tmp/o", "(git merge x)",
   'git merge --ff-only x -m "stop --abort now"', "git merge x # --continue", "git merge --no-ff x --quit-note"].each do |command|
    it("asks for: #{command}") { expect(verdict(command)).to be_ask }
  end

  ["git merge-base --is-ancestor main x", "git merge-tree a b", "git merge-file a b c", "git mergetool", "git merge --abort", "git merge --continue",
   "git merge --quit", "git pull", "rg 'git merge x'", "git log --grep merge", "git log --oneline -3 main", "chi guardrails rule git-merge",
   "git worktree add ../git-merge -b feat/git-merge"].each do |command|
    it("stays silent for: #{command}") { expect(verdict(command)).to be_allow }
  end
end
