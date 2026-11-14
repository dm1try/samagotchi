# frozen_string_literal: true

require "fileutils"
require "open3"
require_relative "../../script/load_check/check"

# script/load-check: the three load rules, read with Prism and never executed.
# Each fixture tree is a tiny lib/samagotchi the checker runs over.
RSpec.describe LoadCheck::Check do
  FIXTURES = File.expand_path("../fixtures/load_check", __dir__)
  # An empty allow-list: the script-level examples see the tree's every finding.
  NO_ALLOW = File.join(FIXTURES, "allow_list", "none.yml")

  def check(tree, allow: nil)
    described_class.new(root: File.join(FIXTURES, tree), allow: allow).run
  end

  it "finds a constant a method names that no require reaches (rule 1), and passes one that does" do
    result = check("call_time")

    expect(result.findings.size).to eq(1)
    expect(result.findings.first).to have_attributes(rule: 1, path: "lib/samagotchi/uses_session.rb", line: 3,
                                                     constant: "Samagotchi::Session", refs: 2)
    expect(result.findings.first.why).to include("lib/samagotchi/session.rb")
    expect(result.files).to eq(4)
  end

  it "reads an autoload written in a loop as reaching the file it names" do
    expect(check("dynamic_autoload").findings).to be_empty
  end

  it "treats a default argument as a call-time reference, not a load-time one" do
    expect(check("default_arg").findings).to be_empty
  end

  it "ignores names that are not chi's (stdlib and gems)" do
    expect(check("stdlib").findings).to be_empty
  end

  it "reports a load-time reference whose require is below it (rule 2)" do
    result = check("load_time")

    expect(result.findings.map { [_1.rule, _1.path, _1.line, _1.constant] }).to eq(
      [[2, "lib/samagotchi/late.rb", 2, "Samagotchi::Base"],
       [2, "lib/samagotchi/late.rb", 3, "Samagotchi::Mixin"]]
    )
    expect(check("load_time_ok").findings).to be_empty
  end

  it "accepts a require inside a method for rule 1 and not for rule 2" do
    result = check("method_require")

    expect(result.findings.size).to eq(1)
    expect(result.findings.first).to have_attributes(rule: 2, path: "lib/samagotchi/runner.rb", line: 2,
                                                     constant: "Samagotchi::Helper")
    expect(result.findings.first.why).to include("inside a method body")
  end

  it "reports a require cycle as a rule 2 finding even when the require is above the reference" do
    result = check("cycle")

    expect(result.findings.size).to eq(1)
    expect(result.findings.first).to have_attributes(rule: 2, path: "lib/samagotchi/pa.rb", line: 3,
                                                     constant: "Samagotchi::Pb")
    expect(result.findings.first.why).to include("cycle")
  end

  it "resolves a nested name through the file that defines it, and a reopened namespace through any of its files" do
    result = check("nested")

    expect(result.findings.size).to eq(1)
    expect(result.findings.first).to have_attributes(rule: 1, path: "lib/samagotchi/naked.rb", line: 3,
                                                     constant: "Samagotchi::Engine::Loop")
  end

  it "counts a constant by where it is defined, not by the file's name" do
    expect(check("renamed_file").findings).to be_empty
  end

  it "evaluates the File.expand_path form of requires and autoloads" do
    result = check("expand_path")

    expect(result.findings.map(&:path)).to eq(["lib/samagotchi/late_expand.rb"])
    expect(result.findings.first).to have_attributes(rule: 2, line: 2, constant: "Samagotchi::Helper2")
  end

  it "flags an autoload naming a namespace reopened in several files (rule 3), not a single-file one" do
    result = check("autoload")

    expect(result.findings.size).to eq(1)
    expect(result.findings.first).to have_attributes(rule: 3, path: "lib/samagotchi/holder.rb", line: 2,
                                                     constant: "Samagotchi::Widget")
    expect(result.findings.first.why).to include("reopened in 2 files")
  end

  it "drops an allow-listed finding and says when an entry matches nothing" do
    allow = File.join(FIXTURES, "allow_list", "allow.yml")

    expect(check("allow_list", allow: allow).findings).to be_empty
    expect(check("allow_list", allow: File.join(FIXTURES, "allow_list", "stale.yml")).findings.size).to eq(1)
    expect(check("allow_list", allow: allow).allow_used).to eq(1)
    expect(check("allow_list", allow: File.join(FIXTURES, "allow_list", "stale.yml")).allow_stale).to eq(1)
  end

  it "checks bin/chi too" do
    result = check("bin_chi")

    expect(result.files).to eq(2)
    expect(result.findings.map { [_1.rule, _1.path, _1.constant] }).to eq([[1, "bin/chi", "Samagotchi::Session"]])
  end

  it "prints one line per finding and the counts, and exits 0 in report mode" do
    script = File.expand_path("../../script/load-check", __dir__)
    out, status = Open3.capture2(RbConfig.ruby, script, "--limit", "3", "--allow", NO_ALLOW, stdin_data: "")

    expect(status.exitstatus).to eq(0)
    expect(out).to match(/\A[123] \S+:\d+ \S+ — .+\n/)
    expect(out).to match(/findings: \d+ \(rule 1 \d+, rule 2 \d+, rule 3 \d+\) across \d+ references\nby area: .+\nfiles scanned: \d+ .*\nallow-list: \d+ entries matched, \d+ matched nothing\n\z/)
  end

  it "reads script/load_check/allow.yml unless --allow names another" do
    script = File.expand_path("../../script/load-check", __dir__)
    out, _status = Open3.capture2(RbConfig.ruby, script, stdin_data: "")

    expect(out).to match(/^allow-list: [1-9]\d* entries matched/)
  end

  it "exits 1 with --strict when findings remain" do
    script = File.expand_path("../../script/load-check", __dir__)
    _out, status = Open3.capture2(RbConfig.ruby, script, "--strict", "--allow", NO_ALLOW, stdin_data: "")

    expect(status.exitstatus).to eq(1)
  end

  it "exits 1 with --strict and names an unmatched allow-list entry" do
    script = File.expand_path("../../script/load-check", __dir__)
    default_allow = File.expand_path("../../script/load_check/allow.yml", __dir__)
    Dir.mktmpdir("load-check-allow-") do |dir|
      allow = File.join(dir, "allow.yml")
      File.write(allow, File.read(default_allow) + <<~YAML)
        - rule: 2
          file: lib/samagotchi/nowhere.rb
          constant: Samagotchi::Nothing
          reason: fixture entry that matches nothing
      YAML
      _out, err, status = Open3.capture3(RbConfig.ruby, script, "--strict", "--allow", allow, stdin_data: "")

      expect(status.exitstatus).to eq(1)
      expect(err).to include("stale allow-list entry: rule 2 file lib/samagotchi/nowhere.rb constant Samagotchi::Nothing")
    end
  end
end
