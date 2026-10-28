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
  # The spec's own dirs are all under Dir.tmpdir, which therefore is no tmp
  # dir for this project (Outside.tmp_write?): +tmp+ is one that is.
  let(:tmp) { Samagotchi::Guardrails::Outside.tmp_roots.find { |dir| !base.start_with?(File.join(dir, "")) } }

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

  it "asks before every write in a session whose folder is the home folder or above it, as review reads nothing there" do
    [home, File.dirname(home)].each do |root|
      at_home = described_class.new(author: -> { author }, root: -> { root }, denied_dirs: -> { [state, config] },
                                    home: -> { home })
      context = Samagotchi::Guardrails::Context.new(cwd: home)
      [{ name: "write", path: File.join(home, ".vimrc"), content: "x" },
       { name: "execute", content: "echo x > ~/.tmux.conf" }].each do |call|
        verdict = Samagotchi::Guardrails::Verdict.new(call: call)
        verdict.context = context
        verdict.targets = Samagotchi::Guardrails::Targets.for(call, context)
        at_home.check(verdict)
        expect(verdict).to be_ask, "#{root} #{call}"
        expect([verdict.reason, verdict]).to match([described_class::NO_PROJECT, be_fresh_ask])
      end
    end
    expect(Samagotchi::Guardrails::ReviewPaths.home_root?(home, home)).to be(true)
    expect(Samagotchi::Guardrails::ReviewPaths.home_root?(project, home)).to be(false)
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

  it "denies a `..` that climbs out of a symlinked dir's target into a secret, in a call or a command" do
    FileUtils.mkdir_p([File.join(home, "src", "foo"), File.join(project, "node_modules"), File.join(home, ".config", "gh")])
    File.write(File.join(home, ".config", "gh", "hosts.yml"), "token\n")
    File.symlink(File.join(home, "src", "foo"), File.join(project, "node_modules", "foo"))
    climb = "node_modules/foo/../../.config/gh/hosts.yml"
    expect(read(climb).reason).to eq(described_class::SECRET)
    expect(verdict_for({ name: "write", path: climb, content: "x" }).reason).to eq(described_class::SECRET)
    expect(execute("cat #{climb}").reason).to eq(described_class::SECRET)
    expect(execute("cd node_modules/foo && cat ../../.config/gh/hosts.yml").reason).to eq(described_class::SECRET)
    # zsh's and bash's cd go physical where the logical dir doesn't exist,
    # and always with -P: either dir counts.
    expect(execute("cd node_modules/foo/../../.config/gh && cat hosts.yml").reason).to eq(described_class::SECRET)
    expect(execute("cd -P node_modules/foo/../.. && cat .config/gh/hosts.yml").reason).to eq(described_class::SECRET)
    expect(execute("pushd node_modules/foo/../../.config/gh && cat hosts.yml").reason).to eq(described_class::SECRET)
    expect(execute("cd node_modules/foo/../../.config/gh && echo x > hosts.yml").reason).to eq(described_class::SECRET)
    # It stays inside either way.
    expect(execute("cd node_modules/foo/.. && cat foo/README")).to be_allow
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

  describe "a command with a heredoc, a script or a value" do
    it "reads the rest of a command after a data heredoc, and a heredoc handed to a shell or interpreter" do
      File.write(File.join(home, "notes"), "x")
      {
        "cat <<EOF > docs/notes.md\nx\nEOF\ncat ~/.ss?/id_*" => described_class::SECRET,
        "bash <<EOF\nchi send x\nEOF" => described_class::CHI,
        "sh <<'EOF'\nsleep 9 &\nEOF" => described_class::BACKGROUND,
        "bash <<EOF\ncat ~/.ss?/id_*\nEOF" => described_class::SECRET,
        "python3 - <<EOF\nimport os; print(os.environ)\nEOF" => described_class::ENVIRONMENT,
        "ruby <<EOF\nsystem('chi send x')\nEOF" => described_class::CHI,
        "bash <<< 'chi send x'" => described_class::CHI
      }.each { |command, reason| expect(refused(command)).to eq(reason), command }
    end

    it "lets a heredoc that is written as data say anything" do
      ["cat <<EOF > docs/notes.md\nthe credentials doc: chi send, printenv, /proc/1/environ, sleep 9 &, ~/.ssh\nEOF",
       "git commit -F - <<EOF\nchi: read credentials from the keychain\nEOF",
       "tee docs/x.md <<'EOF'\nchi share x\nEOF"].each { |command| expect(refused(command)).to be_nil, command }
    end

    it "refuses a command it can't read, never letting it through on a text match" do
      allow(Samagotchi::Guardrails::ShellLex).to receive(:lex).and_raise(ArgumentError, "bad")
      expect(refused("ls")).to eq(described_class::UNREADABLE)
    end

    it "finds chi in values, functions, keywords, -exec/-c/-e arguments and other wrappers" do
      ["alias x='chi send'", "f=chi; $f x", "find . -name x -exec chi send {} ;", "watch -n 2 chi sessions list",
       "npx chi x", "f() { chi send; }; f", "if true; then chi x; fi", "! chi x", "ruby -e 'system(\"chi send\")'",
       "python3 -c \"import os; os.system('chi x')\"", "xargs -I{} chi send {}"].each do |command|
        expect(refused(command)).to eq(described_class::CHI), command
      end
    end

    it "reads a shell's -c script for backgrounding and the environment" do
      expect(refused("bash -c 'sleep 9 &'")).to eq(described_class::BACKGROUND)
      expect(refused("sh -c 'printenv'")).to eq(described_class::ENVIRONMENT)
    end

    it "denies the environment listers, and leaves their setting forms" do
      ["set", "export", "export -p", "declare -x", "typeset", "launchctl getenv HOME", "ps eww", "ps auxe"].each do |command|
        expect(refused(command)).to eq(described_class::ENVIRONMENT), command
      end
      ["set -euo pipefail", "export FOO=1", "declare -a list", "ps aux", "ps -ef"].each do |command|
        expect(refused(command)).to be_nil, command
      end
    end

    it "denies git settings that run commands and git config beyond the repository" do
      ["git config --global core.editor vim", "git config --system x.y z", "git config core.hooksPath .h",
       "git config core.fsmonitor ./x", "git -c core.sshCommand=./x fetch", "git -C . -c core.pager=./x log",
       "git config alias.x '!rm -rf build'"].each do |command|
        expect(refused(command)).to eq(described_class::GIT_CONFIG), command
      end
      ["git config user.name Sam", "git config alias.co checkout", "git -c color.ui=false log", "git status"].each do |command|
        expect(refused(command)).to be_nil, command
      end
    end

    it "denies writing the shell's and git's config, launch agents and ~/.local/bin, and sweeping with ditto" do
      ["echo x > ~/.config/fish/conf.d/x.fish", "cp evil ~/Library/LaunchAgents/x.plist", "ln -s x ~/.local/bin/git",
       "echo x >> ~/.config/git/config"].each do |command|
        expect(refused(command)).to eq(described_class::SECRET), command
      end
      expect(refused("ditto ~ /tmp/x")).to eq(described_class::HOME_SWEEP)
    end
  end

  it "asks the owner, fresh and once only, before a command writes outside the project, never for a tmp dir" do
    other = File.join(home, "other")
    ["echo x > #{other}/out.txt", "ls | tee #{other}/o", "cp docs/plan.md #{other}/", "echo x > $OUT",
     "echo x 2>#{other}/err", "mv docs/plan.md -t #{other}"].each do |command|
      verdict = execute(command)
      expect(verdict).to be_ask, command
      expect([verdict.reason, verdict.scopes]).to eq([described_class::OUTSIDE_WRITE, ["once"]])
      expect(verdict).to be_fresh_ask
    end
    ["echo x > docs/out.txt", "ls > /dev/null 2>&1", "echo x > #{tmp}/x", "cp docs/plan.md #{tmp}/"].each do |command|
      expect(execute(command)).to be_allow, command
    end
    expect(verdict_for({ name: "write", path: File.join(tmp, "x.txt"), content: "x" })).to be_allow
  end

  describe "a command that may write outside the project (fails closed)" do
    def asks?(command)
      verdict = execute(command)
      verdict.ask? && verdict.reason == described_class::OUTSIDE_WRITE && verdict.fresh_ask?
    end

    it "asks for any writer that names a path outside, not only redirections and copiers" do
      ["rm -rf ~/other", "sed -i s/a/b/ ~/other/notes.md", "curl -o ~/other/x https://example.com",
       "dd if=/dev/zero of=~/other/x count=1", "touch ~/other/x", "mkdir ~/other/y", "perl -pi -e 's/a/b/' ~/other/x",
       "python3 -c \"open('#{home}/other/x', 'w').write('x')\"", "bash -c 'rm -rf ~/other'", "find ~/other -delete",
       "git -C ~/other commit -m x", "GIT_DIR=../x git commit -m y", "cp docs/plan.md ~/other/"].each do |command|
        expect(asks?(command)).to be(true), command
      end
    end

    it "asks for a command it can't place: a dir it can't tell, a $var, a $(…), xargs" do
      ["cd .. && make", "cd && make", "cd $X && make", "ls | xargs rm", "rm -rf $DIR", "kill $(cat tmp/pid)",
       "echo hi > \"$OUT\"", "rm -rf ~/oth*"].each do |command|
        expect(asks?(command)).to be(true), command
      end
    end

    it "lets in-project work run: builds, tests, edits, git and reads anywhere" do
      ["bundle exec rspec spec/foo_spec.rb && git status", "npm test", "make", "ruby script.rb", "sh ./run.sh",
       "git commit -am 'fix the thing'", "sed -i '' s/a/b/ docs/plan.md", "rm -rf build", "mkdir -p tmp/x",
       "rm -f docs/*.o", "cd docs && touch x.md", "find . -name '*.o' -delete", "python3 -c 'print(1)'",
       "git commit -m \"$(cat <<'EOF'\nfix: x ~/y\nEOF\n)\"", "cat ~/other/notes.md | grep x", "cp ~/other/notes.md docs/",
       "echo x > #{tmp}/out && cat #{tmp}/out", "PATH=/usr/local/bin:$PATH make"].each do |command|
        expect(execute(command)).to be_allow, command
      end
    end

    it "asks for a tmp path that lands elsewhere: a dangling symlink, a file with another hard link" do
      dir = Dir.mktmpdir("pair-tmp", tmp)
      File.symlink(File.join(home, "other", "new.txt"), File.join(dir, "dangle"))
      File.link(File.join(home, "other", "notes.md"), File.join(dir, "hard"))
      [File.join(dir, "dangle"), File.join(dir, "hard")].each do |path|
        expect(verdict_for({ name: "write", path: path, content: "x" })).to be_ask, path
        expect(asks?("echo hi > #{path}")).to be(true), path
      end
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "asks for a project in a tmp dir that writes to that tmp dir beside it" do
      expect(asks?("echo x > #{File.join(base, "elsewhere.txt")}")).to be(true)
      expect(verdict_for({ name: "write", path: File.join(base, "elsewhere.txt"), content: "x" })).to be_ask
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

  # The spec's dirs are under Dir.tmpdir, which a pair turn writes into freely.
  before do
    FileUtils.mkdir_p(File.join(project, "docs"))
  end

  around { |example| with_env("HOME" => File.join(base, "home")) { example.run } }

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

RSpec.describe "GuardrailWiring: a Verify fresh child's boundary" do
  let(:base) { File.realpath(Dir.mktmpdir("fresh-wiring")) }
  let(:project) { File.join(base, "proj") }
  let(:anchor) { { "turn_id" => "11111111-2222-3333-4444-555555555555", "quote" => "claim" } }

  before do
    FileUtils.mkdir_p(File.join(project, "docs"))
  end

  around { |example| with_env("HOME" => File.join(base, "home")) { example.run } }

  after { FileUtils.rm_rf(base) }

  def child(fresh)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: project, parent_id: "parent",
                                    delegate: true).tap { |s| s.verify_fresh = fresh }
  end

  # The child has no participants.json: the author's lookup finds nobody
  # (nil), or someone the parent invited to act (a pair entry).
  def wiring(session, entry: nil, author: "p:alex")
    Samagotchi::GuardrailWiring.new(scratch: false, hooks: -> {}, tools: -> {}, session: -> { session },
                                    model_key: -> {}, cancelled: -> { false }, ask: ->(_) {},
                                    participant: ->(_author) { entry }).tap do |w|
      w.state_dir = File.join(base, "state")
      w.begin_turn(session.verify_fresh.origin_for(Samagotchi::TurnOrigin.new(client_id: "web:x", author: author)))
    end
  end

  def write(w) = w.gate.evaluate({ name: "write", path: File.join(project, "docs", "plan.md"), content: "x" },
                                 iteration: 1, params: "")

  it "keeps a review requester's child read-only though the child's own lookup finds nobody" do
    w = wiring(child({ "author" => "p:alex", "mode" => "review", "of" => "c1", "anchor" => anchor }), author: nil)
    expect(w.turn_author).to eq("p:alex")
    expect(w.turn_mode).to eq(:review)
    expect(write(w).rule).to eq("review-boundary")
  end

  it "runs a pair requester's child under PairBoundary from the saved mode, not the lookup" do
    w = wiring(child({ "author" => "p:alex", "mode" => "pair", "of" => "c1", "anchor" => anchor }),
               entry: Struct.new(:name, :mode).new("Alex", nil))
    expect(w.turn_mode).to eq(:pair)
    expect(w.checks[1]).to be(w.pair_boundary)
    expect(w.gate.evaluate({ name: "delegate", content: "x" }, iteration: 1, params: "")).to be_deny
  end

  it "fails closed to review for a field that doesn't read" do
    w = wiring(child({ "author" => "p:alex", "mode" => "root", "of" => "c1", "anchor" => anchor }), author: nil)
    expect(w.turn_mode).to eq(:review)
    expect(write(w).rule).to eq("review-boundary")
  end

  it "leaves the owner's child as any delegate child (the owner's turns, ChildBoundary)" do
    w = wiring(child({ "of" => "c1", "anchor" => anchor }), author: nil)
    expect([w.turn_author, w.turn_mode]).to eq([nil, nil])
    expect(w.checks).to include(w.child_boundary)
  end
end
