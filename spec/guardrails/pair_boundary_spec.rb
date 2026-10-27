# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/guardrails"

RSpec.describe Samagotchi::Guardrails::PairBoundary do
  let(:base) { File.realpath(Dir.mktmpdir("pair-boundary")) }
  let(:home) { File.join(base, "home") }
  let(:project) { File.join(home, "work", "proj") }
  let(:state) { File.join(home, ".local", "state", "samagotchi") }
  let(:config) { File.join(home, ".config", "samagotchi") }
  let(:grants) { File.join(state, "web-grants", "grants.json") }
  let(:author) { "p:p_0123abcd" }

  before do
    FileUtils.mkdir_p([File.join(project, "docs"), File.join(home, ".ssh"), File.dirname(grants), config,
                       File.join(home, "other")])
    File.write(File.join(project, "docs", "plan.md"), "plan\n")
    File.write(File.join(project, ".env"), "TOKEN=x\n")
    File.write(File.join(home, ".ssh", "id_rsa"), "key\n")
    File.write(File.join(home, "other", "notes.md"), "notes\n")
    File.write(grants, "{}\n")
  end

  after { FileUtils.rm_rf(base) }

  def boundary(turn_author: author)
    described_class.new(author: -> { turn_author }, denied_dirs: -> { [state, config] }, home: -> { home })
  end

  def verdict_for(call, **opts)
    context = Samagotchi::Guardrails::Context.new(cwd: project)
    verdict = Samagotchi::Guardrails::Verdict.new(call: call)
    verdict.context = context
    verdict.targets = Samagotchi::Guardrails::Targets.for(call, context)
    boundary(**opts).check(verdict)
  end

  def read(path, **opts) = verdict_for({ name: "read", content: path }, **opts)
  def execute(command, **opts) = verdict_for({ name: "execute", content: command }, **opts)

  it "leaves a pair turn's reads, commands and writes to the owner's checks" do
    expect(read("docs/plan.md")).to be_allow
    expect(read(File.join(home, "other", "notes.md"))).to be_allow
    expect(execute("bundle exec rspec spec/foo_spec.rb && git status")).to be_allow
    expect(verdict_for({ name: "write", path: "docs/plan.md", content: "x" })).to be_allow
    expect(verdict_for({ name: "edit", path: "docs/plan.md", old_str: "plan", new_str: "x" })).to be_allow
    expect(verdict_for({ name: "memory_write", path: "notes", scope: "project", content: "x" })).to be_allow
  end

  it "is off for the owner's turns" do
    expect(read(grants, turn_author: nil)).to be_allow
    expect(execute("cat ~/.ssh/id_rsa", turn_author: "owner")).to be_allow
    expect(verdict_for({ name: "delegate", content: "x" }, turn_author: nil)).to be_allow
  end

  it "denies reading grants.json, ~/.ssh and a project .env, never asks" do
    [grants, File.join(home, ".ssh", "id_rsa"), ".env", File.join(config, "config.yml")].each do |path|
      verdict = read(path)
      expect(verdict).to be_deny, path
      expect(verdict.reason).to eq(described_class::SECRET)
      expect(verdict.rule).to eq("pair-boundary")
      expect(verdict.deny_text).to include(described_class::ADVICE)
    end
  end

  it "denies a symlink that leads to a secret" do
    File.symlink(File.join(home, ".ssh"), File.join(project, "keys"))
    expect(read("keys/id_rsa").reason).to eq(described_class::SECRET)
  end

  it "denies a command that names a secret, resolved or by its text" do
    ["cat ~/.ssh/id_rsa", "cat .env", "cd ~ && cat .ssh/id_rsa", "cat #{grants}",
     "cat $HOME/.local/state/samagotchi/web-grants/grants.json", "cat $(echo ~/.ssh/id_rsa)",
     "cat $SECRET_DIR/.env", "ls #{config}"].each do |command|
      verdict = execute(command)
      expect(verdict).to be_deny, command
      expect(verdict.reason).to eq(described_class::SECRET), command
    end
  end

  it "denies the owner-voiced tools and a memory_write outside the project scope" do
    described_class::OWNER_VOICED.each do |tool|
      verdict = verdict_for({ name: tool, content: "x" })
      expect(verdict).to be_deny, tool
      expect(verdict.reason).to eq(format(described_class::OWNER_ONLY, tool))
    end
    verdict = verdict_for({ name: "memory_write", path: "notes", scope: "system", content: "x" })
    expect(verdict.reason).to eq(described_class::MEMORY_SCOPE)
  end

  it "denies ask_user_question with advice to ask in the reply" do
    verdict = verdict_for({ name: "ask_user_question", content: "which?" })
    expect(verdict).to be_deny
    expect(verdict.reason).to eq(described_class::ASK)
    expect(verdict.deny_text).to include("ask in your reply")
  end
end
