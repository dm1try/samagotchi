# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/guardrails"
require "samagotchi/guardrail_wiring"
require "samagotchi/session"

# Every example runs with HOME in a temp dir: nothing here may touch the
# real ~/.ssh or dotfiles.
RSpec.describe Samagotchi::Guardrails::PairBoundary do
  let(:base) { File.realpath(Dir.mktmpdir("pair-boundary")) }
  let(:home) { File.join(base, "home") }
  let(:project) { File.join(home, "work", "proj") }
  let(:state) { File.join(home, ".local", "state", "samagotchi") }
  let(:config) { File.join(home, ".config", "samagotchi") }
  let(:grants) { File.join(state, "web-grants", "grants.json") }
  let(:author) { "p:p_0123abcd" }

  around { |example| with_env("HOME" => home) { example.run } }

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
    described_class.new(author: -> { turn_author }, root: -> { project }, denied_dirs: -> { [state, config] },
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
  def execute(command, **opts) = verdict_for({ name: "execute", content: command }, **opts)

  it "leaves a pair turn's reads, commands and writes to the owner's checks" do
    expect(read("docs/plan.md")).to be_allow
    expect(read(File.join(home, "other", "notes.md"))).to be_allow
    expect(execute("bundle exec rspec spec/foo_spec.rb && git status")).to be_allow
    expect(verdict_for({ name: "write", path: "docs/plan.md", content: "x" })).to be_allow
    expect(verdict_for({ name: "edit", path: "docs/plan.md", old_str: "plan", new_str: "x" })).to be_allow
  end

  it "denies writing chi's files, ~/.ssh, shell startup files and credentials, never asks" do
    targets = [File.join(state, "web-token"), grants, File.join(state, "sessions", "s1", "participants.json"),
               File.join(home, ".ssh", "authorized_keys"), File.join(home, ".zshrc"), File.join(home, ".bashrc"),
               File.join(home, ".gitconfig"), File.join(home, ".config", "gh", "hosts.yml"),
               File.join(home, ".claude.json"), File.join(home, ".zsh_history"), File.join(config, "config.yml"), ".env"]
    targets.each do |path|
      %w[write edit read].each do |tool|
        verdict = verdict_for({ name: tool, path: path, content: path, old_str: "a", new_str: "b" })
        expect(verdict).to be_deny, "#{tool} #{path}"
        expect(verdict.reason).to eq(described_class::SECRET)
      end
    end
  end

  it "asks the owner, fresh and once only, before a write or edit outside the project" do
    outside = File.join(home, "other", "notes.md")
    %w[write edit].each do |tool|
      verdict = verdict_for({ name: tool, path: outside, content: "x", old_str: "notes", new_str: "y" })
      expect(verdict).to be_ask, tool
      expect([verdict.rule, verdict.reason, verdict.scopes]).to eq(["pair-boundary", described_class::OUTSIDE_WRITE, ["once"]])
      expect(verdict).to be_fresh_ask
    end
    expect(verdict_for({ name: "write", path: "docs/new.md", content: "x" })).not_to be_fresh_ask
    expect(verdict_for({ name: "write", path: outside, content: "x" }, turn_author: nil)).to be_allow
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

  def refused(command) = execute(command).then { |verdict| verdict.deny? ? verdict.reason : nil }

  it "denies a command that runs chi, whatever runs it, but chi --version and --help" do
    ["chi share cap abc p_1 1000", "bin/chi send --new hi", "bundle exec chi sessions list", "ruby -Ilib bin/chi answer x",
     "ruby -I lib bin/chi answer x", "FOO=1 /usr/local/bin/chi send x", "sh -c 'chi share abc --name x'",
     "echo $(chi sessions list)", "env X=1 nohup chi send x", "timeout 10 chi send x", "eval chi send x"].each do |command|
      expect(refused(command)).to eq(described_class::CHI), command
    end
    ["chi --version", "chi --help", "grep chi README.md", "git commit -m 'chi: fix the probe'", "ls lib/chi"].each do |command|
      expect(refused(command)).to be_nil, command
    end
  end

  it "denies leaving a command running in the background" do
    ["sleep 100 &", "nohup ruby server.rb", "setsid ruby server.rb", "ruby server.rb & disown",
     "screen -dmS x ruby server.rb", "tmux new -d ruby server.rb", "a && b &"].each do |command|
      expect(refused(command)).to eq(described_class::BACKGROUND), command
    end
    ["a && b", "ruby x.rb 2>&1 | tail", "ruby x.rb > out.log 2>&1"].each { |command| expect(refused(command)).to be_nil, command }
  end

  it "denies reading the environment or the keychain" do
    ["env", "env -0", "printenv", "printenv HOME", "security find-generic-password -s chi -w", "cat /proc/1/environ",
     "X=1 env"].each do |command|
      expect(refused(command)).to eq(described_class::ENVIRONMENT), command
    end
    expect(refused("env RAILS_ENV=test bundle exec rspec")).to be_nil
  end

  it "denies a glob or a $var that leads into a secret, and sweeping a folder above one" do
    File.write(File.join(home, ".zsh_history"), "x")
    ["cat ~/.ss?/id_*", "cat ~/.config/*/config.yml", "cat .en?", "cat ~/.ss${d}h/id_rsa", "cat $HOME/.zsh_hist*",
     "cat ~/$X", "cat #{home}/.ss$X/id_rsa"].each do |command|
      expect(refused(command)).to eq(described_class::SECRET), command
    end
    ["find ~ -name id_rsa", "tar cf - ~", "cp -r ~/.local /tmp/x", "grep -r token ~", "rsync -a ~/ /tmp/x",
     "cd ~ && find . -name x"].each do |command|
      expect(refused(command)).to eq(described_class::HOME_SWEEP), command
    end
    ["ls docs/*.md", "grep -r plan .", "find . -name '*.md'", "cat docs/pl?n.md", "ls ~/other"].each do |command|
      expect(refused(command)).to be_nil, command
    end
  end

  it "denies the owner-voiced tools, any delegate_* tool and every memory_write" do
    (described_class::OWNER_VOICED + %w[cancel_reminder task_stop find_tools delegate_result]).each do |tool|
      verdict = verdict_for({ name: tool, content: "x" })
      expect(verdict).to be_deny, tool
      expect(verdict.reason).to eq(format(described_class::OWNER_ONLY, tool))
    end
    %w[system project].each do |scope|
      verdict = verdict_for({ name: "memory_write", path: "notes", scope: scope, content: "x" })
      expect(verdict.reason).to eq(described_class::MEMORY_WRITE)
    end
  end

  it "denies ask_user_question with advice to ask in the reply" do
    verdict = verdict_for({ name: "ask_user_question", content: "which?" })
    expect(verdict).to be_deny
    expect(verdict.reason).to eq(described_class::ASK)
    expect(verdict.deny_text).to include("ask in your reply")
  end
end

RSpec.describe "GuardrailWiring: a participant's boundary by ParticipantMode" do
  let(:base) { File.realpath(Dir.mktmpdir("pair-wiring")) }
  let(:project) { File.join(base, "proj") }
  let(:author) { "p:p_0123abcd" }
  let(:working) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: project) }
  let(:review) { Struct.new(:id, :working_directory) { def review? = true; def delegate? = false }.new("s1", project) }
  # A participant invited to act (their grant's mode), or one from before pair (none).
  let(:pair_entry) { Struct.new(:name, :mode).new("Sam", "pair") }

  around { |example| with_env("HOME" => File.join(base, "home")) { example.run } }

  before { FileUtils.mkdir_p(File.join(project, "docs")) }
  after { FileUtils.rm_rf(base) }

  def wiring(session, entry: pair_entry)
    Samagotchi::GuardrailWiring.new(scratch: false, hooks: -> {}, tools: -> {}, session: -> { session },
                                    model_key: -> {}, cancelled: -> { false }, ask: ->(_) {},
                                    participant: ->(_author) { entry }).tap do |w|
      w.state_dir = File.join(base, "state")
      w.begin_turn({ client_id: "review:p_0123abcd", author: author })
    end
  end

  def evaluate(wiring, call) = wiring.gate.evaluate(call, iteration: 1, params: "")

  it "seats PairBoundary for a working session and ReviewBoundary for a review session" do
    pair = wiring(working)
    expect(pair.checks[1]).to be(pair.pair_boundary)
    expect(pair.checks).not_to include(pair.review_boundary)
    reviewing = wiring(review)
    expect(reviewing.checks[1]).to be(reviewing.review_boundary)
    expect(reviewing.checks).not_to include(reviewing.pair_boundary)
  end

  it "keeps a working session's participant invited before pair (no grant mode, or unknown) in the review boundary" do
    [Struct.new(:name, :mode).new("Old", nil), nil].each do |entry|
      w = wiring(working, entry: entry)
      expect(w.turn_mode).to eq(:review)
      expect(w.checks[1]).to be(w.review_boundary)
      write = evaluate(w, { name: "write", path: File.join(project, "docs", "plan.md"), content: "x" })
      expect(write.rule).to eq("review-boundary")
    end
  end

  it "lets a pair turn write and execute under the owner's rules, never secrets or owner-voiced tools" do
    w = wiring(working)
    write = evaluate(w, { name: "write", path: File.join(project, "docs", "plan.md"), content: "x" })
    expect(write.rule).not_to eq("pair-boundary")
    expect(write).not_to be_deny
    execute = evaluate(w, { name: "execute", content: "ls docs", cwd: project })
    expect(execute).not_to be_deny
    grants = File.join(Samagotchi::Paths.state_dir, "web-grants", "grants.json")
    expect(evaluate(w, { name: "read", content: grants }).rule).to eq("pair-boundary")
    expect(evaluate(w, { name: "read", content: File.join(Dir.home, ".ssh", "id_rsa") }).rule).to eq("pair-boundary")
    expect(evaluate(w, { name: "read", content: File.join(project, ".env") }).rule).to eq("pair-boundary")
    %w[delegate send_note].each { |tool| expect(evaluate(w, { name: tool, content: "x" })).to be_deny }
    chi = evaluate(w, { name: "execute", content: "chi share cap x p_1 1000", cwd: project })
    expect([chi.rule, chi.reason]).to eq(["pair-boundary", Samagotchi::Guardrails::PairBoundary::CHI])
    expect(evaluate(w, { name: "memory_write", path: "n", scope: "system", content: "x" }).rule).to eq("pair-boundary")
  end

  it "asks the owner before a pair turn writes outside the project, even with the owner's stored approval" do
    asked = []
    session = working
    w = Samagotchi::GuardrailWiring.new(scratch: false, hooks: -> {}, tools: -> {}, session: -> { session },
                                        model_key: -> {}, cancelled: -> { false }, participant: ->(_a) { pair_entry },
                                        ask: lambda { |payload|
                                          asked << payload
                                          Samagotchi::QuestionAnswer.new(id: "q", selected: ["Deny"], selected_indices: [1])
                                        })
    w.state_dir = File.join(base, "state")
    w.interface = :worker
    outside = File.join(base, "elsewhere.txt")
    call = { name: "write", path: outside, content: "x" }
    w.begin_turn({ client_id: "web:o" })
    owner = evaluate(w, call)
    owner.ask!("owner asked", scopes: %w[session], rule: "x", source: "config")
    owner.settle!(:allow)
    owner.scope = "session"
    w.approvals.add(owner, "session")
    w.begin_turn({ client_id: "review:p_0123abcd", author: author })
    verdict = w.gate.settle_ask(evaluate(w, call))

    expect(asked.size).to eq(1)
    expect(asked.first[:approval]).to include(rule: "pair-boundary", scopes: ["once"], author: author)
    expect(verdict).to be_deny
  end

  it "keeps a review session's participant turn read-only" do
    w = wiring(review)
    write = evaluate(w, { name: "write", path: File.join(project, "docs", "plan.md"), content: "x" })
    expect(write).to be_deny
    expect(write.rule).to eq("review-boundary")
  end
end
