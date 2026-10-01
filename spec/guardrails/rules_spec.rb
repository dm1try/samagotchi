# frozen_string_literal: true

require "tmpdir"
require "samagotchi/guardrails"
require "samagotchi/hooks"
require "samagotchi/engine"
require "samagotchi/model_overlay"

RSpec.describe Samagotchi::Guardrails::Rules do
  let(:repo) { File.realpath(Dir.mktmpdir("guard-rules")).tap { |d| system("git", "-C", d, "init", "-q") } }
  let(:context) { Samagotchi::Guardrails::Context.new(cwd: repo) }

  after { FileUtils.rm_rf(repo) }

  def rules(*raw, source: "config", enabled: true)
    described_class.new(described_class.parse(raw.map { |r| r.transform_keys(&:to_s) }, source: source), enabled: enabled)
  end

  def verdict_for(call, set)
    v = Samagotchi::Guardrails::Verdict.new(call: call)
    v.context = context
    v.targets = Samagotchi::Guardrails::Targets.for(call, context)
    set.check(v)
  end

  describe "matching" do
    let(:push) { { id: "git-push", tool: "shell", command: '\bgit\b.*\bpush\b', verdict: "ask", reason: "publishes commits" } }

    it "matches a shell rule on execute and task_create, by command regex" do
      set = rules(push)
      v = verdict_for({ name: "execute", content: "git push origin main" }, set)
      expect([v.decision, v.rule, v.source, v.reason, v.decided_by]).to eq([:ask, "git-push", "config", "publishes commits", "rule"])
      expect(verdict_for({ name: "task_create", content: "cd x && git push" }, set)).to be_ask
      expect(verdict_for({ name: "execute", content: "git status" }, set)).to be_allow
    end

    it "doesn't match a command rule on a file tool" do
      expect(verdict_for({ name: "write", path: "git push", content: "x" }, rules(push.except(:tool)))).to be_allow
    end

    it "matches a tool name or list alone" do
      set = rules({ id: "no-fetch", tool: %w[web_fetch], verdict: "deny" })
      v = verdict_for({ name: "web_fetch", content: "https://x" }, set)
      expect([v.decision, v.reason]).to eq([:deny, "rule no-fetch"])
      expect(verdict_for({ name: "read", content: "a" }, set)).to be_allow
    end

    it "matches a tool glob (an MCP server's tools), with the exact names beside it" do
      set = rules({ id: "mcp-ask", tool: ["mcp_*", "web_fetch"], verdict: "ask" })
      expect(verdict_for({ name: "mcp_everything_echo", args: { "message" => "x" } }, set)).to be_ask
      expect(verdict_for({ name: "web_fetch", content: "https://x" }, set)).to be_ask
      expect(verdict_for({ name: "read", content: "mcp_x" }, set)).to be_allow
      braces = rules({ id: "two", tool: "mcp_{git,gh}_*", verdict: "deny" })
      expect(verdict_for({ name: "mcp_gh_create_issue", args: {} }, braces)).to be_deny
      expect(verdict_for({ name: "mcp_fs_read", args: {} }, braces)).to be_allow
    end

    it "matches outside_repo" do
      set = rules({ id: "out", tool: %w[write edit], path: "outside_repo", verdict: "ask" })
      expect(verdict_for({ name: "write", path: "../x", content: "" }, set)).to be_ask
      expect(verdict_for({ name: "write", path: "in.txt", content: "" }, set)).to be_allow
    end

    it "matches absolute, ** and repo-relative globs" do
      hooks = rules({ id: "git-hooks", tool: %w[write edit], path: "**/.git/hooks/**", verdict: "deny" })
      expect(verdict_for({ name: "write", path: ".git/hooks/pre-commit", content: "" }, hooks)).to be_deny
      etc = rules({ id: "etc", path: "/etc/**", verdict: "deny" })
      expect(verdict_for({ name: "edit", path: "/etc/hosts", content: "" }, etc)).to be_deny
      rel = rules({ id: "cfg", path: "config/*.yml", verdict: "ask" })
      expect(verdict_for({ name: "write", path: "config/app.yml", content: "" }, rel)).to be_ask
      expect(verdict_for({ name: "write", path: "other/config/app.yml", content: "" }, rel)).to be_allow
    end

    it "matches path rules on the read tool's path (the secrets rules from guardrails-extra-rules.yml)" do
      dotenv = rules({ id: "read-dotenv", tool: %w[read], path: "**/.env*", verdict: "ask" })
      expect(verdict_for({ name: "read", content: ".env" }, dotenv)).to be_ask
      expect(verdict_for({ name: "read", content: "config/.env.local" }, dotenv)).to be_ask
      expect(verdict_for({ name: "read", content: "README.md" }, dotenv)).to be_allow
      secrets = rules({ id: "read-secrets", tool: %w[read], path: "**/{.ssh,.aws,.gnupg}/**", verdict: "ask" })
      expect(verdict_for({ name: "read", content: "~/.ssh/id_rsa" }, secrets)).to be_ask
      expect(verdict_for({ name: "read", content: "/home/u/.aws/credentials" }, secrets)).to be_ask
    end

    it "needs every given field to match" do
      set = rules({ id: "x", tool: "execute", command: "rm", path: "outside_repo", verdict: "deny" })
      expect(verdict_for({ name: "execute", content: "rm -rf x" }, set)).to be_allow
    end

    it "lets the strictest rule win, the first of equals kept: config before bundles" do
      set = described_class.new(
        described_class.parse([{ "id" => "a", "tool" => "shell", "verdict" => "ask" }], source: "config") +
        described_class.parse([{ "id" => "b", "tool" => "shell", "verdict" => "ask" },
                               { "id" => "c", "command" => "rm", "verdict" => "deny" }], source: "bundle g")
      )
      expect(verdict_for({ name: "execute", content: "ls" }, set).rule).to eq("a")
      v = verdict_for({ name: "execute", content: "rm x" }, set)
      expect([v.decision, v.rule, v.source]).to eq([:deny, "c", "bundle g"])
    end

    it "passes the rule's scopes to the ask" do
      v = verdict_for({ name: "execute", content: "git push" }, rules(push.merge(scopes: %w[once repo])))
      expect(v.scopes).to eq(%w[once repo])
    end
  end

  describe "models:" do
    let(:checkout) { { id: "discard", tool: "shell", command: '\bgit checkout --', verdict: "ask" } }

    def verdict_on(model, set, setting: "auto")
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.small_models").and_return(setting)
      call = { name: "execute", content: "git checkout -- app.rb" }
      v = Samagotchi::Guardrails::Verdict.new(call: call)
      v.context = context
      v.targets = Samagotchi::Guardrails::Targets.for(call, context, model_name: model,
                                                                     model_key: Samagotchi::ModelOverlay.key_for(model))
      set.check(v)
    end

    it "votes on every model without it" do
      expect(verdict_on("Llama-3.3-70B", rules(checkout))).to be_ask
      expect(verdict_on(nil, rules(checkout))).to be_ask
    end

    it "matches a glob on the bare model name or on the model key" do
      expect(verdict_on("Qwen3.6-27B", rules(checkout.merge(models: "Qwen3.6-*")))).to be_ask
      expect(verdict_on("Qwen3.6-27B", rules(checkout.merge(models: "qwen3-6-*")))).to be_ask
      expect(verdict_on("Qwen3-8B", rules(checkout.merge(models: "Qwen3.6-*")))).to be_allow
    end

    it "matches any glob of a list" do
      set = rules(checkout.merge(models: %w[gemma-* Qwen3-8B]))
      expect(verdict_on("Qwen3-8B", set)).to be_ask
      expect(verdict_on("gemma-4-E4B-it", set)).to be_ask
      expect(verdict_on("Llama-3.3-70B", set)).to be_allow
    end

    it "matches small by guardrails.small_models, read on each check" do
      set = rules(checkout.merge(models: "small"))
      expect(verdict_on("Qwen3-8B", set)).to be_ask
      expect(verdict_on("Ornith-1.5-35B-A3B", set)).to be_ask
      expect(verdict_on("Llama-3.3-70B", set)).to be_allow
      expect(verdict_on("deepseek-v4.1-flash", set)).to be_allow
      expect(verdict_on("Qwen3-8B", set, setting: "")).to be_allow
      expect(verdict_on("deepseek-v4.1-flash", set, setting: "deepseek-*")).to be_ask
    end

    it "doesn't match without a model (fail open)" do
      expect(verdict_on(nil, rules(checkout.merge(models: "small")))).to be_allow
      expect(verdict_on(nil, rules(checkout.merge(models: "*")))).to be_allow
    end

    it "rejects a models: that isn't a name or a list of names" do
      expect { rules(checkout.merge(models: [])) }.to raise_error(described_class::ParseError, "rule discard: models must be small, a glob or a list of them")
      expect { rules(checkout.merge(models: { "a" => 1 })) }.to raise_error(described_class::ParseError, /models must be/)
    end
  end

  describe ".parse errors" do
    def error_for(raw) = (described_class.parse([raw], source: "config") && nil) rescue $!.message

    it "names the rule and the problem" do
      expect(error_for({ "id" => "x", "verdict" => "block", "tool" => "a" })).to eq('rule x: verdict must be ask or deny (got "block")')
      expect(error_for({ "id" => "x", "verdict" => "ask" })).to eq("rule x: give at least one of tool, command, path")
      expect(error_for({ "id" => "x", "verdict" => "ask", "comand" => "rm" })).to eq("rule x: unknown key(s) comand")
      expect(error_for({ "id" => "x", "verdict" => "ask", "command" => "(" })).to start_with("rule x: command is not a valid regex")
      expect(error_for({ "verdict" => "ask", "tool" => "a" })).to eq("rule 1: id is required")
      expect(error_for({ "id" => "x", "verdict" => "ask", "tool" => "a", "scopes" => ["forever"] })).to eq("rule x: unknown scope(s) forever")
      expect(error_for("git push")).to eq("rule 1 is not a mapping")
      expect { described_class.parse({ "id" => "x" }, source: "config") }.to raise_error(described_class::ParseError, "rules must be a list")
    end
  end

  describe "disable" do
    let(:parsed) do
      described_class.parse([{ "id" => "push", "tool" => "shell", "command" => "push", "verdict" => "ask" },
                             { "id" => "rm", "tool" => "shell", "command" => "rm", "verdict" => "deny" }], source: "config") +
        described_class.parse([{ "id" => "rm", "tool" => "shell", "command" => "rm", "verdict" => "ask" }],
                              source: "bundle guardrails")
    end

    it "switches off every rule with a plain id, whatever its source" do
      set = described_class.new(parsed, disable: %w[rm])
      expect(verdict_for({ name: "execute", content: "rm x" }, set)).to be_allow
      expect(verdict_for({ name: "execute", content: "push" }, set)).to be_ask
      expect(set.rules.map { |r| set.disabled?(r) }).to eq([false, true, true])
    end

    it "switches off only that bundle's rule with bundle:id" do
      set = described_class.new(parsed, disable: %w[guardrails:rm])
      v = verdict_for({ name: "execute", content: "rm x" }, set)
      expect([v.decision, v.source]).to eq([:deny, "config"])
      expect(set.rules.map { |r| set.disabled?(r) }).to eq([false, false, true])
    end

    it "names the entries that match no rule" do
      expect(described_class.new(parsed, disable: %w[rm nope other:rm]).unmatched_disables).to eq(%w[nope other:rm])
    end

    it "parses a list of ids and rejects anything else" do
      expect(described_class.parse_disable(nil)).to eq([])
      expect(described_class.parse_disable(["git-push", "guardrails:rm"])).to eq(%w[git-push guardrails:rm])
      expect(described_class.parse_disable("git-push")).to eq(%w[git-push])
      expect { described_class.parse_disable([{ "id" => "x" }]) }.to raise_error(described_class::ParseError, /disable/)
      expect { described_class.parse_disable([""]) }.to raise_error(described_class::ParseError, /disable/)
    end
  end

  describe "enabled: false" do
    it "applies no rules and drops a hook's ask, but keeps a deny" do
      set = rules({ id: "all", tool: "shell", verdict: "deny" }, enabled: false)
      expect(verdict_for({ name: "execute", content: "ls" }, set)).to be_allow

      v = Samagotchi::Guardrails::Verdict.new(call: { name: "execute" }).ask!("hook asks")
      expect(set.hook_asks.check(v)).to be_allow
      v = Samagotchi::Guardrails::Verdict.new(call: { name: "execute" }).deny!("hook denies")
      expect(set.hook_asks.check(v)).to be_deny
      v = Samagotchi::Guardrails::Verdict.new(call: { name: "execute" }).ask!("core asks", decided_by: "core")
      expect(set.hook_asks.check(v)).to be_ask
    end
  end
end

RSpec.describe "Engine: YAML guardrail rules from config.yml" do
  let(:config_path) { Samagotchi::ConfigFile.global_path }
  let!(:original) { File.read(config_path) }

  after do
    File.write(config_path, original)
    Samagotchi::ConfigFile.instance_variable_set(:@yaml_cache, nil)
  end

  def engine_with(yaml)
    File.write(config_path, original + yaml)
    Samagotchi::ConfigFile.instance_variable_set(:@yaml_cache, nil)
    Samagotchi::Engine.new(client: instance_double(Samagotchi::Client))
  end

  def evaluate(engine, call)
    engine.instance_variable_get(:@kernel).guardrail_gate.evaluate(call, iteration: 1, params: "")
  end

  it "votes with the config's rules" do
    engine = engine_with(<<~YAML)
      guardrails:
        rules:
          - id: no-rm
            tool: shell
            command: '\\brm\\b'
            verdict: deny
            reason: no deleting today
    YAML
    v = evaluate(engine, { name: "execute", content: "rm -rf build" })
    expect([v.decision, v.rule, v.source]).to eq([:deny, "no-rm", "config"])
    expect(evaluate(engine, { name: "execute", content: "ls" })).to be_allow
  end

  it "denies every call when the rules don't parse, and says why" do
    engine = nil
    expect do
      engine = engine_with(<<~YAML)
        guardrails:
          rules:
            - id: typo
              verdict: ask
              comand: rm
      YAML
    end.to output(/config.yml guardrails rules: rule typo: unknown key\(s\) comand/).to_stderr
    v = evaluate(engine, { name: "read", content: "README.md" })
    expect([v.decision, v.rule]).to eq([:deny, "guardrail-load"])
    expect(v.reason).to eq("required guardrail rules in config.yml failed to load: rule typo: unknown key(s) comand")
  end

  it "reads guardrails.disable" do
    engine = engine_with(<<~YAML)
      guardrails:
        disable: [no-rm]
        rules:
          - id: no-rm
            tool: shell
            verdict: deny
    YAML
    expect(evaluate(engine, { name: "execute", content: "rm x" })).to be_allow
  end

  it "denies every call when guardrails.disable isn't a list of ids" do
    engine = nil
    expect { engine = engine_with("guardrails:\n  disable: {no-rm: true}\n") }.to output(/disable/).to_stderr
    expect(evaluate(engine, { name: "read", content: "README.md" }).rule).to eq("guardrail-load")
  end

  it "votes with a models: small rule only on a small model, following guardrails.small_models live" do
    rule = "guardrails:\n  rules:\n    - {id: small-rm, tool: shell, command: rm, verdict: deny, models: small}\n"
    on = lambda do |model, extra = ""|
      File.write(config_path, "default: {model: #{model}}\n#{rule}#{extra}")
      Samagotchi::ConfigFile.instance_variable_set(:@yaml_cache, nil)
    end
    on.call("Qwen3-8B")
    small = Samagotchi::Engine.new(client: instance_double(Samagotchi::Client))
    expect(evaluate(small, { name: "execute", content: "rm x" }).rule).to eq("small-rm")
    on.call("Llama-3.3-70B")
    expect(evaluate(Samagotchi::Engine.new(client: instance_double(Samagotchi::Client)), { name: "execute", content: "rm x" })).to be_allow

    on.call("Qwen3-8B", "  small_models: []\n")
    expect(evaluate(small, { name: "execute", content: "rm x" })).to be_allow
  end

  it "reads guardrails.enabled" do
    engine = engine_with(<<~YAML)
      guardrails:
        enabled: false
        rules:
          - id: all
            tool: shell
            verdict: deny
    YAML
    expect(evaluate(engine, { name: "execute", content: "ls" })).to be_allow
  end
end
