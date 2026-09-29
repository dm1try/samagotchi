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
      expect(text.(diff.merge(new_file: true, added: 12))).to eq("  change: new file, 12 lines")
      expect(text.(diff.merge(new_file: true, added: 1))).to eq("  change: new file, 1 line")
      expect(text.({ error: "old text not found in /x" })).to eq("  change: would fail: old text not found in /x")
      expect(text.({ skipped: "binary file" })).to eq("  change: not shown (binary file)")
      expect(text.({ "added" => 2, "removed" => 0 })).to eq("  change: +2 \u22120")
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
        "execute: git push origin main\n  in #{dir} (not in a repo)\n" \
        "  why: git push publishes commits (rule git-push, bundle guardrails)"
      )
      expect(payload[:options]).to eq(["Allow once", "Allow this call for the session", "Allow this call in this directory",
                                       "Allow rule git-push in this directory", "Deny"])
      expect(payload).to include(kind: "approval", header: "Approve tool call?", allow_freeform: true, multi_select: false)
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
      expect(v.deny_text).to eq('The user declined this call: "use a PR". It needed approval (rule git-push, bundle guardrails): ' \
                                "git push publishes commits. Do not retry it or reach the same result another way; " \
                                "ask the user how to proceed.")
      expect(v.deny_text).not_to include("denied by guardrail")
    end

    it "says the user declined, without a reason when none was given" do
      v = described_class.settle(ask, { selected_indices: [2] }, scopes)
      expect(v.deny_text).to start_with("The user declined this call. It needed approval (rule git-push, bundle guardrails):")
    end

    it "denies a freeform-only answer with that reason" do
      v = described_class.settle(ask, { selected_indices: [], freeform: "not now" }, scopes)
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
