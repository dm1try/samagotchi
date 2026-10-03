# frozen_string_literal: true

require "samagotchi/guardrails/read_only_shell"

# Which shell commands only read (a rule's skip_read_only). Anything it
# can't tell counts as not read-only.
RSpec.describe Samagotchi::Guardrails::ReadOnlyShell do
  read_only = [
    # the logged noise cases (approval-noise-log.md)
    "sed -n 1,80p docs/configuration.md; ls ~/.config/samagotchi/",
    "grep -rn props ~/.config/samagotchi/memories/projects/samagotchi_*/",
    "cd /p/samagotchi-plugins-mcp && rg -n \"Log.exception\" lib/samagotchi/log.rb",
    # plain readers, chains and pipes
    "ls", "ls -la ~/.config/samagotchi", "cat a b | wc -l", "head -n 5 x && tail -f y", "du -sh . ; stat x",
    "rg samagotchi/hooks lib", "rg -n 'foo|bar' --glob '*.rb'", "grep -r x . 2>/dev/null", "find . -name '*.rb' -type f",
    "tree -L 2 lib", "file -b x", "sort -u x | uniq -c", "uniq x", "echo hi >&2", "ls 2>&1 | head",
    "ls > /dev/null", "ls 2> /dev/null", "(cd lib && ls)", "cat $HOME/.config/samagotchi/config.yml",
    "ls ${HOME}/x", "ls \"$XDG_CONFIG_HOME/samagotchi\"", "ls $TMPDIR/x", "cat '$(not run)' \"a > b\"",
    # sed scripts that only read
    "sed -n '/def /p' x.rb", "sed -e 's/a/b/g' -e '3d' x", "sed -E 's#x#y#2' f", "sed -n '$p' f", "sed '1~2d' f",
    "sed -n '/a/,/b/{p;q}' f", "sed -n --expression=5p f", "sed -ne 3p f", "sed 'y/abc/xyz/' f",
    # awk
    "awk '{print $1}' f", "awk -F: -v n=1 '$1 == n {print}' /etc/passwd", "awk 'NR>=2' f",
    # git reads
    "git log --oneline -5", "git -C ../x show HEAD:lib/a.rb", "git diff --stat main", "git status --short",
    "git branch", "git branch -a -v", "git branch --list 'feat/*'", "git branch --merged main", "git stash list",
    "git worktree list", "git --no-pager log -p", "git rev-parse --git-common-dir", "git remote -v", "git tag",
    "git blame lib/a.rb", "git grep -n foo"
  ]

  not_read_only = [
    # writes and side effects
    "rm x", "mkdir -p /tmp/pp/config/samagotchi", "cat > f", "echo x >> ~/.config/samagotchi/config.yml",
    "ls | tee f", "echo a>b", "cat <f", "cat <<EOF\nx\nEOF", "ls &", "ls &> /dev/null", "cp a b",
    "touch x", "sed -i s/a/b/ f", "sed -i.bak s/a/b/ f", "sed --in-place s/a/b/ f", "sed -ni 1p f", "sed 1p f -i",
    "sed -f script.sed f", "perl -i -pe s/a/b/ f", "find . -delete", "find . -exec rm {} +", "find . -execdir x \\;",
    "find . -ok rm {} \\;", "find . -fprint out", "find . -fls out", "find . -fprintf out %p",
    # sed scripts that write or run
    "sed 'w out' f", "sed 's/a/b/w out' f", "sed 's/a/b/e' f", "sed '1e id' f", "sed 'r /etc/passwd' f",
    "sed '1a text' f", "sed -n 'W out' f", "sed -n", "sed",
    # awk that writes or runs
    "awk '{print > \"out\"}' f", "awk '{print | \"sh\"}' f", "awk 'BEGIN{system(\"id\")}'",
    "awk '{\"date\" | getline d}'", "awk -f prog.awk f", "awk '@include \"x\"'", "awk",
    # other writers among readers
    "rg --pre ./x foo", "rg --pre=./x foo", "sort -o out f", "sort --output=out f", "sort -uo out f",
    "sort --compress-program=x f", "uniq in out", "tree -o out", "tree -R", "file -C -m magic", "file --compile",
    # git that changes something
    "git push", "git commit -m x", "git -c core.pager=sh log", "git --git-dir=x log", "git diff --ext-diff",
    "git log --output=x", "git show --output x", "git grep -O foo", "git grep -nO foo", "git grep --open-files-in-pager foo",
    "git branch new", "git branch -d x", "git branch -m a b", "git branch -D x", "git stash", "git stash drop",
    "git worktree add x", "git remote add o u", "git tag v1", "git reflog expire --all", "git config x y",
    "git", "git checkout x",
    # never read-only verbs and prefixes
    "xargs cat", "sh -c 'ls'", "bash -c ls", "eval ls", "source x", ". x", "timeout 5 ls", "sudo ls", "watch ls",
    "env ls", "exec ls", "command ls", "nohup ls", "time ls", "less f", "more f", "vim f", "/bin/ls", "./ls",
    "X=1 ls", "FOO=bar git log",
    # substitutions and expansions
    "ls $(rm -rf /)", "ls `id`", "cat \"$(rm x)\"", "cat \"`rm x`\"", "find . $IFS-delete", "find . {-delete,}",
    "find . $'\\x2ddelete'", "ls $X", "ls ${X}", "ls $HOME$X", "ls ~/{a,b}", "ls ;; ls",
    # empty
    "", "   "
  ]

  read_only.each do |command|
    it "read-only: #{command.inspect}" do
      expect(described_class.read_only?(command)).to be(true)
    end
  end

  not_read_only.each do |command|
    it "not read-only: #{command.inspect}" do
      expect(described_class.read_only?(command)).to be(false)
    end
  end

  it "is false rather than raising on a NUL byte or invalid UTF-8" do
    expect(described_class.read_only?("ls \0x")).to be(true).or be(false)
    expect(described_class.read_only?("ls \xFF".b.force_encoding("UTF-8"))).to be(false).or be(true)
  end
end
