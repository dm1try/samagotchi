# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "samagotchi/guardrails"
require "samagotchi/system_one/self_protect"

# The guardrails' path predicates side by side (docs/guardrails.md, "How
# paths resolve"): every surface resolves a path its own way (ProtectedPaths,
# Outside, ReviewPaths, PairBoundary/PairCommand, ChildBoundary, Targets'
# touches_chi?/rm_outside_tmp?/git_dirs, ScratchWrites, System 1's
# SelfProtect), so this pins what each answers today for the same paths, and
# the invariants between them. A change in one resolver that the others
# don't follow fails here.
#
# The fixture (built once; HOME, XDG_CONFIG_HOME, XDG_STATE_HOME and TMPDIR
# point into it during each example). Tokens in the tables:
#   @home    HOME
#   @proj    @home/work/proj, the session's project (a git repo): lib/a.rb,
#            README.md, .env, .git/hooks/, and
#              node_modules/foo -> @home/src/foo (an npm-link style link out)
#              dangling         -> @home/elsewhere/new.txt (missing)
#              hard.txt         a hard link of @home/outside.txt
#              mem              -> @config/memories
#   @wt      @home/work/proj-wt, a sibling checkout (git worktree of @proj)
#   @config  chi's config dir: config.yml, hooks/, memories/notes.md,
#            memories/.bundles/x/rules.yml
#   @state   chi's state dir: guardrails/approvals.json (no context/ yet)
#   @tmp     a tmp dir the project isn't in (TMPDIR), resolved
#   @mktmp   the same dir as Dir.mktmpdir spelt it (/tmp, not /private/tmp)
#   @vartmp  a dir in /var/tmp, resolved
#   @home also holds .ssh/id_rsa, .config/gh/hosts.yml (secrets), src/foo.
#
# PATHS: one row per path as a file tool gets it (relative to @proj), the
# cells what each surface answers for it ("y"/"-" for a boolean):
#   out/in/tmp  Outside.outside? / .inside? / .tmp_write? (root @proj) on
#               every Targets#paths entry (any / all / all)
#   review      ReviewPaths#refusal: ok, outside, secret
#   read/write  PairBoundary on read / write of it: allow, ask, deny
#   child       ChildBoundary on a write of it
#   prot/scr    ProtectedPaths / ScratchWrites on a write of it
#   s1          SystemOne::SelfProtect.refuse? on the write's paths
#   cat         PairBoundary on `cat PATH`
#   touch       Targets#touches_chi? of `cat PATH`
#   rm          Targets#rm_outside_tmp? of `rm -rf PATH`
#   s1cat       SelfProtect.refuse? on the command `cat PATH`
#   reals       ProtectedPaths.reals of each Targets#paths entry, joined
# A path with a `$` is literal to a file tool (Tools::ToolPath expands only
# ~): its shell columns see the expanded one, so the file-vs-shell
# invariants skip it.
#
# Case rows (CASE_LIKE) are written for a disk that folds case (macOS); on a
# case-sensitive one (Linux) EXACT_DISK holds their answers.
#
# The tables and helpers live in this module, so its constants stay out of
# the other specs' way.
module GuardrailsPathConsistency
  RSpec.describe "The guardrails' path predicates, side by side", :aggregate_failures do
    G = Samagotchi::Guardrails
    S1 = Samagotchi::SystemOne::SelfProtect

    PATH_COLUMNS = %w[out in tmp review read write child prot scr s1 cat touch rm s1cat reals].freeze

    PATHS = <<~ROWS
      # id                path                                         out in tmp review  read  write child prot  scr   s1 cat   touch rm s1cat reals
      plain               lib/a.rb                                     -   y  -   ok      allow allow allow allow allow -  allow -     y  -     @proj/lib/a.rb
      absolute            @proj/lib/a.rb                               -   y  -   ok      allow allow allow allow allow -  allow -     y  -     @proj/lib/a.rb
      dot-slash           ./lib/a.rb                                   -   y  -   ok      allow allow allow allow allow -  allow -     y  -     @proj/lib/a.rb
      double-slash        @proj//lib/a.rb                              -   y  -   ok      allow allow allow allow allow -  allow -     y  -     @proj/lib/a.rb
      trailing-slash      lib/                                         -   y  -   ok      allow allow allow allow allow -  allow -     y  -     @proj/lib
      dotdot-lexical      lib/../README.md                             -   y  -   ok      allow allow allow allow allow -  allow -     y  -     @proj/README.md
      missing-tail        lib/new.rb                                   -   y  -   ok      allow allow allow allow allow -  allow -     y  -     @proj/lib/new.rb
      case-tail           LIB/New.rb                                   -   y  -   ok      allow allow allow allow allow -  allow -     y  -     @proj/lib/New.rb
      dollar-home-literal $HOME/.config/samagotchi/config.yml          -   y  -   ok      allow allow allow allow allow -  deny  y     y  y     @proj/$HOME/.config/samagotchi/config.yml
      dollar-tmp-literal  $TMPDIR/out.txt                              -   y  -   ok      allow allow allow allow allow -  allow -     -  -     @proj/$TMPDIR/out.txt
      project-secret      .env                                         -   y  -   secret  deny  deny  allow allow allow -  deny  -     y  -     @proj/.env
      git-config          .git/config                                  -   y  -   secret  deny  deny  allow allow allow -  deny  -     y  -     @proj/.git/config
      case-git-dir        .GIT/config                                  -   y  -   secret  deny  deny  allow allow allow -  deny  -     y  -     @proj/.git/config
      git-hook            .git/hooks/pre-commit                        -   y  -   ok      allow deny  allow allow allow -  allow y     y  -     @proj/.git/hooks/pre-commit
      link-out            node_modules/foo/index.js                    y   -  -   outside allow ask   ask   allow allow -  allow -     y  -     @home/src/foo/index.js
      link-climb          node_modules/foo/../x.txt                    y   -  -   outside allow ask   ask   allow allow -  allow -     y  -     @proj/node_modules/x.txt,@home/src/x.txt
      link-climb-secret   node_modules/foo/../../.config/gh/hosts.yml  y   -  -   outside deny  deny  ask   allow allow -  deny  -     y  -     @proj/.config/gh/hosts.yml,@home/.config/gh/hosts.yml
      dangling            dangling                                     y   -  -   outside allow ask   ask   allow allow -  allow -     y  -     @proj/dangling,@home/elsewhere/new.txt
      hard-link           hard.txt                                     y   -  -   ok      allow ask   ask   allow allow -  allow -     y  -     @proj/hard.txt
      sibling-checkout    ../proj-wt/lib/a.rb                          y   -  -   outside allow ask   ask   allow allow -  allow -     y  -     @wt/lib/a.rb
      home-file           @home/outside.txt                            y   -  -   outside allow ask   ask   allow allow -  allow -     y  -     @home/outside.txt
      home-dir            ~                                            y   -  -   outside allow ask   ask   allow allow -  allow -     y  -     @home
      tmp-file            @tmp/out.txt                                 -   -  y   outside allow allow allow allow allow -  allow -     -  -     @tmp/out.txt
      tmp-as-made         @mktmp/out.txt                               -   -  y   outside allow allow allow allow allow -  allow -     -  -     @tmp/out.txt
      var-tmp             @vartmp/out.txt                              -   -  y   outside allow allow allow allow allow -  allow -     -  -     @vartmp/out.txt
      tmp-dir             @tmp                                         -   -  y   outside allow allow allow allow allow -  allow -     -  -     @tmp
      memory-via-link     mem/notes.md                                 -   -  -   outside deny  deny  allow allow deny  -  deny  y     y  -     @config/memories/notes.md
      memory              @config/memories/notes.md                    -   -  -   outside deny  deny  allow allow deny  -  deny  y     y  -     @config/memories/notes.md
      memory-prompt-case  @config/memories/IDENTITY.md                 -   -  -   outside deny  deny  allow allow deny  -  deny  y     y  -     @config/memories/IDENTITY.md
      bundle              @config/memories/.bundles/x/rules.yml        y   -  -   outside deny  deny  ask   deny  deny  y  deny  y     y  y     @config/memories/.bundles/x/rules.yml
      link-climb-config   mem/../config.yml                            y   -  -   outside deny  deny  ask   ask   allow y  deny  y     y  y     @proj/config.yml,@config/config.yml
      config              @config/config.yml                           y   -  -   outside deny  deny  ask   ask   allow y  deny  y     y  y     @config/config.yml
      config-tilde        ~/.config/samagotchi/config.yml              y   -  -   outside deny  deny  ask   ask   allow y  deny  y     y  y     @config/config.yml
      config-double-slash @config//config.yml                          y   -  -   outside deny  deny  ask   ask   allow y  deny  y     y  y     @config/config.yml
      config-dot-slash    @config/./config.yml                         y   -  -   outside deny  deny  ask   ask   allow y  deny  y     y  y     @config/config.yml
      case-config-dir     @home/.config/SAMAGOTCHI/config.yml          y   -  -   outside deny  deny  ask   ask   allow y  deny  y     y  y     @config/config.yml
      case-config-file    @config/CONFIG.YML                           y   -  -   outside deny  deny  ask   ask   allow y  deny  y     y  y     @config/config.yml
      hooks-dir           @config/hooks/                               y   -  -   outside deny  deny  ask   ask   allow y  deny  y     y  y     @config/hooks
      hook                @config/hooks/h.rb                           y   -  -   outside deny  deny  ask   ask   allow y  deny  y     y  y     @config/hooks/h.rb
      case-hooks-dir      @config/HOOKS/h.rb                           y   -  -   outside deny  deny  ask   ask   allow y  deny  y     y  y     @config/hooks/h.rb
      store               @state/guardrails/approvals.json             y   -  -   outside deny  deny  ask   deny  allow y  deny  y     y  y     @state/guardrails/approvals.json
      context             @state/context/src.yml                       y   -  -   outside deny  deny  ask   deny  allow y  deny  y     y  y     @state/context/src.yml
      case-context-dir    @state/CONTEXT/src.yml                       y   -  -   outside deny  deny  ask   allow allow y  deny  -     y  y     @state/CONTEXT/src.yml
      state-session       @state/sessions/x.json                       y   -  -   outside deny  deny  ask   allow allow y  deny  -     y  y     @state/sessions/x.json
      ssh-key             ~/.ssh/id_rsa                                y   -  -   outside deny  deny  ask   allow allow -  deny  -     y  -     @home/.ssh/id_rsa
      gh-token            @home/.config/gh/hosts.yml                   y   -  -   outside deny  deny  ask   allow allow -  deny  -     y  -     @home/.config/gh/hosts.yml
    ROWS

    # A case row's plain spelling: on a disk that folds case both name one
    # file (or one missing dir), so they answer alike.
    CASE_LIKE = { "case-tail" => "missing-tail", "case-git-dir" => "git-config", "case-config-dir" => "config",
                  "case-config-file" => "config", "case-hooks-dir" => "hook", "case-context-dir" => "context" }.freeze

    # The case rows on a case-sensitive disk: another, missing file.
    EXACT_DISK = <<~ROWS
      case-tail           LIB/New.rb                                   -   y  -   ok      allow allow allow allow allow -  allow -     y  -     @proj/LIB/New.rb
      case-git-dir        .GIT/config                                  -   y  -   secret  deny  deny  allow allow allow -  deny  -     y  -     @proj/.GIT/config
      case-config-dir     @home/.config/SAMAGOTCHI/config.yml          y   -  -   outside allow ask   ask   allow allow -  allow -     y  -     @home/.config/SAMAGOTCHI/config.yml
      case-config-file    @config/CONFIG.YML                           y   -  -   outside deny  deny  ask   allow allow y  deny  y     y  y     @config/CONFIG.YML
      case-hooks-dir      @config/HOOKS/h.rb                           y   -  -   outside deny  deny  ask   allow allow y  deny  y     y  y     @config/HOOKS/h.rb
      case-context-dir    @state/CONTEXT/src.yml                       y   -  -   outside deny  deny  ask   allow allow y  deny  -     y  y     @state/CONTEXT/src.yml
    ROWS

    # Shell commands (run from @proj): touch, rm, git (Targets#git_dirs, "?"
    # for :unknown), pair (PairBoundary), child (ChildBoundary), s1
    # (SelfProtect.refuse?), rotmp (Targets#read_only_but_tmp_writes?, root
    # @proj), then the command.
    COMMANDS = <<~ROWS
      # id                touch rm git           pair  child s1 rotmp command
      tilde               y     -  -             deny  allow y  y     cat ~/.config/samagotchi/config.yml
      dollar-home         y     -  -             deny  allow y  y     cat $HOME/.config/samagotchi/config.yml
      slashes             y     -  -             deny  allow y  y     cat ~/.config//samagotchi/./config.yml
      cd-chain            y     -  -             deny  allow y  -     cd ~/.config; cd samagotchi; cat config.yml
      pushd               y     -  -             deny  allow y  -     pushd ~/.config/samagotchi && cat config.yml
      subshell            y     -  -             deny  allow y  -     (cd ~/.config/samagotchi && cat config.yml) && cat lib/a.rb
      cd-link-climb       -     -  -             deny  allow -  -     cd node_modules/foo && cat ../../.config/gh/hosts.yml
      cd-memory-climb     y     -  -             deny  allow y  -     cd mem && cat ../config.yml
      cd-link-dotdot      -     -  -             ask   allow -  -     cd node_modules/foo/.. && echo x > y.txt
      cd-tmp-secret       -     -  -             deny  allow -  y     cd /tmp && cat ~/.ssh/id_rsa
      tmp-write           -     -  -             allow allow -  y     echo x > @tmp/out.txt
      tmpdir-write        -     -  -             allow allow -  -     echo x > $TMPDIR/out.txt
      sibling-write       -     -  -             ask   ask   -  -     echo x > ../proj-wt/lib/a.rb
      dangling-write      -     -  -             ask   allow -  -     echo x > dangling
      link-climb-write    -     -  -             ask   allow -  -     echo x > node_modules/foo/../x.txt
      git-hook-write      y     -  -             deny  allow -  -     echo x > .git/hooks/pre-commit
      memory-append       y     -  -             deny  allow -  -     echo x >> ~/.config/samagotchi/memories/notes.md
      rm-tmpdir           -     -  -             allow allow -  -     rm -rf $TMPDIR/junk
      rm-project          -     y  -             allow allow -  -     rm -rf lib/old
      rm-sibling          -     y  -             ask   ask   -  -     rm -rf ../proj-wt/tmp
      git-here            -     -  @proj         allow allow -  -     git commit -m x
      git-cd-sibling      -     -  @wt           ask   ask   -  -     cd ../proj-wt && git commit -m x
      git-C-relative      -     -  @wt           ask   ask   -  -     git -C ../proj-wt commit -m x
      git-C-tilde         -     -  @wt           ask   ask   -  -     git -C ~/work/proj-wt commit -m x
      git-C-dollar-home   -     -  @wt           ask   ask   -  -     git -C $HOME/work/proj-wt commit -m x
      git-C-xdg           -     -  @home/.config ask   ask   -  -     git -C $XDG_CONFIG_HOME commit -m x
    ROWS

    def self.rows(text, columns)
      text.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }.to_h do |line|
        id, path, *cells = line.split
        raise "#{id}: #{cells.size} cells, not #{columns.size}" unless cells.size == columns.size

        [id, { "path" => path, **columns.zip(cells).to_h }]
      end
    end

    def self.commands(text)
      text.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }.to_h do |line|
        id, touch, rm, git, pair, child, s1, rotmp, command = line.split(/\s+/, 9)
        [id, { "touch" => touch, "rm" => rm, "git" => git, "pair" => pair, "child" => child, "s1" => s1,
               "rotmp" => rotmp, "command" => command }]
      end
    end

    PATH_ROWS = rows(PATHS, PATH_COLUMNS)
    EXACT_ROWS = rows(EXACT_DISK, PATH_COLUMNS)
    COMMAND_ROWS = commands(COMMANDS)

    # Invariants between the surfaces, over PATH_ROWS' answers (+a+, +id+).
    # Each lists the rows it doesn't hold for: "kept: …" on purpose, "BUG: …" a
    # divergence found and not fixed (a pending example below asserts the
    # invariant for it, so a fix shows).
    INVARIANTS = {
      "a path ProtectedPaths votes on is refused by System 1 (file and shell), review and pair, and touches chi" => [
        ->(a) { a["prot"] == "allow" || (a["s1"] == "y" && a["s1cat"] == "y" && a["review"] != "ok" && a["read"] == "deny" && a["write"] == "deny" && a["cat"] == "deny" && a["touch"] == "y") },
        {}
      ],
      "a path any surface calls outside the project, review and pair don't call inside" => [
        ->(a) { (a["out"] == "-" && a["child"] == "allow" && (a["in"] == "y" || a["tmp"] == "y")) || (a["review"] != "ok" && a["write"] != "allow") },
        { "hard-link" => "kept: a review read of a hard link reads a file that is in the project too; Outside counts it outside for the write that would change the other name's file" }
      ],
      "a path inside the project is inside for every surface" => [
        ->(a) { a["in"] == "-" || (a["out"] == "-" && a["tmp"] == "-" && a["child"] == "allow" && a["review"] != "outside" && a["write"] != "ask") },
        {}
      ],
      "a tmp write is not outside, the pair and child boundaries don't ask, and rm -rf there stays in tmp" => [
        ->(a) { a["tmp"] == "-" || (a["out"] == "-" && a["in"] == "-" && a["write"] == "allow" && a["child"] == "allow" && a["rm"] == "-") },
        {}
      ],
      "an rm -rf of a path that is no tmp write reaches outside tmp" => [
        ->(a, id) { a["tmp"] == "y" || a["rm"] == "y" || literal?(id) },
        {}
      ],
      "a review secret is denied to a pair turn by every tool" => [
        ->(a) { a["review"] != "secret" || (a["read"] == "deny" && a["write"] == "deny" && a["cat"] == "deny") },
        {}
      ],
      "a pair turn's read of a path and its cat of it agree" => [
        ->(a, id) { literal?(id) || a["read"] == a["cat"] },
        {}
      ],
      "System 1 answers a path's write and its cat alike" => [
        ->(a, id) { literal?(id) || a["s1"] == a["s1cat"] },
        {}
      ],
      "a cat of chi's files touches chi, and System 1 refuses it but for the memories" => [
        ->(a, id) { literal?(id) || a["touch"] == "-" || a["s1cat"] == "y" || a["scr"] == "deny" },
        { "git-hook" => "kept: touches_chi? counts the repo's .git/hooks, System 1 only chi's own files" }
      ],
      "a memory file ScratchWrites denies touches chi and is a secret to a pair turn" => [
        ->(a) { a["scr"] == "allow" || (a["touch"] == "y" && a["read"] == "deny" && a["cat"] == "deny") },
        {}
      ]
    }.freeze

    # Folding disks only: a case row answers as its CASE_LIKE row (reals
    # aside: a missing tail keeps its typed case), but for these.
    CASE_EXCEPTIONS = {
      "case-context-dir" => "BUG: on a disk that folds case a write to state/CONTEXT/ lands in the context sources dir " \
                            "once it exists, but ProtectedPaths compares the typed case (no chi-context deny), and " \
                            "touches_chi? and System 1's path test miss it the same way"
    }.freeze

    def self.literal?(id) = PATH_ROWS.fetch(id)["path"].include?("$")

    def self.check(invariant, answers, id)
      invariant.arity == 2 ? invariant.call(answers, id) : invariant.call(answers)
    end

    # Every answer is taken once, here, with the env pointing into the fixture.
    before(:context) do
      @base = File.realpath(Dir.mktmpdir("path-consistency"))
      tmp_root = G::Outside.tmp_roots.find { |dir| !@base.start_with?(File.join(dir, "")) }
      @mktmp = Dir.mktmpdir("path-consistency-tmp", tmp_root == "/private/tmp" ? "/tmp" : tmp_root)
      @vartmp = File.realpath(Dir.mktmpdir("path-consistency-vartmp", "/var/tmp"))
      home = File.join(@base, "home")
      @dirs = { "home" => home, "proj" => File.join(home, "work", "proj"), "wt" => File.join(home, "work", "proj-wt"),
                "config" => File.join(home, ".config", "samagotchi"), "state" => File.join(home, ".local", "state", "samagotchi"),
                "tmp" => File.realpath(@mktmp), "mktmp" => @mktmp, "vartmp" => @vartmp }
      build_fixture
      @folds = File.exist?(File.join(@base, "HOME"))
      @git = G::GitInfo.new
      with_env("HOME" => home, "XDG_CONFIG_HOME" => File.dirname(dir("config")),
               "XDG_STATE_HOME" => File.dirname(dir("state")), "TMPDIR" => dir("tmp")) do
        @answers = PATH_ROWS.to_h { |id, row| [id, path_answers(expand(row["path"]))] }
        @cd_answers = PATH_ROWS.to_h { |id, row| [id, cd_answers(expand(row["path"]))] }
        @command_answers = COMMAND_ROWS.to_h { |id, row| [id, command_answers(row["command"])] }
        @xdg_git_dirs = targets({ name: "execute", content: "git -C $XDG_CONFIG_HOME commit -m x" }).git_dirs
      end
    end

    after(:context) { FileUtils.rm_rf([@base, @mktmp, @vartmp]) }

    attr_reader :answers

    def dir(name) = @dirs.fetch(name)

    def sh(dir, *args)
      out, status = Open3.capture2e("git", "-C", dir, *args)
      raise "git #{args.join(" ")}: #{out}" unless status.success?
    end

    def build_fixture
      home, proj, config, state = @dirs.values_at("home", "proj", "config", "state")
      memories = File.join(config, "memories")
      FileUtils.mkdir_p([File.join(proj, "lib"), File.join(config, "hooks"), File.join(memories, ".bundles", "x"),
                         File.join(state, "guardrails"), File.join(home, ".config", "gh"), File.join(home, ".ssh"),
                         File.join(home, "src", "foo"), File.join(proj, "node_modules")])
      { File.join(config, "config.yml") => "{}\n", File.join(memories, "notes.md") => "n\n",
        File.join(memories, ".bundles", "x", "rules.yml") => "r\n", File.join(state, "guardrails", "approvals.json") => "{}\n",
        File.join(home, ".config", "gh", "hosts.yml") => "t\n", File.join(home, ".ssh", "id_rsa") => "k\n",
        File.join(home, "src", "foo", "index.js") => "j\n", File.join(home, "outside.txt") => "o\n",
        File.join(proj, "lib", "a.rb") => "a\n", File.join(proj, "README.md") => "r\n", File.join(proj, ".env") => "T=1\n" }
        .each { |path, text| File.write(path, text) }
      sh(proj, "init", "-q")
      sh(proj, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
      sh(proj, "worktree", "add", "-q", dir("wt"))
      FileUtils.mkdir_p(File.join(proj, ".git", "hooks"))
      File.symlink(File.join(home, "src", "foo"), File.join(proj, "node_modules", "foo"))
      File.symlink(File.join(home, "elsewhere", "new.txt"), File.join(proj, "dangling"))
      File.link(File.join(home, "outside.txt"), File.join(proj, "hard.txt"))
      File.symlink(memories, File.join(proj, "mem"))
    end

    # --- the surfaces, as the wiring builds them for a session in @proj ------

    def context = G::Context.new(cwd: dir("proj"), git: @git)
    def targets(call) = G::Targets.for(call, context)

    def label(check, call)
      verdict = G::Verdict.new(call: call)
      verdict.context = context
      verdict.targets = targets(call)
      check.check(verdict)
      if verdict.deny? then "deny"
      elsif verdict.ask? then "ask"
      else "allow"
      end
    end

    def pair = G::PairBoundary.new(author: -> { "p:p_0123abcd" }, root: -> { dir("proj") }, home: -> { dir("home") }, web_ports: -> { [4567] })

    def child
      proj = dir("proj")
      G::ChildBoundary.new(root: -> { proj }, worktrees: -> { @git.worktrees(proj) }, common_dir: -> { @git.common_dir(proj) },
                           branch: -> { @git.branch(proj) })
    end

    def protected_paths
      config = dir("config")
      state = dir("state")
      G::ProtectedPaths.new(store_dir: File.join(state, "guardrails"), bundles_dir: File.join(config, "memories", ".bundles"),
                            config_path: File.join(config, "config.yml"), hooks_dir: File.join(config, "hooks"),
                            context_dir: File.join(state, "context"))
    end

    def scratch = G::ScratchWrites.new(memories_dir: -> { File.join(dir("config"), "memories") })

    def yn(value) = value ? "y" : "-"

    def expand(text) = text.gsub(/@(\w+)/) { dir(Regexp.last_match(1)) }

    def tokens(path) = @dirs.except("mktmp").sort_by { |_, d| -d.size }.reduce(path) { |acc, (name, d)| acc.gsub(d, "@#{name}") }

    def s1_command(command, call)
      S1.refuse?({ "tool" => "execute", "command" => command, "cwd" => dir("proj") }, targets: targets(call))
    end

    # Every PATH_COLUMNS cell for +path+ (expanded), as the tables spell them.
    def path_answers(path)
      write = { name: "write", path: path, content: "" }
      paths = targets(write).paths
      proj = dir("proj")
      cat = { name: "execute", content: "cat #{path}" }
      {
        "out" => yn(paths.any? { |p| G::Outside.outside?(p, root: proj) }),
        "in" => yn(paths.all? { |p| G::Outside.inside?(p, root: proj) }),
        "tmp" => yn(paths.all? { |p| G::Outside.tmp_write?(p, root: proj) }),
        "review" => (G::ReviewPaths.new(root: proj, home: dir("home")).refusal(paths) || :ok).to_s,
        "read" => label(pair, { name: "read", content: path }), "write" => label(pair, write),
        "child" => label(child, write), "prot" => label(protected_paths, write), "scr" => label(scratch, write),
        "s1" => yn(S1.refuse?({ "tool" => "write", "paths" => paths })),
        "cat" => label(pair, cat), "touch" => yn(targets(cat).touches_chi?),
        "rm" => yn(targets({ name: "execute", content: "rm -rf #{path}" }).rm_outside_tmp?),
        "s1cat" => yn(s1_command(cat[:content], cat)),
        "reals" => paths.flat_map { |p| G::ProtectedPaths.reals(p) }.uniq.map { |p| tokens(p) }.join(",")
      }
    end

    # `cd DIR && cat BASE` for +path+: the cd-then-relative form of `cat PATH`.
    def cd_answers(path)
      command = "cd #{File.dirname(path)} && cat #{File.basename(path)}"
      call = { name: "execute", content: command }
      { "cat" => label(pair, call), "touch" => yn(targets(call).touches_chi?), "s1cat" => yn(s1_command(command, call)) }
    end

    # The COMMANDS cells for +command+ (unexpanded).
    def command_answers(command)
      call = { name: "execute", content: expand(command) }
      t = targets(call)
      git = t.git_dirs.map { |d| d == :unknown ? "?" : tokens(d.to_s) }
      { "touch" => yn(t.touches_chi?), "rm" => yn(t.rm_outside_tmp?), "git" => git.empty? ? "-" : git.join(","),
        "pair" => label(pair, call), "child" => label(child, call), "s1" => yn(s1_command(call[:content], call)),
        "rotmp" => yn(t.read_only_but_tmp_writes?(root: dir("proj"))), "command" => command }
    end

    def expected(id) = (!@folds && EXACT_ROWS[id]) || PATH_ROWS.fetch(id)

    it "has well-formed tables" do
      expect(EXACT_ROWS.keys).to match_array(CASE_LIKE.keys)
      expect(PATH_ROWS.keys).to include(*CASE_LIKE.keys, *CASE_LIKE.values)
      EXACT_ROWS.each { |id, row| expect(row["path"]).to eq(PATH_ROWS.fetch(id)["path"]), id }
      INVARIANTS.each_value { |_, exceptions| expect(PATH_ROWS.keys).to include(*exceptions.keys) unless exceptions.empty? }
    end

    it "answers every path as the table says" do
      PATH_ROWS.each_key do |id|
        path = PATH_ROWS.fetch(id)["path"]
        expect(answers.fetch(id)).to eq(expected(id).except("path")), "#{id} (#{path}) on a #{@folds ? "folding" : "case-sensitive"} disk"
      end
    end

    it "answers a cd into the path's dir then a relative cat as the cat of the whole path" do
      PATH_ROWS.each do |id, row|
        expect(@cd_answers.fetch(id)).to eq(answers.fetch(id).slice("cat", "touch", "s1cat")), "#{id} (#{row["path"]})"
      end
    end

    INVARIANTS.each do |name, (invariant, exceptions)|
      it "holds: #{name}" do
        broken = answers.reject { |id, a| self.class.check(invariant, a, id) }.keys
        expect(broken).to match_array(exceptions.keys), "broken for #{broken.inspect}; listed: #{exceptions.inspect}"
      end

      exceptions.each do |id, reason|
        next unless reason.start_with?("BUG")

        it "holds for #{id} once fixed: #{name}" do
          pending reason
          expect(self.class.check(invariant, answers.fetch(id), id)).to be(true)
        end
      end
    end

    it "answers a case-different spelling like the plain one on a disk that folds case" do
      skip "this disk is case-sensitive: EXACT_DISK holds the case rows" unless @folds

      broken = CASE_LIKE.reject { |id, like| answers.fetch(id).except("reals") == answers.fetch(like).except("reals") }.keys
      expect(broken).to match_array(CASE_EXCEPTIONS.select { |_, reason| reason.start_with?("BUG") }.keys)
    end

    CASE_EXCEPTIONS.each do |id, reason|
      next unless reason.start_with?("BUG")

      it "answers #{id} like #{CASE_LIKE.fetch(id)} on a folding disk once fixed" do
        skip "this disk is case-sensitive" unless @folds
        pending reason
        expect(answers.fetch(id).except("reals")).to eq(answers.fetch(CASE_LIKE.fetch(id)).except("reals"))
      end
    end

    it "answers every command as the table says" do
      COMMAND_ROWS.each { |id, row| expect(@command_answers.fetch(id)).to eq(row), id }
    end

    it "holds: a command that runs git outside the project gets the child boundary's ask" do
      COMMAND_ROWS.each do |id, row|
        outside = row["git"].split(",").any? { |dir| !%w[- ? @proj].include?(dir) }
        expect(row["child"]).to eq("ask"), id if outside
      end
    end

    it "holds: git -C $XDG_CONFIG_HOME is resolved as the cd walk resolves it (ShellPaths.expand_word)" do
      expect(@xdg_git_dirs).to eq([File.dirname(dir("config"))])
    end
  end
end
