# frozen_string_literal: true

require_relative "outside"
require_relative "path_resolve"
require_relative "read_only_shell"
require_relative "review_paths"
require_relative "shell_paths"
require_relative "shell_lex"

module Samagotchi
  module Guardrails
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
      # Other interpreters a script can be handed to (-e/-c, a heredoc).
      INTERPRETERS = %w[python python3 python2 ruby irb node deno bun perl php lua osascript jshell].freeze
      # Options whose next word is code or a command, for any program.
      CODE_OPTIONS = %w[-c -e -exec --exec -execdir --command --eval -x].freeze
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
      # git settings that make git run a command (or show one), and git
      # config's scopes beyond the repository.
      GIT_RUNNING_KEYS = %w[core.fsmonitor core.sshcommand core.hookspath core.pager core.editor].freeze
      GIT_WIDE_SCOPES = %w[--global --system].freeze
      GIT_VALUE_OPTIONS = %w[-C --git-dir --work-tree --namespace --exec-path].freeze
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

        @outside_writes = !(ReadOnlyShell.read_only?(@text) || writes_inside? || stays_inside?)
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
        return PairBoundary::GIT_CONFIG if program == "git" && git_runs_commands?(args)
        return PairBoundary::OPENER if opener?(program, args)
        return PairBoundary::LISTENER if listener?(program, args)

        nil
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
                   elsif INTERPRETERS.include?(program)
                     @mise_config = true if script.match?(MISE_CONFIG_TEXT)
                     script_text_refusal(script)
                   end
          return reason if reason
        end
        nil
      end

      def runner?(word)
        name = File.basename(word)
        SHELLS.include?(name) || INTERPRETERS.include?(name) || name == "eval"
      end

      def scripts(words, at)
        found = []
        found << words[(at + 1)..].join(" ") if File.basename(words[at]) == "eval"
        words.each_with_index do |word, i|
          next if i.zero? || word == ShellLex::HEREDOC

          previous = words[i - 1]
          found << word if previous.start_with?("<<") || (i > at && %w[-c -e].include?(previous))
        end
        found
      end

      def script_text_refusal(script)
        return PairBoundary::CHI if script.match?(CHI_TEXT)
        return PairBoundary::SECRET if script.match?(PairBoundary::SECRET_TEXT)
        return PairBoundary::ENVIRONMENT if script.match?(SCRIPT_ENV_TEXT) || script.match?(ENV_TEXT)
        return PairBoundary::BACKGROUND if script.match?(SCRIPT_BACKGROUND_TEXT)
        return PairBoundary::OPENER if script.match?(SCRIPT_OPENER_TEXT)
        return PairBoundary::LISTENER if script.match?(SCRIPT_LISTEN_TEXT)

        nil
      end

      # Where the program is in +words+: past assignments, wrappers, shell
      # keywords and their options (and an option's value: ruby -I lib,
      # timeout 10).
      def program_at(words)
        at = 0
        at += 1 while at < words.size && skipped?(words, at)
        at < words.size ? at : nil
      end

      def skipped?(words, at)
        word = words[at]
        return true if word.match?(/\A[A-Za-z_]\w*=/) || word.start_with?("-") || word.match?(/\A\d+[smhd]?\z/)
        return true if WRAPPERS.include?(File.basename(word))

        previous = at.positive? ? words[at - 1] : nil
        !previous.nil? && previous.match?(/\A-[IrCen]\z/)
      end

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

      # git config beyond the repository (--global, --system), or a setting
      # that runs a command (core.hooksPath, core.fsmonitor, core.sshCommand,
      # core.pager, core.editor, a "!" alias), set with git config or git -c.
      def git_runs_commands?(args)
        i = 0
        while i < args.size && args[i].start_with?("-")
          if args[i] == "-c"
            return true if running_setting?(*args[i + 1].to_s.split("=", 2))

            i += 2
          elsif GIT_VALUE_OPTIONS.include?(args[i])
            i += 2
          else
            i += 1
          end
        end
        return false unless args[i] == "config"

        rest = args[(i + 1)..]
        return true if rest.any? { |arg| GIT_WIDE_SCOPES.include?(arg) }

        key, value = rest.reject { |arg| arg.start_with?("-") }
        running_setting?(key, value)
      end

      def running_setting?(key, value)
        key = key.to_s.downcase
        GIT_RUNNING_KEYS.include?(key) || (key.start_with?("alias.") && value.to_s.lstrip.start_with?("!"))
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
        ShellLex.simple_commands(tokens).all? do |words|
          next walk.step(words) if words.is_a?(Symbol)

          walk.dirs.all? { |dir| dir && writable?(dir) } && words_inside?(words, walk) &&
            scripts_inside?(words).tap { walk.step(words) }
        end
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
