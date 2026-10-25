# frozen_string_literal: true

require "samagotchi/system_one"

# The state System 1 is asked about: the ask's own facts, the memory it
# touches when it is a memory ask, and the few earlier decisions the user
# answered that look like this one (docs/guardrails.md, "System 1"). A field
# the ask did not give is left out; the examples are left out when the log
# has none.
RSpec.describe Samagotchi::SystemOne::ApprovalQuestion do
  def approval(rule: "git-push", source: "bundle guardrails", reason: "pushes commits", tool: "execute",
               command: "git push origin main", paths: nil, preview: nil, cwd: "/repo", repo_name: "samagotchi",
               branch: "main", memory: nil)
    { rule: rule, source: source, reason: reason, tool: tool, command: command, paths: paths, preview: preview,
      cwd: cwd, repo_name: repo_name, branch: branch, memory: memory }.compact
  end

  def ask(rule: "git-push", repo: "samagotchi", call: "git push origin main", answer: "allow_once")
    { "kind" => "judgment", "rule" => rule, "repo_name" => repo, "call" => call, "answer" => answer }
  end

  it "carries the rule, the reason, the call and where it runs" do
    state = described_class.state(approval)
    expect(state).to eq({ "rule" => "git-push", "source" => "bundle guardrails", "reason" => "pushes commits",
                          "tool" => "execute", "command" => "git push origin main", "cwd" => "/repo",
                          "repo_name" => "samagotchi", "branch" => "main" })
  end

  it "adds the examples the log offers, ranked by Similar" do
    entries = [ask(rule: "git-rebase", call: "git push origin main"), ask(rule: "git-push", call: "git push origin feature")]
    state = described_class.state(approval, entries: entries)
    expect(state["examples"].map { |example| example["rule"] }).to eq(%w[git-push git-rebase])
    expect(state["examples"].first).to eq({ "rule" => "git-push", "repo" => "samagotchi",
                                            "call" => "git push origin feature", "answer" => "allow_once" })
  end

  it "leaves examples out when the log has none: no entries, or nothing labelled" do
    expect(described_class.state(approval)).not_to have_key("examples")
    expect(described_class.state(approval, entries: [ask(answer: nil), ask(answer: "none")])).not_to have_key("examples")
    expect(described_class.state(approval, entries: [])).not_to have_key("examples")
  end

  it "measures an example's call against the paths or arguments when the ask has no command" do
    write = approval(tool: "write", command: nil, paths: ["/repo/notes.md"], reason: "writes outside the repo")
    entries = [ask(call: "echo a"), ask(rule: "git-push", call: "/repo/notes.md")]
    state = described_class.state(write, entries: entries)
    expect(state["examples"].map { |example| example["call"] }).to eq(["/repo/notes.md", "echo a"])
  end

  it "names the memory a memory ask touches: its entry, its scope, and its description" do
    memory = { name: "git_workspace_rule", scope: "project", description: "Worktree for EVERYTHING" }
    state = described_class.state(approval(tool: "memory_write", command: nil, paths: ["/mem/git_workspace_rule.md"],
                                           reason: "removes a memory", rule: "memory-remove", memory: memory))
    expect(state["memory"]).to eq(memory.transform_keys(&:to_s))
  end

  it "keeps a memory ask with no description: the entry and its scope still reach the judge" do
    state = described_class.state(approval(tool: "memory_write", command: nil, paths: ["/mem/notes.md"],
                                           rule: "memory-remove", memory: { name: "notes", scope: "system", description: "" }))
    expect(state["memory"]).to eq({ "name" => "notes", "scope" => "system" })
  end

  it "has no memory key for a call that is not about a memory" do
    expect(described_class.state(approval)).not_to have_key("memory")
  end

  it "says in the instruction what the examples are" do
    expect(described_class::INSTRUCTIONS).to include("earlier decisions")
    expect(described_class.question.instructions).to eq(described_class::INSTRUCTIONS)
  end
end
