# frozen_string_literal: true

require "samagotchi/hooks/loader"
require "samagotchi/memory_paths"
require "samagotchi/paths"
require "samagotchi/system_one/self_protect"
require "samagotchi/guardrails/targets"
require "tmpdir"

# System 1 may never answer for a call that changes chi itself: config.yml,
# the hooks dir, the installed bundles, the guardrails store (approvals.json,
# judgments.jsonl), and the rules through which an agent answers chi's own
# questions. The memories dir is not one of them: reading and appending a
# memory file stays eligible (docs/guardrails.md, "System 1").
RSpec.describe Samagotchi::SystemOne::SelfProtect do
  S = described_class

  def config_path = Samagotchi::ConfigFile.global_path
  def hooks_dir = Samagotchi::Hooks::Loader.hooks_dir
  def bundles_dir = Samagotchi::MemoryPaths.bundles_dir
  def store_dir = File.join(Samagotchi::Paths.state_dir, "guardrails")
  def memories_dir = Samagotchi::MemoryPaths.system_dir

  it "refuses an edit or write of config.yml" do
    expect(S.refuse?({ "tool" => "edit", "paths" => [config_path] })).to be true
    expect(S.refuse?({ "tool" => "write", "paths" => [config_path] })).to be true
    expect(S.refuse?({ "tool" => "write", "paths" => [config_path, "notes.md"] })).to be true
  end

  it "refuses anything under the hooks dir, the bundles dir or the guardrails store" do
    expect(S.refuse?({ "tool" => "write", "paths" => [File.join(hooks_dir, "before_tool_call.rb")] })).to be true
    expect(S.refuse?({ "tool" => "write", "paths" => [File.join(bundles_dir, "guardrails", "rules.yml")] })).to be true
    expect(S.refuse?({ "tool" => "edit", "paths" => [File.join(store_dir, "approvals.json")] })).to be true
    expect(S.refuse?({ "tool" => "write", "paths" => [File.join(store_dir, "judgments.jsonl")] })).to be true
  end

  # As a command's words are judged (.chi_dirs): a write's paths and a cat
  # of them answer alike.
  it "refuses a path anywhere in chi's state dir (the sessions too), but the memories" do
    session = File.join(Samagotchi::Paths.state_dir, "sessions", "x.json")
    expect(S.refuse?({ "tool" => "write", "paths" => [session] })).to be true
    expect(S.refuse?({ "tool" => "execute", "command" => "cat #{session}" })).to be true
    expect(S.refuse?({ "tool" => "write", "paths" => [File.join(memories_dir, "notes.md")] })).to be false
  end

  it "refuses a command that names one of those paths" do
    expect(S.refuse?({ "tool" => "execute", "command" => "cat #{store_dir}/judgments.jsonl" })).to be true
    expect(S.refuse?({ "tool" => "task_create", "command" => "sed -i 's/x/y/' #{hooks_dir}/hook.rb" })).to be true
    expect(S.refuse?({ "tool" => "execute", "command" => "rm #{config_path}" })).to be true
    expect(S.refuse?({ "tool" => "execute", "command" => "echo #{bundles_dir}/guardrails/rules.yml" })).to be true
  end

  it "refuses the `~` spelling of chi's config file, not only the resolved one" do
    expect(S.refuse?({ "tool" => "execute", "command" => "cat ~/.config/samagotchi/config.yml" })).to be true
    expect(S.refuse?({ "tool" => "execute", "command" => "cp ~/.config/samagotchi/hooks/x.rb /tmp" })).to be true
  end

  it "leaves the memories dir alone: a memory file is not a control file" do
    memory = File.join(memories_dir, "notes.md")
    expect(S.refuse?({ "tool" => "memory_write", "paths" => [memory] })).to be false
    expect(S.refuse?({ "tool" => "execute", "command" => "cat ~/.config/samagotchi/memories/notes.md" })).to be false
    expect(S.refuse?({ "tool" => "edit", "paths" => [File.join(memories_dir, "projects", "a_1234", "index.md")] })).to be false
  end

  it "refuses a command that climbs out of the memories dir, however it climbs" do
    memories = memories_dir
    [
      "cd #{memories}; cd ..; echo 'mode: off' >> config.yml",
      "cd #{memories} && cd .. && echo x >> config.yml",
      "cd #{memories} && echo x >> ../config.yml",
      "cd #{memories} && cd \"${PWD%/*}\" && echo x >> config.yml",
      "cd #{memories} && cd ${PWD%/memories} && echo x >> hooks.yml",
      "cd #{memories} && cd \"$(dirname \"$PWD\")\" && echo x >> config.yml",
      "cd #{memories} && cd `dirname $PWD` && echo x >> config.yml",
      "cd #{memories} && cd - && echo x >> config.yml",
      "cd #{memories} && sh -c 'cd ..; echo x >> config.yml'",
      "cd #{memories} && echo x >> ../conf*.yml",
      "git push && cd ~/.config/samagotchi/memories && cd \"${PWD%/*}\" && echo x >> config.yml"
    ].each do |command|
      expect(S.refuse?({ "tool" => "execute", "command" => command, "cwd" => Dir.pwd })).to be(true), command
    end
  end

  it "refuses a cd chain or a symlink that reaches chi's config without spelling it" do
    config_dir = Samagotchi::ConfigFile.config_dir
    parent = File.dirname(config_dir)
    expect(S.refuse?({ "tool" => "execute", "command" => "cd #{parent}; cd #{File.basename(config_dir)}; cat config.yml",
                       "cwd" => Dir.pwd })).to be true

    Dir.mktmpdir do |tmp|
      File.symlink(config_dir, File.join(tmp, "l"))
      expect(S.refuse?({ "tool" => "execute", "command" => "cat l/config.yml", "cwd" => tmp })).to be true
      expect(S.refuse?({ "tool" => "execute", "command" => "cat #{tmp}/l/config.yml" })).to be true
    end
  end

  it "keeps the memories exemption for a command whose every word resolves into them" do
    memories = memories_dir
    expect(S.refuse?({ "tool" => "execute", "command" => "cd #{memories} && cat notes.md", "cwd" => Dir.pwd })).to be false
    expect(S.refuse?({ "tool" => "execute", "command" => "git push && sed -i '' s/a/b/ ~/.config/samagotchi/memories/x.md",
                       "cwd" => Dir.pwd })).to be false
  end

  # The shell memory edits a coordinator's day is made of: a word the walk
  # can't resolve that is only data (a script body, a heredoc, a phrase)
  # keeps the exemption while the text shows no climb.
  it "keeps the exemption for data words: a script body, a heredoc, a phrase" do
    note = File.join(memories_dir, "x.md")
    [
      "python3 -c \"p='#{note}'; s=open(p).read(); open(p, 'w').write(s.replace('old', 'new'))\"",
      "cat >> #{note} <<'EOF'\n- a note\n- another\nEOF",
      "echo \"- a note\" >> #{note}",
      "echo 'mode: on' >> ~/.config/samagotchi/memories/x.md",
      "cd #{memories_dir} && grep -l notes *.md"
    ].each do |command|
      expect(S.refuse?({ "tool" => "execute", "command" => command, "cwd" => Dir.pwd })).to be(false), command
    end
  end

  it "still refuses data words that name chi's config, or a word after a cd it can't follow" do
    config_dir = Samagotchi::ConfigFile.config_dir
    note = File.join(memories_dir, "x.md")
    [
      "python3 -c \"open('#{config_dir}/config.yml', 'a').write('x')  # #{note}\"",
      "cd #{memories_dir} && cd 'a b' && echo x >> config.yml",
      "cd #{memories_dir} && cd ~- && echo x >> config.yml",
      "cd #{memories_dir} && python3 -c \"import os; os.chdir('..'); open('config.yml', 'a')\"",
      "cat >> #{note} <<EOF\n$(cat #{note})\nEOF"
    ].each do |command|
      expect(S.refuse?({ "tool" => "execute", "command" => command, "cwd" => Dir.pwd })).to be(true), command
    end
  end

  # An interpreter climbs by its own calls, with no `..`, `$` or backticks in
  # the text: its script keeps the memories text in when it can climb, and
  # one chi can't see (a file, stdin) always does.
  it "refuses an interpreter's script that climbs out of the memories dir by its own calls, or one it can't see" do
    mem = memories_dir
    note = File.join(mem, "x.md")
    [
      %(git push && python3 -c 'import os; os.chdir("#{mem}"); os.chdir(os.pardir); open("config.yml","a").write("x")'),
      %(git push && python3 -c 'import os; p="#{mem}"; open(os.path.dirname(p)+"/config.yml","a").write("x")'),
      %(git push && ruby -e 'Dir.chdir("#{mem}"); Dir.chdir(File.dirname(Dir.pwd)); File.write("config.yml", "x")'),
      %(git push && cd #{mem} && python3 -c 'import os; os.chdir(os.pardir); open("config.yml","a")'),
      %(git push && cd #{mem} && node -e 'process.chdir(require("path").resolve(process.cwd(), "x", "..."))'),
      %(git push && python3 -c 'from pathlib import Path; (Path("#{note}").parent.parent / "config.yml").write_text("x")'),
      %(git push && python3 -c 'p="#{note}"; open(p[:p.rindex("/memories")] + "/config.yml", "a")'),
      %(git push && cd #{mem} && python3 /tmp/climb.py),
      %(git push && cd #{mem} && echo 'import os' | python3),
      %(git push && cd #{mem} && sh < /tmp/climb.sh),
      # a shell's -e/-x and python's -x are flags: the pipe is the script
      %(git push && cd #{mem} && echo Y2QgLi4= | base64 -d | sh -x),
      %(git push && cd #{mem} && echo 'import os' | python3 -x),
      %(git push && cd #{mem} && echo 'x' | python3 -c 'exec(input())'),
      # an interpreter in any version's name, and the programs that run a file
      %(git push && cd #{mem} && python3.12 /tmp/climb.py), %(git push && cd #{mem} && pypy3 /tmp/climb.py),
      %(git push && cd #{mem} && Rscript /tmp/climb.R), %(git push && cd #{mem} && tclsh /tmp/climb.tcl),
      %(git push && cd #{mem} && awk -f /tmp/climb.awk), %(git push && cd #{mem} && make -f /tmp/climb.mk),
      %(git push && cd #{mem} && deno run /tmp/climb.ts), %(git push && cd #{mem} && npm run x),
      # in any case: a case-insensitive disk runs MAKE as make (ShellLex.program_name)
      %(git push && cd #{mem} && MAKE), %(git push && cd #{mem} && RUBY /tmp/climb.rb),
      %(git push && cd #{mem} && Bash /tmp/climb.sh),
      # a value letter before the code letter's place: php -d's, osascript -l's (a file follows)
      %(git push && cd #{mem} && php -dr /tmp/climb.php), %(git push && cd #{mem} && osascript -le /tmp/climb.scpt),
      %(git push && cd #{mem} && julia /tmp/climb.jl),
      # perl's debugger runs .perldb from the dir it is in
      %(git push && cd #{mem} && perl -de 0),
      # fish's --command may source a file, as a script file it names
      %(git push && cd #{mem} && fish --command 'source /tmp/climb.fish')
    ].each do |command|
      facts = { "rule" => "git-push", "tool" => "execute", "command" => command, "cwd" => Dir.pwd }
      expect(S.refuse?(facts)).to be(true), command
    end
  end

  it "refuses a call whose env: redefines the shell" do
    targets = Samagotchi::Guardrails::Targets.new(tool: "task_create", command: "git push", paths: [], cwd: Dir.pwd,
                                                  repo_root: nil, env: { "BASH_ENV" => "/tmp/x.sh" })
    expect(S.refuse?({ "tool" => "task_create", "command" => "git push" }, targets: targets)).to be true
  end

  it "resolves the command's words under the call's env: too" do
    config_dir = Samagotchi::ConfigFile.config_dir
    targets = Samagotchi::Guardrails::Targets.new(tool: "task_create", command: "cat $XDG_CONFIG_HOME/x", paths: [],
                                                  cwd: Dir.pwd, repo_root: nil, env: { "XDG_CONFIG_HOME" => config_dir })
    expect(S.refuse?({ "tool" => "task_create", "command" => "cat $XDG_CONFIG_HOME/x", "cwd" => Dir.pwd },
                     targets: targets)).to be true
  end

  it "allows a call on an ordinary repo file" do
    expect(S.refuse?({ "tool" => "edit", "paths" => [File.join(Dir.pwd, "lib", "samagotchi", "config.rb")] })).to be false
    expect(S.refuse?({ "tool" => "execute", "command" => "git push origin main" })).to be false
    expect(S.refuse?({ "tool" => "execute", "command" => "rg samagotchi lib" })).to be false
  end

  it "refuses the rules that answer chi's own questions, however the user lists them" do
    %w[chi-answer-piped chi-answer-http chi-broadcast].each do |rule|
      expect(S.refuse?({ "tool" => "execute", "command" => "chi answer #{rule}", "rule" => rule })).to be true
    end
  end

  it "says nothing about an ask with no facts" do
    expect(S.refuse?({})).to be false
    expect(S.refuse?(nil)).to be false
  end
end
