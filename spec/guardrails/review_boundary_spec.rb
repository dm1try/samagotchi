# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/guardrails"
require "samagotchi/guardrail_wiring"

RSpec.describe Samagotchi::Guardrails::ReviewBoundary do
  let(:base) { File.realpath(Dir.mktmpdir("review-boundary")) }
  let(:home) { File.join(base, "home") }
  let(:project) { File.join(home, "work", "proj") }
  let(:state) { File.join(home, ".local", "state", "samagotchi") }
  let(:config) { File.join(home, ".config", "samagotchi") }
  let(:author) { "p:p_0123abcd" }

  before do
    FileUtils.mkdir_p([File.join(project, "docs"), File.join(project, ".git"), File.join(home, ".ssh"), state, config])
    File.write(File.join(project, "docs", "plan.md"), "plan\n")
    File.write(File.join(home, ".ssh", "id_rsa"), "key\n")
  end

  after { FileUtils.rm_rf(base) }

  def boundary(turn_author: author, root: project)
    described_class.new(author: -> { turn_author }, root: -> { root }, denied_dirs: -> { [state, config] },
                        home: -> { home })
  end

  def verdict_for(call, **opts)
    context = Samagotchi::Guardrails::Context.new(cwd: project)
    verdict = Samagotchi::Guardrails::Verdict.new(call: call)
    verdict.context = context
    verdict.targets = Samagotchi::Guardrails::Targets.for(call, context)
    boundary(**opts).check(verdict)
  end

  def read(path, **opts) = verdict_for({ name: "read", content: path }, **opts)

  it "lets a participant read the project" do
    expect(read("docs/plan.md")).to be_allow
    expect(read(File.join(project, "docs", "plan.md"))).to be_allow
  end

  it "is off for the owner's turns" do
    expect(read(File.join(home, ".ssh", "id_rsa"), turn_author: nil)).to be_allow
    expect(read(File.join(home, ".ssh", "id_rsa"), turn_author: "owner")).to be_allow
    expect(verdict_for({ name: "write", path: "x", content: "y" }, turn_author: nil)).to be_allow
  end

  it "denies a read outside the project, ~/.ssh included" do
    verdict = read(File.join(home, ".ssh", "id_rsa"))
    expect(verdict).to be_deny
    expect(verdict.reason).to eq(described_class::OUTSIDE)
    expect(verdict.rule).to eq("review-boundary")
    expect(read("../../../.ssh/id_rsa").reason).to eq(described_class::OUTSIDE)
  end

  it "denies a symlink in the project that leads out of it" do
    File.symlink(File.join(home, ".ssh"), File.join(project, "keys"))
    expect(read("keys/id_rsa").reason).to eq(described_class::OUTSIDE)
  end

  it "denies the project's secret files and chi's own dirs inside it" do
    %w[.env .env.local .envrc .env-local .env_production config/.netrc certs/server.pem tls/site.key .aws/credentials
       credentials.json .git-credentials config/credentials.yml.enc .git/config .git/modules/sub/config .npmrc .pypirc
       keys/id_ed25519 .docker/config.json infra/terraform.tfstate config/secrets.yml].each do |path|
      expect(read(path).reason).to eq(described_class::SECRET), path
    end
    expect(read(".git/HEAD")).to be_allow
    expect(read("docs/environment.md")).to be_allow
    inside = File.join(project, "chi-state")
    FileUtils.mkdir_p(inside)
    checker = described_class.new(author: -> { author }, root: -> { project }, denied_dirs: -> { [inside] }, home: -> { home })
    verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "read", content: File.join(inside, "web-token") })
    verdict.targets = Samagotchi::Guardrails::Targets.for(verdict.call, Samagotchi::Guardrails::Context.new(cwd: project))
    expect(checker.check(verdict).reason).to eq(described_class::SECRET)
  end

  it "denies every read when the session's folder is the home folder or above it" do
    expect(read(File.join(home, "notes.txt"), root: home).reason).to eq(described_class::HOME_ROOT)
    expect(read(File.join(home, "notes.txt"), root: base).reason).to eq(described_class::HOME_ROOT)
  end

  it "denies every read without a project root" do
    expect(read("docs/plan.md", root: nil).reason).to eq(described_class::OUTSIDE)
  end

  it "allows memory_read in the project scope only" do
    expect(verdict_for({ name: "memory_read", content: "notes", scope: "project" })).to be_allow
    expect(verdict_for({ name: "memory_read", content: "notes", scope: "system" }).reason).to eq(described_class::MEMORY_SCOPE)
    expect(verdict_for({ name: "memory_read", content: "notes" }).reason).to eq(described_class::MEMORY_SCOPE)
  end

  it "denies forget_outputs: it would rewrite the owner's earlier outputs with the participant's note" do
    expect(verdict_for({ name: "forget_outputs", content: "[]" }).reason).to eq(format(described_class::NOT_IN_KIT, "forget_outputs"))
  end

  it "denies, never asks, every other tool" do
    %w[write edit memory_write execute task_create task_wait delegate delegate_result send_note list_sessions
       register_reminder web_fetch context_read ask_user_question call_tool find_tools load_tools forget_outputs].each do |tool|
      verdict = verdict_for({ name: tool, content: "x", path: "docs/plan.md" })
      expect(verdict).to be_deny, tool
      expect(verdict.reason).to eq(format(described_class::NOT_IN_KIT, tool)), tool
      expect(verdict.deny_text).to include(described_class::ADVICE)
    end
  end

  describe "in GuardrailWiring" do
    let(:session) { Struct.new(:id, :working_directory) { def delegate? = false }.new("s1", project) }
    let(:wiring) do
      Samagotchi::GuardrailWiring.new(scratch: false, hooks: -> {}, tools: -> {}, session: -> { session },
                                      model_key: -> {}, cancelled: -> { false }, ask: ->(_) {}).tap do |w|
        w.state_dir = File.join(base, "state")
      end
    end

    it "comes before the rules, for a participant's turn only" do
      expect(wiring.checks.index(wiring.review_boundary)).to eq(1)
      wiring.begin_turn({ client_id: "review:p_0123abcd", author: author })
      verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "write", path: "docs/plan.md", content: "x" })
      verdict.targets = Samagotchi::Guardrails::Targets.for(verdict.call, Samagotchi::Guardrails::Context.new(cwd: project))
      expect(wiring.review_boundary.check(verdict)).to be_deny
      wiring.begin_turn({ client_id: "web:tab" })
      verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "write", path: "docs/plan.md", content: "x" })
      expect(wiring.review_boundary.check(verdict)).to be_allow
    end
  end
end
