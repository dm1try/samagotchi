# frozen_string_literal: true

require_relative "outside"
require_relative "path_resolve"
require_relative "read_only_shell"
require_relative "review_paths"
require_relative "shell_git_dirs"
require_relative "shell_paths"
require_relative "shell_lex"

module Samagotchi
  module Guardrails
    # Read only by a pair turn's outside-write check: kept off the load
    # path of everything that requires PairCommand (the testing kit's budget).
    autoload :ImplicitWriters, File.expand_path("implicit_writers", __dir__)

    # One shell command of a participant's pair turn, read the way
    # PairBoundary needs it (the refusal words are PairBoundary's):
    # - #refusal: why it may not run, nil when it may: chi, something left
    #   running, a URL opener or a listener (OPENERS, LISTENERS: the owner's
    #   browser cookies), the environment or the keychain, git settings that run
    #   commands, a folder sweep, a secret (a path a word resolves to, a glob
    #   or a $var whose fixed part leads into one, SECRET_TEXT for the
    #   rest); a script it hands a shell (sh -c, eval, a heredoc) is read as
    #   a command of its own, one it hands another interpreter (ruby -e,
    #   python <<EOF) by its text. A command it can't read is refused
    #   (UNREADABLE), never let through on a text match;
    # - #outside_writes?: whether it may change something outside the
    #   project, failing closed: no unless it only reads
    #   (ReadOnlyShell.read_only?), or only reads but for writes into the
    #   project or a tmp dir (ReadOnlyShell.read_only_but_writes?), or
    #   stays inside the project (#stays_inside?: it runs in the project and
    #   every path it names, an option's value, a glob's fixed part and the
    #   paths in a script it hands on among them, lands in the project or a
    #   tmp dir, Outside.inside? / Outside.tmp_write?). A word it can't
    #   resolve ($var, $(…), a dir after cd $X) counts as outside.
    # A data heredoc (cat, tee, git commit -F - read it: ShellLex::HEREDOC)
    # is not looked into: it's text being written, not run.
    class PairCommand
      # What runs a command on another's behalf, and the shell's keywords
      # before a command: skipped to find the program.
      WRAPPERS = %w[env exec command nohup time sudo nice xargs setsid timeout stdbuf caffeinate bundle ruby watch npx
                    { ! then do else elif if while until].freeze
      # chi's own invocations a pair turn may run: they print and exit.
      CHI_ALLOWED = [%w[--version], %w[--help]].freeze
      # chi named in a script, a value or an argument.
      CHI_TEXT = %r{(?:\A|[\s;&|(`'"=])(?:[^\s;&|(`'"=]*/)?chi(?=\s|\z|[;&|)`'"])}
      SHELLS = %w[sh bash zsh dash fish ksh].freeze
      # Other interpreters a script can be handed to (-e/-c, a heredoc), by
      # name in any version's spelling (python3.12, pypy3, ruby3.3, perl5.36).
      INTERPRETER = /\A(?:python\d*(?:\.\d+)?|pypy\d*(?:\.\d+)?|ruby\d*(?:\.\d+)?|irb|node(?:js)?|deno|bun|
                      perl\d*(?:\.\d+)*|php\d*(?:\.\d+)?|lua(?:jit|\d*(?:\.\d+)?)|osascript|jshell|Rscript|
                      tclsh\d*(?:\.\d+)?|wish)\z/x
      # The options whose next word is an interpreter's code, by its name's
      # start (a shell's is -c only: its -e and -x are flags); others: -c, -e.
      CODE_FLAGS = { "python" => %w[-c], "pypy" => %w[-c], "ruby" => %w[-e], "irb" => %w[-e],
                     "node" => %w[-e -p --eval --print], "bun" => %w[-e -p --eval --print], "perl" => %w[-e -E],
                     "php" => %w[-r], "lua" => %w[-e], "osascript" => %w[-e], "Rscript" => %w[-e],
                     "tclsh" => [], "wish" => [], "deno" => [], "jshell" => [] }.freeze
      # How an interpreter's short-option cluster reads (ruby -we, perl -le,
      # python3 -Ic), by its name's start: the letters whose value is the
      # rest of the word (ruby -rset: no code), and those that take digits
      # (perl -l0e). Any other letter is a flag; the code letter's code is
      # the rest of the word, or the next word (.cluster_code_at).
      CLUSTER_VALUES = { "python" => %w[mWX], "pypy" => %w[mWX], "ruby" => %w[CEFiIrx 0W],
                         "perl" => %w[CdDFiImMx 0l], "node" => %w[r], "bun" => %w[r], "lua" => %w[l] }.freeze
      # A shell's options whose next word is their value, not its script.
      SHELL_VALUE_OPTIONS = %w[-o +o -O +O].freeze
      # Options whose next word is code or a command, for any program.
      CODE_OPTIONS = %w[-c -e -exec --exec -execdir --command --eval -x].freeze
      # A shell's or interpreter's options whose next word is a value, not
      # its script (#stdin_script?).
      RUNNER_VALUE_OPTIONS = %w[-o +o -O +O -W -X -I -r --require --import --loader -C].freeze
      # A redirection of stdin (< file, 0<file), not a heredoc's <<.
      STDIN_REDIRECT = /\A0?<(?!<)/
      # Programs that detach what they start, or run it later (cron, at).
      DETACHERS = %w[nohup setsid disown daemonize crontab at batch].freeze
      # Programs that print the environment or a keychain's secrets, whatever
      # their arguments.
      ENV_READERS = %w[printenv security op].freeze
      # Commands that print a stored credential (a token, a password, a
      # key), by the program and the words that say so in its arguments.
      # Programs that load a project's env files (PairBoundary::ENV_LOADER).
      ENV_LOADERS = %w[mise direnv].freeze
      ENV_LOADER_TEXT = %r{(?<![\w./-])(?:mise|direnv)(?![\w./-])}
      CREDENTIAL_PRINTERS = {
        "gh" => [%w[auth token]],
        "git" => [%w[credential], %w[credential-osxkeychain], %w[credential-store], %w[credential-cache],
                  %w[credential-manager]],
        "gcloud" => [%w[print-access-token], %w[print-identity-token]],
        "aws" => [%w[configure get], %w[configure export-credentials], %w[ecr get-login-password],
                  %w[sts get-session-token]],
        "az" => [%w[account get-access-token]],
        "heroku" => [%w[auth:token]],
        "npm" => [%w[token]],
        "kubectl" => [%w[config view --raw]],
        "keyring" => [%w[get]]
      }.freeze
      # A credential helper run by itself (docker-credential-osxkeychain get).
      CREDENTIAL_HELPER = /\A(?:docker-credential-|git-credential-)/
      ENV_TEXT = %r{/proc/[^\s]*/environ}
      # Programs that open a URL or a file in the owner's apps (a browser
      # sends the owner's cookies with it), whatever their arguments; gio
      # with its open verb.
      OPENERS = %w[open xdg-open gnome-open kde-open kde-open5 kfmclient exo-open wslview sensible-browser
                   x-www-browser www-browser google-chrome google-chrome-stable chromium chromium-browser
                   firefox safari msedge microsoft-edge brave-browser].freeze
      # Programs that listen on a port whatever their arguments (static
      # HTTP servers), and the netcats, which listen with -l.
      LISTENERS = %w[http-server live-server httpd lighttpd nginx caddy miniserve darkhttpd webfsd].freeze
      NETCATS = %w[nc ncat netcat].freeze
      NC_LISTEN = /\A-[a-zA-Z0-9]*l|\A--listen\z/
      # An interpreter's flags or arguments that serve a port (python -m
      # http.server, ruby -run -e httpd, php -S, busybox httpd).
      SERVE_MODULES = %w[http.server SimpleHTTPServer CGIHTTPServer socketserver].freeze
      # An interpreter's script that opens a URL in the owner's apps, or
      # listens on a port.
      SCRIPT_OPENER_TEXT = /\bwebbrowser\b|\bopen location\b|openExternal|xdg-open|\bopen\s+["']?https?:/
      SCRIPT_LISTEN_TEXT = /\blisten\s*\(|\bhttp\.server\b|\bserve_forever\b|HTTPServer|TCPServer|socketserver|createServer|WEBrick|\bhttpd\b/
      # This machine's loopback names (.web_text): localhost and its
      # subdomains, 127.x.y.z, 0.0.0.0, ::1 spelt any way, ::ffff:127.x.
      LOOPBACK_HOSTS = [/(?:[\w-]+\.)*localhost\.?/, /127(?:\.\d{1,3}){1,3}/, /0\.0\.0\.0/,
                        /\[?(?:0{0,4}:){2,7}0{0,3}1\]?/, /\[?::ffff:127(?:\.\d{1,3}){3}\]?/].freeze
      # An interpreter's script that reads the environment or detaches.
      SCRIPT_ENV_TEXT = /\bos\.environ\b|\bgetenv\b|\bprocess\.env\b|\bENV\b|\bprintenv\b|%ENV\b/
      # An interpreter's script that runs git config or git -c (by its text:
      # the script isn't parsed).
      SCRIPT_GIT_CONFIG_TEXT = /\bgit\b[^\n]{0,40}?(?:\bconfig\b|["'\s]-c\b|--config-env|--template)/
      SCRIPT_BACKGROUND_TEXT = /\b(?:nohup|setsid|disown|daemonize|Process\.daemon|detach(?:ed)?)\b/
      # Programs that read a folder's whole tree: given home (or any folder
      # above a denied one) they reach the secrets in it.
      # A link to such a folder reaches them too (ln, link).
      SWEEPERS = %w[find tar cp rsync scp zip 7z cpio grep egrep fgrep rg ag ack fd ditto ln link].freeze
      # Programs that make a link (and cp's options that do).
      LINKERS = %w[ln link mklink].freeze
      CP_LINK_OPTION = /\A-[a-zA-Z]*[sl]|\A--(?:symbolic-)?link\z/
      # An interpreter's script that makes a link.
      SCRIPT_LINK_TEXT = /symlink|\blink\(|\bln\s|\bmklink\b|FileUtils\.ln|hardlink/i
      # A pair turn writes no git config at all (any key may run a command
      # later in the owner's name: hooks, fsmonitor, a driver, a helper, an
      # include): only reads, parsed strictly. git config's read actions,
      # the flags and value options a read may carry (exact spellings: git
      # takes a long option's unique prefix too, and such a word counts as
      # a write here), and its read subcommands.
      GIT_CONFIG_READ_ACTIONS = %w[--get --get-all --get-regexp --get-urlmatch --get-color --get-colorbool -l
                                   --list].freeze
      GIT_CONFIG_READ_FLAGS = %w[--show-origin --show-scope --name-only -z --null --includes --no-includes --local
                                 --worktree --all --regexp --fixed-value --bool --int --bool-or-int --path
                                 --expiry-date --no-type].freeze
      GIT_CONFIG_READ_VALUES = %w[-f --file --blob --type --default --value --url].freeze
      GIT_CONFIG_READS = %w[get list].freeze
      GIT_CONFIG_WRITES = %w[set unset rename-section remove-section edit].freeze
      # How many words a read action takes after it (a key, a value pattern…).
      GIT_CONFIG_READ_ARITY = { "--get-urlmatch" => 2..2, "-l" => 0..0, "--list" => 0..0, "get" => 1..1,
                                "list" => 0..0 }.freeze
      # A clone's, an init's or a submodule's -c/--config (the new repository's
      # config) or --template (its hooks), in any prefix git takes.
      GIT_SEEDING = %w[clone init submodule].freeze
      GIT_SEED_CONFIG = /\A(?:-c.*|--c(?:o(?:n(?:f(?:i(?:g)?)?)?)?)?(?:=.*)?)\z/
      GIT_SEED_TEMPLATE = /\A--t(?:e(?:m(?:p(?:l(?:a(?:t(?:e)?)?)?)?)?)?)?(?:=.*)?\z/
      # git's options whose value is a command it runs now (filter-branch's
      # filters, rebase --exec, difftool --extcmd, --upload-pack, …), and the
      # subcommands whose -x / -u is one.
      GIT_COMMAND_OPTIONS = %w[--exec --upload-pack --receive-pack --extcmd --tree-filter --index-filter --msg-filter
                               --env-filter --commit-filter --parent-filter --tag-name-filter].freeze
      GIT_COMMAND_SHORT = %w[rebase difftool clone fetch ls-remote pull].freeze
      # Programs that install git hooks (or set core.hooksPath), by the
      # arguments that do it (nil: any).
      HOOK_INSTALLERS = { "pre-commit" => %w[install], "husky" => nil, "lefthook" => %w[install add],
                          "simple-git-hooks" => nil, "overcommit" => %w[--install], "git-hooks" => %w[install] }.freeze
      # git's own options before its subcommand: the flags, and those whose
      # value may be the next word. Any other option (one git knows and this
      # list doesn't: --exec-path alone, a newer one) may or may not take
      # the next word, and both readings are judged (.git_command_starts):
      # an unknown option never hides the config, -c or template after it.
      GIT_FLAG_OPTIONS = %w[-p --paginate -P --no-pager --no-replace-objects --no-lazy-fetch --no-optional-locks
                            --no-advice --bare --literal-pathspecs --glob-pathspecs --noglob-pathspecs
                            --icase-pathspecs -v --version -h --help --html-path --man-path --info-path].freeze
      GIT_VALUE_OPTIONS = %w[-C --git-dir --work-tree --namespace --attr-source --shallow-file].freeze
      # Variables whose value is a command a program runs through a shell
      # (git's diff driver, editor, pager, ssh, proxy, askpass; the editors
      # and pagers others run): read as an sh -c script, wherever the
      # assignment stands (a prefix, export's, env's).
      COMMAND_ENV = %w[GIT_EXTERNAL_DIFF GIT_EDITOR EDITOR VISUAL GIT_SEQUENCE_EDITOR GIT_SSH_COMMAND GIT_SSH
                       GIT_PROXY_COMMAND GIT_PAGER PAGER MANPAGER GIT_ASKPASS SSH_ASKPASS].freeze
      # Devices a command may name in the project's stead.
      DEVICES = %w[/dev/null /dev/stdout /dev/stderr /dev/tty /dev/zero /dev/random /dev/urandom].freeze
      # A word that starts with $TMPDIR or ${TMPDIR}.
      TMPDIR_WORD = /\A\$(?:\{TMPDIR\}|TMPDIR\b)/

      # A path in a script's text (an interpreter's -e/-c, a heredoc): ~, ..
      # or an absolute path, at the text's start or after a space, quote,
      # bracket, = or comma.
      SCRIPT_PATH = %r{(?:\A|(?<=[\s'"(\[=,]))(?:~|\.\.|/[\w.~-])[^\s'"`;,()\]]*}
      # A $(…) that is only a message's heredoc (git commit -m "$(cat <<EOF …)"),
      # its body cut by ShellLex.code_text.
      MESSAGE_SUBST = /\$\(cat <<-?(['"]?)(\w+)\1\n\2\n\)/
      # Assignments whose value is a search list, not a path.
      LIST_VARIABLES = %w[PATH].freeze
      GLOB = /[*?\[\]{}]/
      SHELL_BRACKETS = %w[[ [[ ]] { } ]].freeze
      # How many matches of a glob are checked against the denylist.
      GLOB_LIMIT = 500
      # How deep scripts handed to a shell are read; deeper is UNREADABLE.
      MAX_DEPTH = 3

      # Whether a pair turn may write +path+ (absolute) without asking: it
      # lands in the project (Outside.inside?) or in a tmp dir the project
      # isn't in (Outside.tmp_write?), every way it resolves. No project
      # (+root+ blank): the tmp dirs only.
      def self.writable?(path, root:, cwd: nil)
        root = root.to_s
        return Outside.tmp_write?(path, root: cwd || Dir.pwd) if root.empty?

        Outside.inside?(path, root: root) || Outside.tmp_write?(path, root: root)
      end

      # mise's config files (mise.toml, .mise.toml, mise.<env>.toml, .config/mise.toml,
      # anything under .config/mise/, mise/ or .mise/ config*.toml, and the
      # .tool-versions it reads too): mise runs their [env] at the next worker
      # start (ProjectEnv), and installs the tools they pin.
      MISE_CONFIG_PATH = %r{(?:\A|/)(?:\.?mise(?:\.[^/]+)?\.toml|\.config/mise\.toml|\.config/mise/.+|
                             \.?mise/config[^/]*\.toml|\.tool-versions)\z}x
      MISE_CONFIG_TEXT = %r{(?<![\w-])(?:\.?mise(?:\.[\w.-]+)?\.toml|\.config/mise|\.?mise/config[\w.-]*\.toml|
                            \.tool-versions(?![\w.-]))}x

      # Whether +path+ is one of mise's config files (MISE_CONFIG_PATH), as
      # given or as it resolves.
      def self.mise_config?(path)
        path.to_s.match?(MISE_CONFIG_PATH) ||
          (path.to_s.start_with?("/") && PathResolve.reals(path).any? { |real| real.match?(MISE_CONFIG_PATH) })
      end

      # Whether +path+ is in a .git/hooks folder, as given or as it resolves
      # (ShellPaths::HOOKS_PART): git runs what is there.
      def self.git_hook?(path)
        path.to_s.match?(ShellPaths::HOOKS_PART) ||
          (path.to_s.start_with?("/") && PathResolve.reals(path).any? { |real| real.match?(ShellPaths::HOOKS_PART) })
      end

      # Where the program is in +words+: past assignments, wrappers, shell
      # keywords and their options (and an option's value: ruby -I lib,
      # timeout 10).
      def self.program_at(words)
        at = 0
        at += 1 while at < words.size && skipped?(words, at)
        at < words.size ? at : nil
      end

      def self.skipped?(words, at)
        word = words[at]
        return true if word.match?(/\A[A-Za-z_]\w*=/) || word.start_with?("-") || word.match?(/\A\d+[smhd]?\z/)
        return true if WRAPPERS.include?(File.basename(word))

        previous = at.positive? ? words[at - 1] : nil
        !previous.nil? && previous.match?(/\A-[IrCen]\z/)
      end
      private_class_method :skipped?

      # Where git's subcommand may start in its +args+ (indices): past its
      # own options (GIT_FLAG_OPTIONS, GIT_VALUE_OPTIONS and their value,
      # an option=value), every reading of an option it doesn't know (with
      # its next word as a value and without). :config_option among them
      # when one of those options is a -c or --config-env.
      def self.git_command_starts(args)
        starts = []
        todo = [0]
        seen = {}
        until todo.empty?
          i = todo.shift
          next if seen[i]

          seen[i] = true
          word = args[i]
          next starts << i if word.nil? || !word.start_with?("-")
          next starts << :config_option if word.start_with?("-c", "--config-env")

          if GIT_FLAG_OPTIONS.include?(word) || word.include?("=") then todo << (i + 1)
          elsif GIT_VALUE_OPTIONS.include?(word) then todo << (i + 2)
          else todo.push(i + 1, i + 2)
          end
        end
        starts
      end

      # A git builtin by its dashed name (git-config, …/git-core/git-submodule,
      # a +program+ word's basename) as git runs it: ["git", [sub, *args]];
      # any other program as it is.
      def self.git_form(program, args)
        sub = program.to_s[/\Agit-([a-z][\w-]*)\z/, 1]
        sub ? ["git", [sub, *args]] : [program, args]
      end

      # A shell, another interpreter or eval: what runs a script it is given.
      def self.runner?(word)
        return false if word.include?("\0")

        name = File.basename(word)
        SHELLS.include?(name) || interpreter?(name) || name == "eval"
      end

      # Whether +name+ (a word's basename) is an interpreter's (INTERPRETER).
      def self.interpreter?(name) = name.to_s.match?(INTERPRETER)

      # The options whose next word is +name+'s code (CODE_FLAGS).
      def self.code_flags(name)
        return %w[-c] if SHELLS.include?(name)

        CODE_FLAGS.find { |start, _| name.start_with?(start) }&.last || %w[-c -e]
      end

      # Whether +word+ is +name+'s code option: one of .code_flags, a long
      # one with its code after = (node --eval=…), or a short-option
      # cluster holding its code letter (.cluster_code_at: sh -ec, bash -cx,
      # ruby -we, perl -le, node -pe, python3 -Ic).
      def self.code_flag?(name, word)
        flags = code_flags(name)
        flags.include?(word) || !long_code(name, word).nil? || !cluster_code_at(name, word).nil?
      end

      # The code a long code option carries after = (--eval=…), nil for
      # another word.
      def self.long_code(name, word)
        flag = code_flags(name).find { |option| option.start_with?("--") && word.start_with?("#{option}=") }
        flag && word.delete_prefix("#{flag}=")
      end

      # Where +word+, a short-option cluster, holds +name+'s code letter
      # (a shell's c, python's c, ruby's e, node's e and p…): its index, the
      # letters before it read as CLUSTER_VALUES says; nil when it holds
      # none, or a letter before it takes the rest as its value.
      def self.cluster_code_at(name, word)
        return nil unless word.match?(/\A-[A-Za-z0-9]/)

        letters = code_flags(name).filter_map { |flag| flag[1] if flag.match?(/\A-[A-Za-z]\z/) }.join
        return nil if letters.empty?

        rest, digits = SHELLS.include?(name) ? ["", ""] : cluster_values(name)
        i = 1
        while i < word.size
          char = word[i]
          return i if letters.include?(char)
          return nil if rest.include?(char)

          i += 1
          if digits.include?(char) then i += 1 while word[i]&.match?(/\d/)
          elsif !char.match?(/[A-Za-z]/) then return nil
          end
        end
        nil
      end

      def self.cluster_values(name)
        values = CLUSTER_VALUES.find { |start, _| name.start_with?(start) }&.last || []
        [values[0].to_s, values[1].to_s]
      end
      private_class_method :cluster_values

      # The scripts +name+ (a shell or an interpreter, not eval) is handed
      # in +rest+, the words after it: a shell's is the first word that
      # isn't an option after its -c cluster (sh -c -- S, bash -c -x S, its
      # -o's value skipped); an interpreter's is each code option's (one of
      # .code_flags, a long one's after =, a cluster's rest and the next
      # word: both are read when the rest isn't empty).
      def self.code_scripts(name, rest)
        return shell_scripts(rest) if SHELLS.include?(name)

        found = []
        rest.each_with_index do |word, i|
          next unless code_flag?(name, word)

          if (code = long_code(name, word)) then found << code
          elsif (at = cluster_code_at(name, word)) && at + 1 < word.size then found << word[(at + 1)..]
          end
          found << rest[i + 1] if rest[i + 1] && long_code(name, word).nil?
        end
        found
      end

      def self.shell_scripts(rest)
        start = rest.index { |word| cluster_code_at("sh", word) } or return []
        i = start + 1
        while i < rest.size
          word = rest[i]
          return rest[i + 1] ? [rest[i + 1]] : [] if word == "--"
          return [word] unless word.start_with?("-", "+")

          i += SHELL_VALUE_OPTIONS.include?(word) ? 2 : 1
        end
        []
      end
      private_class_method :shell_scripts

      # Where a simple command's shell or interpreter (.runner?) gets its
      # script: nil without one; :inline for its code option's script
      # (.code_flag?: a shell's -c, python's -c, node's -e/-p…), eval's
      # words, a heredoc or here-string (#scripts reads them); :file for a
      # script file or a module (-m) it names (not read); :stdin when it
      # reads a pipe (+piped+, whatever its options: a -c script may read
      # stdin too, exec(input())), a < file, -s, -, or no script at all.
      # Other flags (a shell's -e, -x, -o x; python's -x) are flags.
      def self.script_source(words, piped: false)
        limit = program_at(words) || (words.size - 1)
        at = (0..limit).find { |i| runner?(words[i]) } or return nil
        name = File.basename(words[at])
        return :inline if name == "eval"
        return :stdin if piped

        rest = words[(at + 1)..]
        return :inline if rest.any? { |word| word.start_with?("<<") }
        return :stdin if rest.any? { |word| word.match?(STDIN_REDIRECT) }

        skip = false
        rest.each do |word|
          next skip = false if skip
          return :stdin if ["-", "-s"].include?(word) || (SHELLS.include?(name) && word.match?(/\A-[a-zA-Z]*s[a-zA-Z]*\z/))
          return :inline if code_flag?(name, word)
          return :file if word == "-m" || word.match?(/\A-m\w/)
          # a redirection's operator alone: its target is the next word
          next skip = word.sub(ShellPaths::REDIRECT_PREFIX, "").empty? if word.match?(ShellPaths::REDIRECT_PREFIX)
          next skip = RUNNER_VALUE_OPTIONS.include?(word) if word.start_with?("-", "+")

          return :file
        end
        :stdin
      end

      # A command's text naming chi web's endpoint on this machine: a
      # loopback name (LOOPBACK_HOSTS) or one of +hostnames+, and one of
      # +ports+, anywhere in it (a URL's host:port, nc's host port, a
      # script's ("host", port), /dev/tcp/host/port, curl's --resolve); or
      # 0:port. nil without a port.
      # @return [Regexp, nil]
      def self.web_text(ports, hostnames: [])
        return nil if ports.empty?

        hosts = (LOOPBACK_HOSTS.map(&:source) + hostnames.map { |name| Regexp.escape(name) }).join("|")
        port = ports.map { |number| Regexp.escape(number.to_s) }.join("|")
        Regexp.new("\\A(?=[\\s\\S]*?(?<![\\w.-])(?:#{hosts})(?![\\w-]))(?=[\\s\\S]*?(?<![\\w.])(?:#{port})(?!\\d))|" \
                   "(?<![\\w.:-])0:(?:#{port})(?!\\d)", Regexp::IGNORECASE)
      end

      # This machine's own names (Socket.gethostname, with and without
      # its domain and with .local), lowercased.
      def self.hostnames
        require "socket"
        name = Socket.gethostname.to_s.downcase
        short = name.split(".").first.to_s
        [name, short, "#{short}.local"].reject { |host| host.empty? || host == ".local" }.uniq
      rescue StandardError
        []
      end

      # @param paths [ReviewPaths] the denylist
      # @param root [String, nil] the project root (outside writes; none:
      #   every command but a read-only one writes outside)
      # @param web [Regexp, nil] chi web's endpoint in a command's text
      #   (.web_text)
      def initialize(text, cwd:, paths:, home:, root: nil, depth: 0, web: nil)
        @web = web
        @text = text.to_s
        @cwd = cwd
        @paths = paths
        @home = home.to_s
        @root = root.to_s
        @depth = depth
      end

      # @return [String, nil] a PairBoundary refusal
      def refusal
        return @refusal if defined?(@refusal)

        @refusal = read
      rescue StandardError
        @mise_config = true
        @refusal = PairBoundary::UNREADABLE
      end

      # Whether it makes a link (ln, link, cp -s/-l, a script's symlink): a
      # path through a link it makes now is judged before the link exists,
      # so the owner approves it (asked about; a link to a folder above a
      # secret is refused: SWEEPERS). True for one it can't read.
      def links?
        return @links if defined?(@links)

        @links = @depth > MAX_DEPTH || ShellLex.simple_commands(ShellLex.lex(@text)).any? do |words|
          words.is_a?(Array) && link_command?(words)
        end
      rescue StandardError
        @links = true
      end

      # Whether it runs mise or direnv (ENV_LOADERS): they load the
      # project's env files (a mise.local.toml, an .envrc), which hold the
      # owner's secrets, into what the command prints; the owner approves
      # it. True for one it can't read.
      def loads_env?
        return @loads_env if defined?(@loads_env)

        @loads_env = @depth > MAX_DEPTH || ShellLex.simple_commands(ShellLex.lex(@text)).any? do |words|
          words.is_a?(Array) && env_loader_command?(words)
        end
      rescue StandardError
        @loads_env = true
      end

      # Whether it writes (or, not only reading, names) a mise config file
      # (.mise_config?), a script it hands on included: the owner approves
      # it. True for one it can't read.
      def mise_config_write?
        refusal
        @mise_config ||= false
      end

      # Whether it may write outside the project (asked about, never
      # denied); true for one it can't read.
      def outside_writes?
        return @outside_writes if defined?(@outside_writes)

        @outside_writes = env_command_outside? ||
                          !(ReadOnlyShell.read_only?(@text) || writes_inside? || stays_inside?)
      rescue StandardError
        @outside_writes = true
      end

      private

      def read
        return PairBoundary::UNREADABLE if @depth > MAX_DEPTH

        tokens = ShellLex.lex(@text)
        code = ShellLex.code_text(@text, keep_written: false)
        subst = tokens.any? { |_, value| value.include?(ShellLex::SUBST) }
        return PairBoundary::CHI if subst && code.match?(CHI_TEXT)
        return PairBoundary::BACKGROUND if tokens.any? { |type, value| type == :op && value == "&" }
        return PairBoundary::ENVIRONMENT if code.match?(ENV_TEXT)
        return PairBoundary::CHI_WEB if @web && code.match?(@web)
        return PairBoundary::SECRET if subst && code.match?(PairBoundary::SECRET_TEXT)

        read_only = ReadOnlyShell.read_only_parts(tokens)
        walk = ShellPaths::Walk.new(@cwd, @home, ENV)
        ShellLex.simple_commands(tokens).each do |words|
          next walk.step(words) if words.is_a?(Symbol)

          # A path the command names counts as written (mise's config, git's
          # hooks) unless the part of it holding this command only reads.
          @read_only = read_only.shift
          reason = words_refusal(words) || scripts_refusal(words) || paths_refusal(words, walk.step(words))
          return reason if reason
        end
        nil
      end

      # A simple command's own refusal, by its program and arguments.
      def words_refusal(words)
        at = program_at(words)
        return PairBoundary::CHI if chi_in_values?(words)
        return PairBoundary::VERB if at && unplain_program?(words[at])

        program = at && File.basename(words[at])
        args = at ? words[(at + 1)..] : []
        return PairBoundary::CHI if program == "chi" && !CHI_ALLOWED.include?(args)

        upto = at ? words[0..at] : words
        return PairBoundary::BACKGROUND if upto.any? { |w| DETACHERS.include?(File.basename(w)) } || detached_session?(program, args)
        return PairBoundary::ENVIRONMENT if env_reader?(program, args) || bare_env?(words)

        program, args = PairCommand.git_form(program, args)
        return PairBoundary::GIT_CONFIG if git_config_env?(words) || git_alias?(program, args)

        env_commands(words).each do |script|
          reason = nested(script).refusal
          return reason if reason
        end

        if program == "git"
          # xargs adds words of its input: a git config it runs may write
          xargs = words[0...at].any? { |word| File.basename(word) == "xargs" }
          reason = git_refusal(args, appended: xargs) || git_command_refusal(args)
          return reason if reason
        end
        return PairBoundary::GIT_HOOKS if hook_installer?(words)
        return PairBoundary::OPENER if opener?(program, args)
        return PairBoundary::LISTENER if listener?(program, args)

        exec_commands(args).each do |command|
          reason = words_refusal(command)
          return reason if reason
        end
        nil
      end

      # The commands find runs (-exec, -execdir, -ok, -okdir … ; or +):
      # judged as commands of their own.
      def exec_commands(args)
        found = []
        args.each_with_index do |arg, at|
          next unless %w[-exec -execdir -ok -okdir].include?(arg)

          command = args[(at + 1)..].take_while { |word| !%w[; \\; +].include?(word) }
          found << command unless command.empty?
        end
        found
      end

      # open, xdg-open, a browser, gio open; osascript's open location is
      # its script's (#script_text_refusal).
      def opener?(program, args)
        OPENERS.include?(program.to_s.downcase) || (program == "gio" && args.first == "open")
      end

      # nc -l, socat with a …LISTEN address, a static HTTP server, an
      # interpreter serving a module (python -m http.server), ruby's un
      # httpd (ruby -run -e httpd, ruby being a wrapper word: the args are
      # the whole command's), php -S, busybox httpd.
      def listener?(program, args)
        name = program.to_s
        return true if LISTENERS.include?(name)
        return true if NETCATS.include?(name) && args.any? { |arg| arg.match?(NC_LISTEN) }
        return true if name == "socat" && args.any? { |arg| arg.match?(/LISTEN/i) }
        return true if name.start_with?("php") && args.include?("-S")
        return true if name == "busybox" && args.first == "httpd"
        return true if args.each_cons(2).any? { |flag, value| flag == "-m" && SERVE_MODULES.include?(value) }

        false
      end

      # A program word the shell expands: a $var, a $(…), a glob (bin/ch?,
      # ${e}i); the test brackets and braces are words of their own.
      def unplain_program?(word)
        return false if SHELL_BRACKETS.include?(word)

        word.include?("$") || word.include?(ShellLex::SUBST) || word.match?(GLOB)
      end

      # chi in an assignment's value (FOO=chi, alias x='chi …') or in the
      # word after an option that takes code or a command (-exec, -c, -e).
      def chi_in_values?(words)
        words.each_with_index.any? do |word, i|
          value = word[/\A[A-Za-z_][\w-]*=(.*)\z/m, 1]
          (value && value.match?(CHI_TEXT)) || (i.positive? && CODE_OPTIONS.include?(words[i - 1]) && word.match?(CHI_TEXT))
        end
      end

      # The scripts the command hands on: a shell's (-c, eval, a heredoc or
      # here-string) read as a command; an interpreter's (-e/-c, a heredoc)
      # by its text.
      def scripts_refusal(words)
        limit = program_at(words) || (words.size - 1)
        at = (0..limit).find { |i| runner?(words[i]) } or return nil
        program = File.basename(words[at])
        scripts(words, at).each do |script|
          reason = if SHELLS.include?(program) || program == "eval"
                     inner = nested(script)
                     inner.refusal.tap { @mise_config = true if inner.mise_config_write? }
                   elsif PairCommand.interpreter?(program)
                     @mise_config = true if script.match?(MISE_CONFIG_TEXT)
                     script_text_refusal(script)
                   end
          return reason if reason
        end
        nil
      end

      def runner?(word) = PairCommand.runner?(word)

      def scripts(words, at)
        name = File.basename(words[at])
        found = []
        found << words[(at + 1)..].join(" ") if name == "eval"
        words.each_with_index do |word, i|
          next if i.zero? || word == ShellLex::HEREDOC

          found << word if words[i - 1].start_with?("<<")
        end
        found.concat(PairCommand.code_scripts(name, words[(at + 1)..])) unless name == "eval"
        found
      end

      def script_text_refusal(script)
        return PairBoundary::CHI if script.match?(CHI_TEXT)
        return PairBoundary::SECRET if script.match?(PairBoundary::SECRET_TEXT)
        return PairBoundary::ENVIRONMENT if script.match?(SCRIPT_ENV_TEXT) || script.match?(ENV_TEXT)
        return PairBoundary::BACKGROUND if script.match?(SCRIPT_BACKGROUND_TEXT)
        return PairBoundary::OPENER if script.match?(SCRIPT_OPENER_TEXT)
        return PairBoundary::LISTENER if script.match?(SCRIPT_LISTEN_TEXT)
        return PairBoundary::GIT_CONFIG if script.match?(SCRIPT_GIT_CONFIG_TEXT)

        nil
      end

      def program_at(words) = PairCommand.program_at(words)

      # screen -d…, tmux new -d: a session left running.
      def detached_session?(program, args)
        (program == "screen" && args.any? { |arg| arg.match?(/\A-\w*d/) }) ||
          (program == "tmux" && args.any? { |arg| arg.match?(/\Anew(-session)?\z/) } && args.include?("-d"))
      end

      # printenv, security, op, a credential printer (CREDENTIAL_PRINTERS)
      # or helper; set, export, declare and typeset that list (no
      # assignment); launchctl getenv/export; ps with a BSD e (ps e, eww) or
      # -E (ps -E, -axE).
      def env_reader?(program, args)
        return true if ENV_READERS.include?(program) || program.to_s.match?(CREDENTIAL_HELPER)
        return true if credential_printer?(program, args)

        listing = args.none? { |arg| !arg.start_with?("-", "+") }
        case program
        when "set" then args.empty?
        when "export", "declare", "typeset" then listing
        when "launchctl" then %w[getenv export].include?(args.first)
        when "ps" then args.any? { |arg| arg.match?(/\A[a-zA-Z]*e[a-zA-Z]*\z|\A-[a-zA-Z]*E[a-zA-Z]*\z/) }
        else false
        end
      end

      # Whether +args+ hold one of +program+'s CREDENTIAL_PRINTERS words, in
      # order and next to each other (git -C x credential fill).
      def credential_printer?(program, args)
        CREDENTIAL_PRINTERS.fetch(program, []).any? do |words|
          args.each_cons(words.size).any?(words)
        end
      end

      # env with no command after it prints the environment.
      def bare_env?(words)
        assignment = ->(word) { word.start_with?("-") || word.match?(/\A[A-Za-z_]\w*=/) }
        at = words.index { |word| !assignment.call(word) }
        return false unless at && File.basename(words[at]) == "env"

        words[(at + 1)..].all?(&assignment)
      end

      # Why a git command is refused: a config write (anything but a read
      # .git_config_read? holds for, git -c and --config-env whatever they
      # set, a clone's, init's or submodule's -c/--config: GIT_CONFIG) or a
      # template (--template: its hooks, GIT_HOOKS); nil for the rest.
      def git_refusal(args, appended: false)
        starts = PairCommand.git_command_starts(args)
        return PairBoundary::GIT_CONFIG if starts.include?(:config_option)

        starts.each do |i|
          reason = git_command_refusal_at(args[i], args[(i + 1)..] || [], appended: appended)
          return reason if reason
        end
        nil
      end

      def git_command_refusal_at(command, rest, appended:)
        return (!appended && git_config_read?(rest) ? nil : PairBoundary::GIT_CONFIG) if command == "config"
        return nil unless GIT_SEEDING.include?(command)
        return PairBoundary::GIT_CONFIG if rest.any? { |arg| arg.match?(GIT_SEED_CONFIG) }

        rest.any? { |arg| arg.match?(GIT_SEED_TEMPLATE) } ? PairBoundary::GIT_HOOKS : nil
      end

      # Whether git config's arguments (+rest+) only read, every word
      # accounted for: a read action or subcommand (GIT_CONFIG_READ_ACTIONS,
      # GIT_CONFIG_READS) or a lone key, the flags and value options a read
      # may carry (exact spellings), and as many words as the action takes.
      # Anything else (an unknown or abbreviated option, a value option at
      # the end, a word too many) is a write.
      def git_config_read?(rest)
        actions = []
        positional = []
        skip = false
        rest.each do |arg|
          next skip = false if skip

          if arg.start_with?("-") && arg != "-"
            if GIT_CONFIG_READ_ACTIONS.include?(arg) then actions << arg
            elsif GIT_CONFIG_READ_VALUES.include?(arg) then skip = true
            elsif !GIT_CONFIG_READ_FLAGS.include?(arg) && !GIT_CONFIG_READ_VALUES.include?(arg[/\A[^=]+(?==)/])
              return false
            end
          else
            positional << arg
          end
        end
        return false if skip

        if GIT_CONFIG_READS.include?(positional.first)
          return false unless actions.empty?

          actions << positional.shift
        end
        return positional.size == 1 && !GIT_CONFIG_WRITES.include?(positional.first) if actions.empty?
        return false unless actions.size == 1

        GIT_CONFIG_READ_ARITY.fetch(actions.first, 1..2).cover?(positional.size)
      end

      # The commands a git command runs now, handed to it as text (a
      # submodule foreach's, a rebase --exec's, a filter's, an --upload-pack,
      # an ext:: URL…; GIT_COMMAND_OPTIONS): read as commands of their own.
      def git_commands(args)
        PairCommand.git_command_starts(args).grep(Integer).flat_map do |i|
          git_commands_at(args[i], args[(i + 1)..] || [])
        end
      end

      def git_commands_at(command, rest)
        found = rest.filter_map { |arg| arg.delete_prefix("ext::") if arg.start_with?("ext::") }
        found << rest.drop_while { |arg| arg != "foreach" }.drop(1).reject { |arg| arg.start_with?("-") }.join(" ") if
          command == "submodule" && rest.include?("foreach")
        found << rest.drop_while { |arg| arg != "run" }.drop(1).join(" ") if command == "bisect" && rest.include?("run")
        rest.each_with_index do |arg, at|
          name, value = arg.split("=", 2)
          next unless GIT_COMMAND_OPTIONS.include?(name) || (%w[-x -u].include?(name) && GIT_COMMAND_SHORT.include?(command))

          found << (value || rest[at + 1].to_s)
        end
        found
      end

      # A command a git command runs now (.git_commands), refused as its
      # own command would be.
      def git_command_refusal(args)
        git_commands(args).each do |script|
          reason = nested(script).refusal
          return reason if reason
        end
        nil
      end

      # alias g=git (or a function's body naming git), then `g config …`:
      # git under another name; an alias naming git is refused.
      def git_alias?(program, args)
        program == "alias" && args.any? { |arg| arg.match?(%r{=['"]?(?:\S*/)?git(?:\s|['"]?\z)}) }
      end

      # An assignment (a prefix, export's, env's) of a variable that hands
      # git config or a template of its own (ShellGitDirs::CONFIG_ENV): what
      # it sets may run a command, as git -c's may.
      def git_config_env?(words)
        words.any? { |word| word[/\A([A-Za-z_]\w*)=/, 1].to_s.match?(ShellGitDirs::CONFIG_ENV) }
      end

      # The commands a simple command's assignments hand a program
      # (COMMAND_ENV: GIT_EDITOR='…' git commit, export GIT_PAGER=…).
      def env_commands(words)
        words.filter_map do |word|
          name, value = word.match(/\A([A-Za-z_]\w*)=(.+)\z/m)&.captures
          value if COMMAND_ENV.include?(name)
        end
      end

      # Whether a command an assignment hands a program (#env_commands)
      # may write outside, read as a command of its own.
      def env_command_outside?
        ShellLex.simple_commands(ShellLex.lex(@text)).any? do |words|
          words.is_a?(Array) && env_commands(words).any? { |script| nested(script).outside_writes? }
        end
      end

      # A hook installer (HOOK_INSTALLERS: pre-commit install, husky,
      # lefthook install…), wherever it stands among the wrappers (npx husky).
      def hook_installer?(words)
        at = program_at(words) or return false
        (0..at).any? do |i|
          name = File.basename(words[i])
          next false unless HOOK_INSTALLERS.key?(name)

          verbs = HOOK_INSTALLERS[name]
          verbs.nil? || words[(i + 1)..].intersect?(verbs)
        end
      end

      # The secrets a simple command's words reach: a resolved path on the
      # denylist; a glob that matches one or whose fixed part leads into a
      # denied dir; a $var word whose fixed part does; a sweeper given a
      # folder above a denied one; SECRET_TEXT for a word it can't read.
      def paths_refusal(words, resolved)
        program_word = (at = program_at(words)) && File.basename(words[at])
        resolved.each do |word, path|
          return PairBoundary::GIT_HOOKS if !@read_only && PairCommand.git_hook?(path || word)

          @mise_config = true if !@read_only && PairCommand.mise_config?(path || word)

          if path
            return PairBoundary::SECRET if @paths.secret_refusal([path])
            return PairBoundary::HOME_SWEEP if SWEEPERS.include?(program_word) && above_denied?(path)
          elsif unresolved_secret?(word) || (!data?(word) && word.match?(PairBoundary::SECRET_TEXT))
            return PairBoundary::SECRET
          end
        end
        nil
      end

      def data?(word) = word == ShellLex::HEREDOC

      # A word Walk can't resolve: a glob checked by what it matches and by
      # its fixed part, a $var by its fixed part (the text before the first
      # glob character or $, with a leading ~, $HOME, XDG dir or $TMPDIR
      # expanded: PathResolve.expand_head). After $TMPDIR the fixed part
      # counts only inside a denied root, not as the start of one's name: an
      # isolated run keeps its state dir in tmp, and `ls $TMPDIR/*` is no
      # reach for it. A script body (spaces, quotes), a data heredoc or a
      # $(…) is left to the other checks.
      def unresolved_secret?(word)
        return false if word.include?("\0") || word.match?(ShellPaths::SCRIPT)

        expanded = PathResolve.expand_head(word, home: @home, env: ENV)
        fixed = expanded[/\A[^*?\[\]{}$]*/]
        dir = @cwd || Dir.pwd
        if !expanded.include?("$") && expanded.match?(GLOB)
          matches = Dir.glob(File.expand_path(expanded, dir)).first(GLOB_LIMIT)
          return true unless @paths.secret_refusal(matches).nil?
        end
        return false if fixed.empty?

        prefix = File.expand_path(fixed, dir)
        word.match?(TMPDIR_WORD) ? inside_denied?(prefix) : leads_into_denied?(prefix)
      end

      # Whether a path's text is a denied root or inside one.
      def inside_denied?(path) = @paths.denied_roots.any? { |root| PathResolve.under?(path, root) }

      # Whether a path's text is the start of a denied root's (its parent,
      # or part of its name: ~/.ss) or inside one.
      def leads_into_denied?(prefix)
        @paths.denied_roots.any? { |root| root.start_with?(prefix) || PathResolve.under?(prefix, root) }
      end

      # Whether +path+ is a denied root's folder or one above it.
      def above_denied?(path)
        PathResolve.reals(path).any? { |real| @paths.denied_roots.any? { |root| PathResolve.under?(root, real) } }
      end

      def link_command?(words)
        at = program_at(words)
        program = at && File.basename(words[at])
        return true if LINKERS.include?(program)
        return true if program == "cp" && words[(at + 1)..].any? { |arg| arg.match?(CP_LINK_OPTION) }
        return true if words.each_cons(2).any? { |option, word| CODE_OPTIONS.include?(option) && LINKERS.include?(File.basename(word)) }

        runner = (0..(at || (words.size - 1))).find { |i| runner?(words[i]) } or return false
        name = File.basename(words[runner])
        scripts(words, runner).any? do |script|
          SHELLS.include?(name) || name == "eval" ? nested(script).links? : script.match?(SCRIPT_LINK_TEXT)
        end
      end

      def env_loader_command?(words)
        at = program_at(words)
        return true if at && ENV_LOADERS.include?(File.basename(words[at]))
        return true if words.each_cons(2).any? { |option, word| CODE_OPTIONS.include?(option) && ENV_LOADERS.include?(File.basename(word)) }

        runner = (0..(at || (words.size - 1))).find { |i| runner?(words[i]) } or return false
        name = File.basename(words[runner])
        scripts(words, runner).any? do |script|
          SHELLS.include?(name) || name == "eval" ? nested(script).loads_env? : script.match?(ENV_LOADER_TEXT)
        end
      end

      def nested(script) = PairCommand.new(script, cwd: @cwd, paths: @paths, home: @home, root: @root,
                                                   depth: @depth + 1, web: @web)

      # Whether it only reads but for writes (a > or >> target, cp's
      # destination, tee's files) into the project or a tmp dir.
      def writes_inside?
        ReadOnlyShell.read_only_but_writes?(@text, cwd: @cwd, home: @home, env: ENV) { |path| writable?(path) }
      end

      # Whether it stays inside the project: every simple command runs in
      # it, and every path it names lands in it or a tmp dir, a script it
      # hands on included (a shell's read as a command, another
      # interpreter's paths by its text). The program's own word is not a
      # path it writes; a word it can't resolve ($var, a $(…) other than a
      # message's heredoc, a dir it can't tell) is outside. A script file's
      # body (ruby x.rb, make) is not read.
      def stays_inside?
        return false if @root.empty? || @depth > MAX_DEPTH

        tokens = ShellLex.lex(@text)
        return false if tokens.any? { |_, value| value.include?(ShellLex::SUBST) } && !substs_messages_only?

        walk = ShellPaths::Walk.new(@cwd, @home, ENV)
        piped = ShellLex.piped_flags(tokens)
        ShellLex.simple_commands(tokens).all? do |words|
          next walk.step(words) if words.is_a?(Symbol)

          stdin = PairCommand.script_source(words, piped: piped.shift) == :stdin || git_hands_command?(words)
          walk.dirs.all? { |dir| dir && writable?(dir) } && words_inside?(words, walk) &&
            !implicit_outside?(words, walk) && !stdin && scripts_inside?(words).tap { walk.step(words) }
        end
      end

      # A program that writes to its own place outside with no word naming
      # it (ImplicitWriters: npm -g, gem install, brew, defaults write, …),
      # wherever it stands among the wrappers (sudo npm, bundle config),
      # python -m's module as the program, under the assignments before it
      # (npm_config_global=true).
      def implicit_outside?(words, walk)
        at = program_at(words) or return false
        assigned = words[0...at].filter_map { |word| word.split("=", 2) if word.match?(/\A[A-Za-z_]\w*=/) }.to_h
        (0..at).any? do |i|
          program = words[i]
          args = words[(i + 1)..]
          local = project_program?(walk, program)
          if PairCommand.interpreter?(File.basename(program)) && (module_args = module_run(args))
            program, args = module_args
          end
          ImplicitWriters.outside?(program, args, local: local, assigned: assigned)
        end
      end

      # An interpreter's -m module and the words after it ([name, args]):
      # -m pip, -mpip; nil without one.
      def module_run(args)
        args.each_with_index do |arg, i|
          return [args[i + 1], args[(i + 2)..]] if arg == "-m" && args[i + 1]
          return [arg.delete_prefix("-m"), args[(i + 1)..]] if arg.match?(/\A-m\w/)
        end
        nil
      end

      # Whether a git command runs a command now that it is handed as text
      # (.git_commands): where it writes isn't placed, so it asks.
      def git_hands_command?(words)
        at = program_at(words) or return false
        program, args = PairCommand.git_form(File.basename(words[at]), words[(at + 1)..])
        program == "git" && !git_commands(args).empty?
      end

      # Whether a program's word is a path into the project (.venv/bin/pip).
      def project_program?(walk, word)
        return false unless word.include?("/")

        paths = walk.paths(word)
        !paths.empty? && paths.all? { |path| Outside.inside?(path, root: @root) }
      end

      # Whether every $(…) is a message's heredoc (its body cut as data).
      def substs_messages_only?
        rest = ShellLex.code_text(@text, keep_written: false).gsub(MESSAGE_SUBST, "")
        !rest.include?("$(") && !rest.include?("`")
      end

      # Whether each word of a simple command but the program (and the
      # wrappers before it) lands in the project or a tmp dir.
      def words_inside?(words, walk)
        at = program_at(words)
        # xargs runs its program on paths it reads from its input
        return false if at && words[0...at].any? { |word| File.basename(word) == "xargs" }

        words.each_with_index.all? do |word, i|
          next true if at && (i == at || (i < at && WRAPPERS.include?(File.basename(word))))
          next true if LIST_VARIABLES.any? { |name| word.start_with?("#{name}=") }

          word_inside?(walk, word)
        end
      end

      def word_inside?(walk, word)
        return true if data?(word)
        return substs_messages_only? if word.include?(ShellLex::SUBST)

        candidate = walk.candidate(word) or return true
        return text_inside?(walk, candidate) if candidate.match?(ShellPaths::SCRIPT)
        return glob_inside?(walk, candidate) if candidate.match?(GLOB) && !candidate.include?("$")

        paths = walk.paths(candidate)
        !paths.empty? && paths.all? { |path| DEVICES.include?(path) || writable?(path) }
      end

      # A word with spaces or quotes is text (a message, a pattern) unless
      # it starts like a path.
      def text_inside?(walk, text)
        return true unless text.match?(%r{\A(?:~|\.\.|/)})

        expanded = expand_tilde(text)
        return false if expanded.start_with?("~")

        walk.dirs.all? { |dir| (dir || expanded.start_with?("/")) && writable?(File.expand_path(expanded, dir || "/")) }
      end

      # A glob by its fixed part (the text before its first glob character).
      def glob_inside?(walk, word)
        fixed = word[/\A[^*?\[\]{}]*/]
        return walk.dirs.all? { |dir| dir && writable?(dir) } if fixed.empty?

        paths = walk.paths(fixed)
        !paths.empty? && paths.all? { |path| writable?(path) }
      end

      # The scripts a simple command hands on (#scripts): a shell's as a
      # command of its own, another interpreter's by the paths in its text.
      def scripts_inside?(words)
        limit = program_at(words) || (words.size - 1)
        at = (0..limit).find { |i| runner?(words[i]) } or return true
        program = File.basename(words[at])
        scripts(words, at).all? do |script|
          if SHELLS.include?(program) || program == "eval"
            !nested(script).outside_writes?
          else
            script.scan(SCRIPT_PATH).all? { |path| writable?(File.expand_path(expand_tilde(path), @cwd || Dir.pwd)) }
          end
        end
      end

      def writable?(path) = PairCommand.writable?(path, root: @root, cwd: @cwd)

      # +text+ with a leading ~ (alone or before a /) as the home folder.
      def expand_tilde(text) = text.sub(%r{\A~(?=/|\z)}, @home)
    end
  end
end
