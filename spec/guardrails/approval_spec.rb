# frozen_string_literal: true

require "tmpdir"
require "samagotchi/guardrails"

RSpec.describe Samagotchi::Guardrails::Approval do
  let(:dir) { File.realpath(Dir.mktmpdir("guard-appr")) }
  let(:context) { Samagotchi::Guardrails::Context.new(cwd: dir) }
  let(:call) { { name: "execute", content: "git push origin main" } }

  after { FileUtils.rm_rf(dir) }

  def ask(scopes: nil, rule: "git-push", source: "bundle guardrails", c: call)
    v = Samagotchi::Guardrails::Verdict.new(call: c)
    v.ask!("git push publishes commits", scopes: scopes, rule: rule, source: source)
    v.context = context
    v.targets = Samagotchi::Guardrails::Targets.for(c, context)
    v
  end

  describe ".payload" do
    it "says everything in plain text, outside a repo" do
      payload = described_class.payload(ask)
      expect(payload[:question]).to eq(
        "execute: git push origin main\n  in #{dir} (not in a repo)\n" \
        "  why: git push publishes commits (rule git-push, bundle guardrails)"
      )
      expect(payload[:options]).to eq(["Allow once", "Allow this call for the session", "Allow this call in this directory",
                                       "Allow rule git-push in this directory", "Deny"])
      expect(payload).to include(kind: "approval", header: "Approve tool call?", allow_freeform: true, multi_select: false)
    end

    it "names the repo and branch, and carries the structured approval" do
      system("git", "-C", dir, "init", "-q", "-b", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "x",
             out: File::NULL, err: File::NULL)
      payload = described_class.payload(ask(scopes: %w[once repo]))
      expect(payload[:question]).to include("  in #{dir} (repo #{File.basename(dir)}, branch main)")
      expect(payload[:options]).to eq(["Allow once", "Allow this call in this repo", "Deny"])
      expect(payload[:approval]).to eq(tool: "execute", command: "git push origin main", cwd: dir, repo_root: dir,
                                       branch: "main", rule: "git-push", source: "bundle guardrails",
                                       reason: "git push publishes commits", scopes: %w[once repo])
    end

    it "lists paths for a file tool, and offers no rule scope without a rule" do
      payload = described_class.payload(ask(rule: nil, source: nil, c: { name: "write", path: "a.txt", content: "x" }))
      expect(payload[:question]).to start_with("write: #{dir}/a.txt\n")
      expect(payload[:question]).to end_with("(hook)")
      expect(payload[:approval][:paths]).to eq(["#{dir}/a.txt"])
      expect(payload[:approval][:scopes]).to eq(%w[once session repo])
    end

    it "keeps wire tokens in a command verbatim" do
      payload = described_class.payload(ask(c: { name: "execute", content: "echo '<|x|>'" }))
      expect(payload[:question]).to start_with("execute: echo '<|x|>'")
    end
  end

  describe ".settle" do
    let(:scopes) { %w[once session] }

    it "allows with the scope at the picked index" do
      v = described_class.settle(ask, { selected_indices: [1], selected: ["x"] }, scopes)
      expect([v.decision, v.scope, v.decided_by]).to eq([:allow, "session", "user"])
    end

    it "denies on Deny, with the user's reason when given" do
      v = described_class.settle(ask, { selected_indices: [2], freeform: "use a PR" }, scopes)
      expect(v).to be_deny
      expect(v.deny_text).to include('The user declined: "use a PR".')
    end

    it "denies a freeform-only answer with that reason" do
      v = described_class.settle(ask, { selected_indices: [], freeform: "not now" }, scopes)
      expect(v.deny_text).to include('The user declined: "not now".')
    end

    it "denies a cancelled or unanswered question" do
      v = described_class.settle(ask, { error: "cancelled" }, scopes)
      expect(v.deny_text).to eq("denied by guardrail (rule git-push, bundle guardrails): git push publishes commits. " \
                                "The approval was cancelled. Do not retry it or reach the same result another way; " \
                                "ask the user how to proceed.")
      expect(described_class.settle(ask, "legacy text", scopes)).to be_deny
    end
  end
end
