# frozen_string_literal: true

require "spec_helper"
require "samagotchi/guardrails/parent_approvals"

# What a parent agent (chi answer) may allow on an approval: the one rule
# the CLI checks before posting and the worker checks again.
RSpec.describe Samagotchi::Guardrails::ParentApprovals do
  let(:approval) do
    { id: "a1", kind: "approval",
      options: ["Allow once", "Allow this call for the session", "Allow rule spike-ask in this directory", "Deny"],
      approval: { tool: "execute", scopes: %w[once session rule] } }
  end

  def refusal(pending, indices, setting)
    described_class.refusal(pending, indices, setting: setting)
  end

  it "lets a deny through whatever the setting: the Deny option, no option (text alone)" do
    %w[off once].each do |setting|
      expect(refusal(approval, [3], setting)).to be_nil
      expect(refusal(approval, [], setting)).to be_nil
    end
  end

  it "refuses every allow with off, and all but the once scope with once" do
    [0, 1, 2].each { |index| expect(refusal(approval, [index], "off")).to eq(:off) }
    expect(refusal(approval, [0], "once")).to be_nil
    [1, 2].each { |index| expect(refusal(approval, [index], "once")).to eq(:once_only) }
  end

  it "checks the scope by index, never by label" do
    relabeled = approval.merge(options: ["Allow once", "Allow once", "Allow once", "Deny"])
    expect(refusal(relabeled, [1], "once")).to eq(:once_only)
    no_once = approval.merge(options: ["Allow once", "Deny"], approval: { scopes: %w[session] })
    expect(refusal(no_once, [0], "once")).to eq(:once_only)
  end

  it "refuses a mix of deny and allow (a multi-select answer), and any unknown setting as off" do
    expect(refusal(approval, [3, 0], "off")).to eq(:off)
    expect(refusal(approval, [3, 1], "once")).to eq(:once_only)
    expect(refusal(approval, [0], "always")).to eq(:off)
    expect(refusal(approval, [0], nil)).to eq(:off)
  end

  it "fails closed when the scopes are missing, empty or malformed: only the last option, Deny, passes" do
    [nil, [], "once", [nil], [1], %w[once session rule extra]].each do |scopes|
      pending = approval.merge(approval: { tool: "execute", scopes: scopes })
      [0, 1, 2].each do |index|
        expect(refusal(pending, [index], "once")).to eq(:once_only), "scopes #{scopes.inspect}, option #{index}"
      end
      expect(refusal(pending, [3], "once")).to be_nil
    end
    expect(refusal(approval.except(:approval), [0], "once")).to eq(:once_only)
    expect(refusal(approval.merge(approval: "x"), [0], "off")).to eq(:off)
  end

  it "treats a last option that isn't Deny, or an index it can't place, as an allow" do
    pending = approval.merge(options: ["Allow once", "Allow always"], approval: {})
    expect(refusal(pending, [1], "once")).to eq(:once_only)
    expect(refusal(approval, [nil], "once")).to eq(:once_only)
    expect(refusal(approval, [9], "off")).to eq(:off)
  end

  it "reads string keys (a session file) and an approval without a kind" do
    pending = { "kind" => "approval", "options" => approval[:options], "approval" => { "scopes" => %w[once session rule] } }
    expect(refusal(pending, [0], "once")).to be_nil
    expect(refusal(pending, [1], "once")).to eq(:once_only)
    expect(refusal(approval.except(:kind), [1], "off")).to eq(:off)
  end

  it "has nothing to say about a question that isn't an approval" do
    question = { id: "q1", kind: "hook", options: %w[Yes No] }
    expect(refusal(question, [0], "off")).to be_nil
    expect(refusal(question.except(:kind), [0], "off")).to be_nil
  end

  it "tells the parent to deny and tell its user, never how to allow it" do
    expect(described_class.message(:off)).to eq(
      "allowing a tool call is up to the user: deny it (--option Deny --text WHY), and tell your user"
    )
    expect(described_class.message(:once_only)).to eq(
      "only Allow once (guardrails.parent_approvals: once) can be given here: " \
      "deny it (--option Deny --text WHY), and tell your user"
    )
    expect(described_class.message(:protected)).to start_with("this call changes chi's own config")
    expect(described_class.message(:off, typed: true)).to end_with("deny it (n; WHY), and tell your user")
    %i[off once_only protected].each { |reason| expect(described_class.message(reason)).not_to include("--attach", "web") }
  end

  it "is a config.yml setting only: the parent's environment can't change it" do
    env = { "SAMAGOTCHI_GUARDRAILS_PARENT_APPROVALS" => "once" }
    expect(Samagotchi::Config.resolve("guardrails.parent_approvals", file_data: {}, env: env)).to eq("off")
    file = { "guardrails" => { "parent_approvals" => "once" } }
    expect(Samagotchi::Config.resolve("guardrails.parent_approvals", file_data: file, env: {})).to eq("once")
  end

  it "takes guardrails.enabled and small_models from config.yml only, never the environment" do
    env = { "SAMAGOTCHI_GUARDRAILS_ENABLED" => "false", "SAMAGOTCHI_GUARDRAILS_SMALL_MODELS" => "" }
    expect(Samagotchi::Config.resolve("guardrails.enabled", file_data: {}, env: env)).to be(true)
    expect(Samagotchi::Config.resolve("guardrails.small_models", file_data: {}, env: env)).to eq("auto")
    file = { "guardrails" => { "enabled" => false, "small_models" => "x*" } }
    expect(Samagotchi::Config.resolve("guardrails.enabled", file_data: file, env: {})).to be(false)
    expect(Samagotchi::Config.resolve("guardrails.small_models", file_data: file, env: {})).to eq("x*")
  end

  # chi's own config, hooks and guardrail rules stay with the user, whatever
  # parent_approvals says: an "Allow once" there would turn once into always.
  describe "an approval that touches chi's own config, hooks or guardrails" do
    let(:config_home) { Dir.mktmpdir("pa-config") }
    let(:once_only) { approval.merge(options: ["Allow once", "Allow this call for the session", "Deny"]) }

    around do |example|
      with_env("XDG_CONFIG_HOME" => config_home) { example.run }
    ensure
      FileUtils.rm_rf(config_home)
    end

    def facts(fields) = once_only.merge(approval: { tool: "write", scopes: %w[once session] }.merge(fields))

    it "is refused as protected for any allow, with once or off; a deny still goes" do
      [
        facts(source: "core", rule: "chi-config", paths: ["/elsewhere/config.yml"]),
        facts(source: "core", rule: "chi-hooks"),
        facts(tool: "execute", source: "bundle guardrails", rule: "shell-touches-chi", command: "ls"),
        facts(rule: "write-outside-repo", paths: [File.join(config_home, "samagotchi", "config.yml")]),
        facts(rule: "write-outside-repo", paths: [File.join(config_home, "samagotchi", "memories", ".bundles", "x", "r.yml")]),
        facts(tool: "edit", rule: "write-outside-repo", paths: [File.join(config_home, "samagotchi", "hooks", "h.rb")]),
        facts(tool: "execute", rule: "my-ask", command: "sed -i s/a/b/ #{config_home}/samagotchi/config.yml"),
        facts(tool: "execute", rule: "my-ask", command: "cat > ~/.config/samagotchi/hooks/x.rb")
      ].each do |pending|
        %w[off once].each do |setting|
          expect(refusal(pending, [0], setting)).to eq(:protected), pending[:approval].inspect
        end
        expect(refusal(pending, [2], "once")).to be_nil
        expect(refusal(pending, [], "once")).to be_nil
      end
    end

    it "lists the config, hooks, approval store and installed bundles dirs as chi's" do
      expect(described_class.chi_dirs).to include(File.join(config_home, "samagotchi"),
                                                  Samagotchi::MemoryPaths.bundles_dir.chomp("/"))
    end

    it "covers a hooks_dir set in config.yml" do
      hooks = Dir.mktmpdir("pa-hooks")
      FileUtils.mkdir_p(File.join(config_home, "samagotchi"))
      File.write(File.join(config_home, "samagotchi", "config.yml"), "hooks:\n  hooks_dir: #{hooks}\n")
      expect(refusal(facts(rule: "x", paths: [File.join(hooks, "a.rb")]), [0], "once")).to eq(:protected)
    ensure
      FileUtils.rm_rf(hooks)
    end

    it "leaves other approvals to the setting" do
      pending = facts(tool: "execute", rule: "git-push", command: "git push", paths: nil)
      expect(refusal(pending, [0], "once")).to be_nil
      expect(refusal(facts(rule: "write-outside-repo", paths: ["/tmp/x.txt"]), [0], "once")).to be_nil
    end

    it "says only the user can allow it" do
      expect(described_class.message(:protected)).to include("only the user can allow")
    end
  end

  describe ".parent_process?" do
    let(:tty) { instance_double(IO, tty?: true) }
    let(:pipe) { instance_double(IO, tty?: false) }

    it "is a parent when stdin isn't a terminal" do
      expect(described_class.parent_process?(env: {}, stdin: pipe)).to be(true)
      expect(described_class.parent_process?(env: {}, stdin: tty)).to be(false)
    end

    it "is a parent on a terminal when an agent marker is set (a PTY wrapper keeps the environment)" do
      %w[CLAUDECODE AI_AGENT CODEX_THREAD_ID SAMAGOTCHI_PARENT_SESSION].each do |marker|
        expect(described_class.parent_process?(env: { marker => "1" }, stdin: tty)).to be(true), marker
      end
      expect(described_class.parent_process?(env: { "CLAUDECODE" => "" }, stdin: tty)).to be(false)
    end
  end
end
