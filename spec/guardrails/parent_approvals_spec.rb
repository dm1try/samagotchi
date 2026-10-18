# frozen_string_literal: true

require "spec_helper"
require "samagotchi/guardrails/parent_approvals"
require "samagotchi/pending_question"

# The facts a parent agent's answer is judged by (ParentPolicy): which
# approvals are the user's alone, and who answers as a parent.
RSpec.describe Samagotchi::Guardrails::ParentApprovals do
  let(:approval) do
    { id: "a1", kind: "approval",
      options: ["Allow once", "Allow this call for the session", "Allow rule spike-ask in this directory", "Deny"],
      approval: { tool: "execute", scopes: %w[once session rule] } }
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
  # the strategy says: an "Allow once" there would turn once into always.
  describe "an approval that touches chi's own config, hooks or guardrails" do
    let(:config_home) { Dir.mktmpdir("pa-config") }
    let(:once_only) { approval.merge(options: ["Allow once", "Allow this call for the session", "Deny"]) }

    around do |example|
      with_env("XDG_CONFIG_HOME" => config_home) { example.run }
    ensure
      FileUtils.rm_rf(config_home)
    end

    def facts(fields) = once_only.merge(approval: { tool: "write", scopes: %w[once session] }.merge(fields))
    def protected?(pending) = described_class.protected?(Samagotchi::PendingQuestion.from_file(pending))

    it "is protected by its rule, its source, its paths or its command" do
      [
        facts(source: "core", rule: "chi-config", paths: ["/elsewhere/config.yml"]),
        facts(source: "core", rule: "chi-hooks"),
        facts(tool: "execute", source: "bundle guardrails", rule: "shell-touches-chi", command: "ls"),
        facts(tool: "execute", source: "bundle guardrails", rule: "chi-context-cmd", command: "chi context add x --cmd y"),
        facts(rule: "write-outside-repo", paths: [File.join(config_home, "samagotchi", "config.yml")]),
        facts(rule: "write-outside-repo", paths: [File.join(config_home, "samagotchi", "memories", ".bundles", "x", "r.yml")]),
        facts(tool: "edit", rule: "write-outside-repo", paths: [File.join(config_home, "samagotchi", "hooks", "h.rb")]),
        facts(tool: "execute", rule: "my-ask", command: "sed -i s/a/b/ #{config_home}/samagotchi/config.yml"),
        facts(tool: "execute", rule: "my-ask", command: "cat > ~/.config/samagotchi/hooks/x.rb")
      ].each do |pending|
        expect(protected?(pending)).to be(true), pending[:approval].inspect
        expect(described_class.protected_facts?(pending[:approval])).to be(true), pending[:approval].inspect
      end
    end

    it "lists the config, hooks, approval store, installed bundles and attached context dirs as chi's" do
      expect(described_class.chi_dirs).to include(File.join(config_home, "samagotchi"),
                                                  Samagotchi::MemoryPaths.bundles_dir.chomp("/"),
                                                  File.join(Samagotchi::Paths.state_dir, "context"))
    end

    it "covers a hooks_dir set in config.yml" do
      hooks = Dir.mktmpdir("pa-hooks")
      FileUtils.mkdir_p(File.join(config_home, "samagotchi"))
      File.write(File.join(config_home, "samagotchi", "config.yml"), "hooks:\n  hooks_dir: #{hooks}\n")
      expect(protected?(facts(rule: "x", paths: [File.join(hooks, "a.rb")]))).to be(true)
    ensure
      FileUtils.rm_rf(hooks)
    end

    it "leaves other approvals to the setting" do
      expect(protected?(facts(tool: "execute", rule: "git-push", command: "git push", paths: nil))).to be(false)
      expect(protected?(facts(rule: "write-outside-repo", paths: ["/tmp/x.txt"]))).to be(false)
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
