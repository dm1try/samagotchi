# frozen_string_literal: true

require "tmpdir"
require "samagotchi/guardrails"
require "samagotchi/tools/registry"

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

  it "tags each option's effect for a parent's answer: once permits, a wider scope permits wide, Deny denies" do
    payload = described_class.payload(ask(scopes: %w[once session repo]))
    expect(payload[:options].last).to eq("Deny")
    expect(payload[:effects]).to eq(%w[permit permit_wide permit_wide deny])
  end

  describe ".payload with an edit preview" do
    let(:diff) { { text: "@@ -1 +1 @@\n-a\n+b", added: 3, removed: 1, truncated: false, new_file: false } }

    it "puts the preview in approval[:preview] and one change line in the question" do
      payload = described_class.payload(ask, preview: diff)
      expect(payload[:approval][:preview]).to eq(diff)
      expect(payload[:question].lines.last).to eq("  change: +3 \u22121")
      expect(payload[:question]).not_to include("@@")
    end

    it "words each preview kind, with symbol or string keys" do
      text = ->(preview) { described_class.payload(ask, preview: preview)[:question].lines.last }
      expect(text.call(diff.merge(new_file: true, added: 12))).to eq("  change: new file, 12 lines")
      expect(text.call(diff.merge(new_file: true, added: 1))).to eq("  change: new file, 1 line")
      expect(text.call({ error: "old text not found in /x" })).to eq("  change: would fail: old text not found in /x")
      expect(text.call({ skipped: "binary file" })).to eq("  change: not shown (binary file)")
      expect(text.call({ "added" => 2, "removed" => 0 })).to eq("  change: +2 \u22120")
    end

    it "leaves a call without a preview as it was" do
      payload = described_class.payload(ask)
      expect(payload[:approval]).not_to have_key(:preview)
      expect(payload[:question]).not_to include("change:")
    end
  end

  describe ".payload" do
    it "says everything in plain text, outside a repo" do
      payload = described_class.payload(ask)
      expect(payload[:question]).to eq(
        "execute: git push origin main\n  in #{dir} (not in a repo)\n  " \
        "why: git push publishes commits (rule git-push, bundle guardrails)"
      )
      expect(payload[:options]).to eq(["Allow once", "Allow this call for the session", "Allow this call in this directory",
                                       "Allow rule git-push in this directory", "Deny"])
      expect(payload).to include(kind: "approval", header: "Approve tool call?", allow_freeform: true, multi_select: false)
    end

    it "names a participant's turn's ask and offers it once only, even in a scratch session; the owner's unnamed" do
      payload = described_class.payload(ask(scopes: %w[once session repo]), author: "p:p_0123abcd", author_name: "Sam",
                                                                            only: %w[once session])
      expect(payload[:options]).to eq(["Allow once", "Deny"])
      expect(payload[:effects]).to eq(%w[permit deny])
      expect(payload[:header]).to eq("Sam's turn asks: approve tool call?")
      expect(payload[:question].lines.last).to eq("  asked by: Sam's turn (a participant, not you); Allow once only")
      expect(payload[:approval]).to include(author: "p:p_0123abcd", author_name: "Sam", scopes: ["once"],
                                            asked_by: format(described_class::ASKED_BY, "Sam"))
      unnamed = described_class.payload(ask, author: "p:p_0123abcd")
      expect(unnamed[:header]).to eq("p_0123abcd's turn asks: approve tool call?")
      expect(unnamed[:approval]).to include(author: "p:p_0123abcd")
      expect(unnamed[:approval]).not_to have_key(:author_name)
      owner = described_class.payload(ask, author: "owner")
      expect(owner[:approval]).not_to include(:author, :author_name)
      expect(owner[:header]).to eq("Approve tool call?")
    end

    it "shows a plugin tool's arguments when its targets name no command or path, cut" do
      registry = Samagotchi::Tools::Registry.new
      registry.register("mcp_x_echo", schema: { name: "mcp_x_echo" }, handler: ->(*) { "" }, source: "mcp")
      c = { name: "mcp_x_echo", args: { "message" => "hello there", "n" => 3, "flag" => true, "id" => "abc" } }
      v = Samagotchi::Guardrails::Verdict.new(call: c)
      v.ask!("an MCP tool", rule: "mcp-ask", source: "config")
      v.context = context
      v.targets = Samagotchi::Guardrails::Targets.for(c, context, registry: registry)
      expect(described_class.payload(v)[:question].lines.first).to eq("mcp_x_echo: flag=true id=abc message=\"hello there\" n=3\n")
      long = c.merge(args: { "text" => "x" * 400 })
      v.targets = Samagotchi::Guardrails::Targets.for(long, context, registry: registry)
      expect(described_class.payload(v)[:question].lines.first.chomp.length).to eq("mcp_x_echo: ".length + 300)
    end

    it "gives the card a plugin tool's arguments (approval[:args]) only when there is no command or path" do
      registry = Samagotchi::Tools::Registry.new
      registry.register("mcp_x_echo", schema: { name: "mcp_x_echo" }, handler: ->(*) { "" }, source: "mcp")
      c = { name: "mcp_x_echo", args: { "message" => "hello there", "n" => 3 } }
      v = Samagotchi::Guardrails::Verdict.new(call: c)
      v.ask!("an MCP tool", rule: "mcp-ask", source: "config")
      v.context = context
      v.targets = Samagotchi::Guardrails::Targets.for(c, context, registry: registry)
      expect(described_class.payload(v)[:approval][:args]).to eq("message=\"hello there\" n=3")
      v.targets = Samagotchi::Guardrails::Targets.for(c.merge(args: {}), context, registry: registry)
      expect(described_class.payload(v)[:approval]).not_to have_key(:args)
      expect(described_class.payload(ask)[:approval]).not_to have_key(:args)
    end

    it "asks about a call that acts as another tool by its label, else its name, with the inner args" do
      registry = Samagotchi::Tools::Registry.new
      registry.register("call_tool", schema: { name: "call_tool" }, handler: ->(*) { "" }, source: "mcp",
                                    targets: ->(call) { { acts_as: call[:args]["tool"], args: call[:args]["args"] } })
      c = { name: "call_tool", args: { "tool" => "mcp_github_x", "args" => { "owner" => "me" } } }
      v = Samagotchi::Guardrails::Verdict.new(call: c)
      v.ask!("an MCP tool", rule: "mcp-ask", source: "config")
      v.context = context
      v.targets = Samagotchi::Guardrails::Targets.for(c, context, registry: registry)
      payload = described_class.payload(v, label: "github: x")
      expect(payload[:question].lines.first).to eq("github: x: owner=me\n")
      expect(payload[:approval]).to include(tool: "call_tool", acts_as: "mcp_github_x", label: "github: x", args: "owner=me")
      expect(described_class.payload(v)[:question].lines.first).to eq("mcp_github_x: owner=me\n")
    end

    it "names a plugin tool by its label when given one; approval[:tool] stays the raw name" do
      c = { name: "mcp_x_echo", args: { "message" => "hi" } }
      v = Samagotchi::Guardrails::Verdict.new(call: c)
      v.ask!("an MCP tool", rule: "mcp-ask", source: "config")
      v.context = context
      registry = Samagotchi::Tools::Registry.new
      registry.register("mcp_x_echo", schema: { name: "mcp_x_echo" }, handler: ->(*) { "" }, source: "mcp")
      v.targets = Samagotchi::Guardrails::Targets.for(c, context, registry: registry)
      payload = described_class.payload(v, label: "x: echo")
      expect(payload[:question].lines.first).to eq("x: echo: message=hi\n")
      expect(payload[:approval]).to include(tool: "mcp_x_echo", label: "x: echo")
      expect(described_class.payload(v)[:approval]).not_to have_key(:label)
    end

    it "names the repo and branch, and carries the structured approval" do
      system("git", "-C", dir, "init", "-q", "-b", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "x",
             out: File::NULL, err: File::NULL)
      payload = described_class.payload(ask(scopes: %w[once repo]))
      expect(payload[:question]).to include("  in #{dir} (repo #{File.basename(dir)}, branch main)")
      expect(payload[:options]).to eq(["Allow once", "Allow this call in this repo (#{File.basename(dir)})", "Deny"])
      expect(payload[:approval]).to eq(tool: "execute", command: "git push origin main", cwd: dir, repo_root: dir,
                                       repo_name: File.basename(dir), branch: "main", rule: "git-push",
                                       source: "bundle guardrails", reason: "git push publishes commits",
                                       scopes: %w[once repo])
    end

    it "names the repository, not the worktree, in a linked worktree" do
      system("git", "-C", dir, "init", "-q", "-b", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "x",
             out: File::NULL, err: File::NULL)
      worktree = File.join(dir, "wt-feature")
      system("git", "-C", dir, "worktree", "add", "-q", "-b", "feat", worktree, out: File::NULL, err: File::NULL)
      c = { name: "execute", content: "git push", cwd: worktree }
      v = Samagotchi::Guardrails::Verdict.new(call: c).ask!("pushes", rule: "git-push", source: "config", scopes: %w[once repo rule])
      v.context = context
      v.targets = Samagotchi::Guardrails::Targets.for(c, context)
      payload = described_class.payload(v)
      repo = File.basename(dir)
      expect(payload[:question]).to include("  in #{worktree} (repo #{repo}, branch feat)")
      expect(payload[:options]).to eq(["Allow once", "Allow this call in this repo (#{repo})",
                                       "Allow rule git-push in this repo (#{repo})", "Deny"])
      expect(payload[:approval]).to include(repo_root: worktree, repo_name: repo)
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

  describe "a memory_write ask" do
    def memory_call(name: "notes", scope: "system", remove: false)
      { name: "memory_write", path: name, scope: scope, remove: remove }
    end

    def memory_facts(call, rule: "memory-remove")
      described_class.payload(ask(c: call, rule: rule))[:approval][:memory]
    end

    it "names the entry and its scope, and says nothing for another tool" do
      with_config_home(dir) do
        expect(memory_facts(memory_call, rule: "memory-write")).to eq({ name: "notes", scope: "system" })
        expect(described_class.payload(ask)[:approval]).not_to have_key(:memory)
        expect(memory_facts({ name: "memory_write", path: "h", scope: "team" })).to be_nil
      end
    end

    it "adds the entry's index description for a removal, where the ask needs it" do
      with_config_home(dir) do
        FileUtils.mkdir_p(Samagotchi::MemoryPaths.system_dir)
        File.write(File.join(Samagotchi::MemoryPaths.system_dir, "index.md"),
                   "- **notes** · system · 2026-10-25 · 42 — how the user likes their notes\n\nFree-form prose here.\n")
        expect(memory_facts(memory_call(remove: true))).to eq({ name: "notes", scope: "system",
                                                                description: "how the user likes their notes" })
        # A write ask gets the entry and its scope only: its own content is in the card.
        expect(memory_facts(memory_call, rule: "memory-write")).to eq({ name: "notes", scope: "system" })
      end
    end

    it "keeps just the name and scope when the index has no line, or no description" do
      with_config_home(dir) do
        FileUtils.mkdir_p(Samagotchi::MemoryPaths.system_dir)
        File.write(File.join(Samagotchi::MemoryPaths.system_dir, "index.md"),
                   "- **notes** · system · 2026-10-25 · 42 · from guardrails\n- **other** · system · 2026-10-25 · 10\n")
        expect(memory_facts(memory_call(remove: true))).to eq({ name: "notes", scope: "system" })
        expect(memory_facts(memory_call(name: "other", remove: true))).to eq({ name: "other", scope: "system" })
      end
    end

    it "resolves a project scope's index too" do
      with_config_home(dir) do
        call = memory_call(name: "git_workspace_rule", scope: "project", remove: true)
        entry_dir = File.dirname(Samagotchi::Guardrails::Targets.memory_path(call, nil))
        FileUtils.mkdir_p(entry_dir)
        File.write(File.join(entry_dir, "index.md"),
                   "- **git_workspace_rule** · project · 2026-10-03 · 1942 — worktree per task\n")
        expect(memory_facts(call))
          .to eq({ name: "git_workspace_rule", scope: "project", description: "worktree per task" })
      end
    end
  end

  describe ".settle" do
    let(:scopes) { %w[once session] }

    it "allows with the scope at the picked index" do
      answer = Samagotchi::QuestionAnswer.new(id: "q", selected: ["x"], selected_indices: [1])
      v = described_class.settle(ask, answer, scopes)
      expect([v.decision, v.scope, v.decided_by]).to eq([:allow, "session", "user"])
    end

    it "denies on Deny, with the user's reason when given" do
      answer = Samagotchi::QuestionAnswer.new(id: "q", selected: ["Deny"], freeform: "use a PR", selected_indices: [2])
      v = described_class.settle(ask, answer, scopes)
      expect(v).to be_deny
      expect(v.deny_text).to eq('The user declined this call: "use a PR". It needed approval (rule git-push, bundle guardrails): ' \
                                "git push publishes commits. Do not retry it or reach the same result another way; " \
                                "ask the user how to proceed.")
      expect(v.deny_text).not_to include("denied by guardrail")
    end

    it "says the user declined, without a reason when none was given" do
      answer = Samagotchi::QuestionAnswer.new(id: "q", selected: ["Deny"], selected_indices: [2])
      v = described_class.settle(ask, answer, scopes)
      expect(v.deny_text).to start_with("The user declined this call. It needed approval (rule git-push, bundle guardrails):")
    end

    it "denies a freeform-only answer with that reason" do
      answer = Samagotchi::QuestionAnswer.new(id: "q", selected: [], freeform: "not now")
      v = described_class.settle(ask, answer, scopes)
      expect(v.deny_text).to start_with('The user declined this call: "not now". It needed approval')
    end

    it "denies a cancelled or unanswered question" do
      v = described_class.settle(ask, { error: "cancelled" }, scopes)
      expect(v.deny_text).to eq("The approval was cancelled. It needed approval (rule git-push, bundle guardrails): " \
                                "git push publishes commits. Do not retry it or reach the same result another way; " \
                                "ask the user how to proceed.")
      expect(described_class.settle(ask, "legacy text", scopes)).to be_deny
    end
  end
end
