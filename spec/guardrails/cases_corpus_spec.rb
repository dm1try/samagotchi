# frozen_string_literal: true

require "json"
require "tmpdir"
require "yaml"
require "samagotchi/guardrails"

# The guardrail cases corpus (spec/fixtures/guardrails/cases.jsonl): one
# labelled tool call per line, run against a fixed rule set
# (spec/fixtures/guardrails/rules.yml) or the shipped guardrails bundle's.
#
# A case:
#   id      required, unique, kebab-case
#   tool    required: execute, task_create, write, edit or read
#   command the shell command (execute, task_create)
#   path    the path (write, edit, read)
#   cwd     optional: the call's cwd:, relative to the spec's temp repo
#   expect  required: match | no_match | allow | ask | deny
#   rule    the rule these are about (required with match, no_match and
#           checked against the deciding rule with ask, deny)
#   rules   optional: fixture (the default) or guardrails-bundle
#   source  required: where the case came from (heredoc-fp,
#           heredoc-bypass, chi-answer-piped, ...)
#   note    optional: why the label is what it is
#
# match / no_match: whether Rule#matches? matches the call. allow / ask /
# deny: the rule set's decision (Rules#check), not the whole Gate's. Add a
# case with every guardrail false positive or miss fixed; never relabel a
# case to make a spec pass.
RSpec.describe "The guardrail cases corpus" do
  KEYS = %w[id tool command path cwd expect rule rules source note].freeze
  LABELS = %w[match no_match allow ask deny].freeze
  RULE_SETS = %w[fixture guardrails-bundle].freeze
  SHELL_TOOLS = %w[execute task_create].freeze

  CASES = File.readlines(File.expand_path("../fixtures/guardrails/cases.jsonl", __dir__), chomp: true)
            .each_with_index.map { |line, i| JSON.parse(line).merge("line" => i + 1) }

  let(:rules_doc) { YAML.safe_load_file(File.expand_path("../fixtures/guardrails/rules.yml", __dir__)) }
  let(:bundle_dir) { File.expand_path("../../lib/samagotchi/bundles/guardrails", __dir__) }
  let(:bundle_doc) { YAML.safe_load_file(File.join(bundle_dir, "guardrails", "rules.yml")) }
  let(:context) { Samagotchi::Guardrails::Context.new(cwd: @repo, git: @git) }

  let(:rule_sets) do
    {
      "fixture" => Samagotchi::Guardrails::Rules.new(
        Samagotchi::Guardrails::Rules.parse(rules_doc["rules"], source: "config"), mode: "auto"
      ),
      "guardrails-bundle" => Samagotchi::Guardrails::Rules.new(
        Samagotchi::Guardrails::Rules.parse(bundle_doc["rules"], source: "bundle guardrails"), mode: "auto"
      )
    }
  end

  before(:context) do
    @repo = File.realpath(Dir.mktmpdir("cases-corpus")).tap { |d| system("git", "-C", d, "init", "-q") }
    @git = Samagotchi::Guardrails::GitInfo.new
  end

  after(:context) { FileUtils.rm_rf(@repo) }

  def call_for(kase)
    tool = kase["tool"]
    call = if SHELL_TOOLS.include?(tool)
             { name: tool, content: kase["command"] }
           elsif tool == "read"
             { name: tool, content: kase["path"] }
           else
             { name: tool, path: kase["path"], content: "" }
           end
    call[:cwd] = kase["cwd"] if kase["cwd"]
    call
  end

  def rule_set(kase) = rule_sets.fetch(kase["rules"] || "fixture")

  def rule_named(kase, id) = rule_set(kase).rules.find { |rule| rule.id == id }

  def label_of(verdict)
    if verdict.allow? then "allow"
    elsif verdict.ask? then "ask"
    elsif verdict.deny? then "deny"
    end
  end

  it "is a well-formed corpus" do
    expect(CASES).not_to be_empty
    ids = CASES.map { |kase| kase["id"] }
    expect(ids.uniq.size).to eq(ids.size), "duplicate ids: #{(ids - ids.uniq).uniq.inspect}"
    CASES.each do |kase|
      where = "line #{kase["line"]} (#{kase["id"].inspect})"
      expect(kase.keys - %w[line]).to all(satisfy { |key| KEYS.include?(key) }), "#{where}: unknown key(s)"
      %w[id tool expect source].each { |key| expect(kase[key]).not_to be_nil, "#{where}: no #{key}" }
      expect(LABELS).to include(kase["expect"]), "#{where}: expect #{kase["expect"].inspect}"
      expect(RULE_SETS).to include(kase["rules"]), "#{where}: rules #{kase["rules"].inspect}" if kase["rules"]
      if SHELL_TOOLS.include?(kase["tool"])
        expect(kase["command"]).to be_a(String), "#{where}: a shell tool needs a command"
      else
        expect(kase["path"]).to be_a(String), "#{where}: #{kase["tool"]} needs a path"
      end
      next unless %w[match no_match].include?(kase["expect"]) || %w[ask deny].include?(kase["expect"])

      expect(kase["rule"]).to be_a(String), "#{where}: #{kase["expect"]} needs a rule"
      expect(rule_named(kase, kase["rule"])).not_to be_nil, "#{where}: no rule #{kase["rule"].inspect} in #{kase["rules"] || "fixture"}"
    end
  end

  CASES.each do |kase|
    it "#{kase["id"]}: #{kase["expect"]} #{kase["rule"]}" do
      call = call_for(kase)
      targets = Samagotchi::Guardrails::Targets.for(call, context)
      set = rule_set(kase)
      note = kase["note"] ? " (#{kase["note"]})" : ""
      if %w[match no_match].include?(kase["expect"])
        matched = rule_named(kase, kase["rule"]).matches?(targets)
        expect(matched).to eq(kase["expect"] == "match"), "expected #{kase["expect"]} on #{kase["rule"]}#{note}"
      else
        verdict = Samagotchi::Guardrails::Verdict.new(call: call)
        verdict.context = context
        verdict.targets = targets
        set.check(verdict)
        expect(label_of(verdict)).to eq(kase["expect"]), "expected #{kase["expect"]}#{note}"
        expect(verdict.rule).to eq(kase["rule"]), "expected rule #{kase["rule"]}#{note}" if kase["rule"]
      end
    end
  end
end
