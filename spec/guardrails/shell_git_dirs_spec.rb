# frozen_string_literal: true

require "samagotchi/guardrails/shell_git_dirs"

# Where a shell command runs a git subcommand that changes a checkout: a
# text heuristic for honest mistakes (cd into another checkout, git -C),
# not a boundary. Session cwd /p/wt, home /home/u.
RSpec.describe Samagotchi::Guardrails::ShellGitDirs do
  def dirs(command, cwd: "/p/wt") = described_class.for(command, cwd: cwd, home: "/home/u")

  table = {
    "cd /p/main && git commit -m x" => ["/p/main"],
    "git -C /p/main commit -am x" => ["/p/main"],
    "pushd ../main && git add . && popd" => ["/p/main"],
    "(cd /p/main && git stash) && git commit -m y" => ["/p/main", "/p/wt"],
    "git --git-dir=/p/main/.git --work-tree=/p/main add ." => ["/p/main"],
    "git --git-dir /p/main/.git commit -m x" => ["/p/main"],
    "git --git-dir=/p/bare.git push" => ["/p/bare.git"],
    "GIT_DIR=/p/main/.git git commit -m x" => ["/p/main"],
    "GIT_WORK_TREE=/p/main GIT_DIR=/p/main/.git git add ." => ["/p/main"],
    "cd /p/main && GIT_EDITOR=true git rebase --continue" => ["/p/main"],
    "cd /p/main 2>/dev/null && git -c core.editor=true commit --amend" => ["/p/main"],
    "cd /p/main\ngit add x" => ["/p/main"],
    "cd ~/projects/samagotchi && git checkout -b x" => ["/home/u/projects/samagotchi"],
    "cd $HOME/x && git add ." => ["/home/u/x"],
    "cd ${HOME}/x && git add ." => ["/home/u/x"],
    "cd && git add ." => ["/home/u"],
    "cd .. && git commit -m x" => ["/p"],
    "git -C /p -C main commit" => ["/p/main"],
    "/usr/bin/git -C /p/main push" => ["/p/main"],
    "if cd /p/main; then git commit -m x; fi" => ["/p/main"],
    "env GIT_DIR=/p/main/.git git commit -m x" => ["/p/main"],
    "cd /p/main && git status && git log -3" => [],
    "git -C /p/main log --oneline" => [],
    "cd /p/main && git stash list" => [],
    "cd /p/main && git stash show -p" => [],
    "cd /p/main && bundle exec rspec spec/x_spec.rb" => [],
    "git commit -m 'cd /p/main'" => ["/p/wt"],
    "echo \"cd /p/main && git commit\"" => [],
    "cd lib && git add foo.rb" => ["/p/wt/lib"],
    "cd /p/main; cd /p/wt && git commit -m x" => ["/p/wt"],
    "git worktree add ../x -b y" => [],
    "cd /p/main && git worktree add ../x -b y" => [],
    "cd /tmp/sbx && git init && git commit" => ["/tmp/sbx"],
    "cd $REPO && git commit" => [:unknown],
    "cd \"$(git rev-parse --show-toplevel)\" && git add ." => [:unknown],
    "cd `pwd` && git add ." => [:unknown],
    "cd - && git commit" => [:unknown],
    "sh -c 'cd /p/main && git commit'" => [],
    "cd /p/main # && git commit" => [],
    "git push 2>&1 && cd /p/main" => ["/p/wt"],
    "git -C /p/main push |& tee log" => ["/p/main"],
    "cd /p/main;; git add x" => ["/p/main"],
    "cat <<EOF\nit's\nEOF\ngit push origin main" => ["/p/wt"],
    "cat <<-'EOF'\n\tit's\n\tEOF\ncd /p/main && git push" => ["/p/main"],
    "cat >/tmp/n <<'EOF'\ngit push origin main\nEOF" => [],
    "git commit -m \"$(cat <<'EOF'\nit's\nEOF\n)\" && git push" => ["/p/wt", "/p/wt"].uniq
  }.freeze

  table.each do |command, expected|
    it "#{command.inspect} -> #{expected.inspect}" do
      expect(dirs(command)).to eq(expected)
    end
  end

  %w[commit add reset checkout switch rebase merge push stash rm mv cherry-pick revert pull restore am].each do |sub|
    it "counts git #{sub} as changing the checkout" do
      expect(dirs("git -C /p/main #{sub} x")).to eq(["/p/main"])
    end
  end

  %w[status log diff show fetch branch tag worktree config clean init help blame grep].each do |sub|
    it "doesn't count git #{sub}" do
      expect(dirs("git -C /p/main #{sub} x")).to eq([])
    end
  end

  it "starts from the call's cwd" do
    expect(dirs("git commit -m x", cwd: "/p/main")).to eq(["/p/main"])
  end

  it "resolves an absolute -C or cd after an unknown dir" do
    expect(dirs("cd $X && git -C /p/main add . && cd /p/other && git add .")).to eq(["/p/main", "/p/other"])
    expect(dirs("cd $X && git -C rel add .")).to eq([:unknown])
  end

  describe "the lexer" do
    it "does its best on an unbalanced quote, without raising" do
      expect(dirs("cd /p/main && git commit -m \"oops")).to eq(["/p/main"])
      expect(dirs("git commit -m 'oops && cd /p/main")).to eq(["/p/wt"])
    end

    it "treats nested $(…) as one opaque word" do
      expect(dirs("cd $(dirname $(pwd)) && git add .")).to eq([:unknown])
      expect(dirs("echo $(cd /p/main && git commit) && git add .")).to eq(["/p/wt"])
    end

    it "keeps backslash escapes and quoted spaces in a word" do
      expect(dirs("cd /p/my\\ main && git add .")).to eq(["/p/my main"])
      expect(dirs("cd '/p/my main' && git add .")).to eq(["/p/my main"])
    end

    it "is empty for a NUL byte or invalid UTF-8 rather than raising" do
      expect(dirs("cd /p/ma\0in && git add .")).to eq([])
      expect(dirs("cd /p/\xFF && git add .".b.force_encoding("UTF-8"))).to eq([])
    end

    it "is empty for an empty or blank command" do
      expect(dirs("")).to eq([])
      expect(dirs(" \n ")).to eq([])
    end
  end
end
