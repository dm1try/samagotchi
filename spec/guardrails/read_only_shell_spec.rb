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
    "git blame lib/a.rb", "git grep -n foo",
    # sqlite3 is read-only only with both safety flags; options may follow the database.
    "sqlite3 -readonly -safe coffee.db 'select 1'",
    "sqlite3 coffee.db -json -readonly -safe 'select 1'",
    "sqlite3 -safe -readonly -csv -header coffee.db 'select writefile(\"out\", \"x\")'",
    "sqlite3 -readonly -safe coffee.db 'vacuum into \"copy.db\"'",
    "sqlite3 -readonly -safe coffee.db 'select edit(\"file\")'",
    # gh's explicitly read-only subcommands.
    "gh run list", "gh run view 123", "gh pr list", "gh pr view 123", "gh pr diff 123", "gh pr checks 123",
    "gh issue list", "gh issue view 123", "gh repo view"
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
    # sqlite3 needs both safety flags and rejects options and dot commands it cannot prove safe.
    "sqlite3 -safe coffee.db 'select 1'", "sqlite3 -readonly coffee.db 'select 1'",
    "sqlite3 -readonly -safe coffee.db 'select 1' -cmd '.shell touch /tmp/x'",
    "sqlite3 -readonly -safe coffee.db -init startup.sql 'select 1'",
    "sqlite3 -readonly -safe -A coffee.db 'select 1'", "sqlite3 -readonly -safe -nonce x db 'select 1'",
    "sqlite3 -readonly -safe -unsafe-testing db 'select 1'", "sqlite3 -readonly -safe -append db 'select 1'",
    "sqlite3 -readonly -safe -zip db 'select 1'", "sqlite3 -readonly -safe -deserialize db 'select 1'",
    "sqlite3 -readonly -safe coffee.db '.shell touch /tmp/x'",
    "sqlite3 -readonly -safe coffee.db '.system touch /tmp/x'",
    "sqlite3 -readonly -safe coffee.db", "sqlite3 -readonly -safe .hidden.db 'select 1'",
    # gh allows only its listed reading subcommands, never web or watch modes.
    "gh pr view 123 --web", "gh --web pr view 123", "gh pr view 123 -w", "gh pr view 123 -cw", "gh pr checks 123 --watch",
    "gh api repos/owner/repo",
    "gh pr checkout 123", "gh run rerun 123", "gh issue create",
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

  # The child boundary's: writes it can name, each path the block accepts
  # (here: anything under /w), from the dir the command is in by then.
  describe ".read_only_but_writes?" do
    def writes?(command, cwd: "/p")
      described_class.read_only_but_writes?(command, cwd: cwd, home: "/h", env: {}) { |path| path.start_with?("/w/") }
    end

    it "lets reads write a redirect, cp's destination and tee's files where the block says" do
      ["ls > /w/o", "ls >>/w/o", "ls 2>/w/e 1>/w/o", "cat x | tee /w/a -a /w/b", "cp x /w/y", "cp -rp x y /w/d",
       "cp -t /w/d x", "cp -rt/w/d x", "cp --target-directory=/w/d x", "cp --preserve=mode -- x /w/y",
       "cd /w && cp /p/x y", "cat x > ../w/o", "(cd /x) ; ls > /w/o", "ls", "git log > /w/log"].each do |command|
        expect(writes?(command)).to be(true), command
      end
    end

    it "refuses writes elsewhere, options it doesn't know and what read_only? refuses" do
      ["ls > o", "ls > /w/o > o", "cat x | tee /w/a b", "tee -", "cp x y", "cp /w/x y", "cp -t /w/d", "cp x",
       "cp -l x /w/y", "cp -s x /w/y", "cp --link x /w/y", "cp --symbolic-link x /w/y", "cp --parents x /w/d",
       "cp -b x /w/y", "cp -T -t /w/d x", "mv x /w/y", "ls &> /w/o", "ls >| /w/o", "ls >&/w/o", "ls > $(p)",
       "cd /w | cp x y", "ls | cd /w && cp x y", "(cd /w) && cp x y", "cd $X && cp x y", "ls > /w/*",
       "cp x /w/y & ls", "rm /w/y", "ls > /w/o; rake"].each do |command|
        expect(writes?(command)).to be(false), command
      end
      expect(writes?("cp x y", cwd: nil)).to be(false)
    end

    it "leaves read_only? as it was: no cp, tee or redirect into a file" do
      expect(["cp x /w/y", "tee /w/a", "ls > /w/o"].map { |c| described_class.read_only?(c) }).to all(be(false))
    end
  end
end
