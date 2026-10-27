# frozen_string_literal: true

require "tmpdir"
require_relative "review_paths"
require_relative "shell_paths"
require_relative "shell_lex"

module Samagotchi
  module Guardrails
    # One shell command of a participant's pair turn, read the way
    # PairBoundary needs it (the refusal words are PairBoundary's):
    # - #refusal: why it may not run, nil when it may: chi, something left
    #   running, the environment or the keychain, git settings that run
    #   commands, a folder sweep, a secret (a path a word resolves to, a glob
    #   or a $var whose fixed part leads into one, SECRET_TEXT for the
    #   rest); a script it hands a shell (sh -c, eval, a heredoc) is read as
    #   a command of its own, one it hands another interpreter (ruby -e,
    #   python <<EOF) by its text. A command it can't read is refused
    #   (UNREADABLE), never let through on a text match;
    # - #outside_writes?: whether it writes outside the project (a
    #   redirection's target, tee's files, cp/mv/ln/install/rsync/ditto's
    #   destination), the tmp dirs and /dev/null aside; a target it can't
    #   resolve counts as outside.
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
      # Programs that detach what they start.
      DETACHERS = %w[nohup setsid disown daemonize].freeze
      # Programs that print the environment or a keychain's secrets, whatever
      # their arguments.
      ENV_READERS = %w[printenv security].freeze
      ENV_TEXT = %r{/proc/[^\s]*/environ}
      # An interpreter's script that reads the environment or detaches.
      SCRIPT_ENV_TEXT = /\bos\.environ\b|\bgetenv\b|\bprocess\.env\b|\bENV\b|\bprintenv\b|%ENV\b/
      SCRIPT_BACKGROUND_TEXT = /\b(?:nohup|setsid|disown|daemonize|Process\.daemon|detach(?:ed)?)\b/
      # Programs that read a folder's whole tree: given home (or any folder
      # above a denied one) they reach the secrets in it.
      SWEEPERS = %w[find tar cp rsync scp zip 7z cpio grep egrep fgrep rg ag ack fd ditto].freeze
      # git settings that make git run a command (or show one), and git
      # config's scopes beyond the repository.
      GIT_RUNNING_KEYS = %w[core.fsmonitor core.sshcommand core.hookspath core.pager core.editor].freeze
      GIT_WIDE_SCOPES = %w[--global --system].freeze
      GIT_VALUE_OPTIONS = %w[-C --git-dir --work-tree --namespace --exec-path].freeze
      # Writers whose last argument (or -t DIR) is the destination.
      COPIERS = %w[cp mv ln install rsync ditto].freeze
      REDIRECTS = %w[> >> &> &>> 1> 1>> 2> 2>>].freeze
      REDIRECT_WORD = /\A\d*(?:&>>?|>>?)(?!&)(.+)\z/
      DEVICES = %w[/dev/null /dev/stdout /dev/stderr /dev/tty].freeze
      GLOB = /[*?\[\]{}]/
      # How many matches of a glob are checked against the denylist.
      GLOB_LIMIT = 500
      # How deep scripts handed to a shell are read; deeper is UNREADABLE.
      MAX_DEPTH = 3

      # The tmp dirs a pair turn writes into freely (neither asked nor
      # denied): Dir.tmpdir, $TMPDIR, /tmp, /private/tmp.
      def self.tmp_roots
        [Dir.tmpdir, ENV.fetch("TMPDIR", nil), "/tmp", "/private/tmp"].compact.reject(&:empty?)
                                                                      .map { |dir| ProtectedPaths.real(dir) }.uniq
      end

      # @param paths [ReviewPaths] the denylist
      # @param root [String, nil] the project root (outside writes)
      def initialize(text, cwd:, paths:, home:, root: nil, depth: 0, tmp_roots: nil)
        @tmp_roots = tmp_roots
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
        @refusal = PairBoundary::UNREADABLE
      end

      # Whether it writes outside the project (asked about, never denied).
      def outside_writes?
        refusal
        @targets.to_a.any? { |path| outside?(path) }
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
        return PairBoundary::SECRET if subst && code.match?(PairBoundary::SECRET_TEXT)

        @targets = []
        walk = ShellPaths::Walk.new(@cwd, @home, ENV)
        ShellLex.simple_commands(tokens).each do |words|
          next walk.step(words) if words.is_a?(Symbol)

          @targets.concat(write_targets(words, walk))
          reason = words_refusal(words) || scripts_refusal(words) || paths_refusal(words, walk.step(words))
          return reason if reason
        end
        nil
      end

      # A simple command's own refusal, by its program and arguments.
      def words_refusal(words)
        at = program_at(words)
        program = at && File.basename(words[at])
        args = at ? words[(at + 1)..] : []
        return PairBoundary::CHI if program == "chi" && !CHI_ALLOWED.include?(args)
        return PairBoundary::CHI if chi_in_values?(words)

        upto = at ? words[0..at] : words
        return PairBoundary::BACKGROUND if upto.any? { |w| DETACHERS.include?(File.basename(w)) } || detached_session?(program, args)
        return PairBoundary::ENVIRONMENT if env_reader?(program, args) || bare_env?(words)
        return PairBoundary::GIT_CONFIG if program == "git" && git_runs_commands?(args)

        nil
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
                     PairCommand.new(script, cwd: @cwd, paths: @paths, home: @home, root: @root, depth: @depth + 1,
                                             tmp_roots: @tmp_roots).refusal
                   elsif INTERPRETERS.include?(program)
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

      # printenv, security; set, export, declare and typeset that list
      # (no assignment); launchctl getenv/export; ps with a BSD e (ps e, eww).
      def env_reader?(program, args)
        return true if ENV_READERS.include?(program)

        listing = args.none? { |arg| !arg.start_with?("-", "+") }
        case program
        when "set" then args.empty?
        when "export", "declare", "typeset" then listing
        when "launchctl" then %w[getenv export].include?(args.first)
        when "ps" then args.any? { |arg| arg.match?(/\A[a-zA-Z]*e[a-zA-Z]*\z/) }
        else false
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
      # glob character or $, with ~ and $HOME expanded). A script body
      # (spaces, quotes), a data heredoc or a $(…) is left to the other checks.
      def unresolved_secret?(word)
        return false if word.include?("\0") || word.match?(ShellPaths::SCRIPT)

        expanded = word.sub(%r{\A~(?=/|\z)}, @home).sub(/\A\$(?:\{HOME\}|HOME\b)/, @home)
        fixed = expanded[/\A[^*?\[\]{}$]*/]
        dir = @cwd || Dir.pwd
        if !expanded.include?("$") && expanded.match?(GLOB)
          matches = Dir.glob(File.expand_path(expanded, dir)).first(GLOB_LIMIT)
          return true unless @paths.secret_refusal(matches).nil?
        end
        return false if fixed.empty?

        leads_into_denied?(File.expand_path(fixed, dir))
      end

      # Whether a path's text is the start of a denied root's (its parent,
      # or part of its name: ~/.ss) or inside one.
      def leads_into_denied?(prefix)
        @paths.denied_roots.any? { |root| root.start_with?(prefix) || ShellPaths.within?(prefix, root) }
      end

      # Whether +path+ is a denied root's folder or one above it.
      def above_denied?(path)
        real = ProtectedPaths.real(path)
        @paths.denied_roots.any? { |root| ShellPaths.within?(root, real) }
      end

      # The paths a simple command writes (nil for one it can't resolve), from
      # the dir it runs in (before a cd in it takes effect).
      def write_targets(words, walk)
        targets = []
        words.each_with_index do |word, i|
          if REDIRECTS.include?(word) && words[i + 1]
            targets << walk.path(words[i + 1])
          elsif (target = word[REDIRECT_WORD, 1]) && !word.start_with?("<")
            targets << walk.path(target)
          end
        end
        at = program_at(words) or return targets
        program = File.basename(words[at])
        args = words[(at + 1)..].reject { |w| REDIRECTS.include?(w) || w.match?(REDIRECT_WORD) }
        plain = args.reject { |arg| arg.start_with?("-") }
        if program == "tee"
          targets.concat(plain.map { |arg| walk.path(arg) })
        elsif COPIERS.include?(program)
          dir = args[args.index("-t") + 1] if args.include?("-t")
          dir ||= args.find { |arg| arg.start_with?("--target-directory=") }&.split("=", 2)&.last
          dir ||= plain.last if plain.size >= 2
          targets << walk.path(dir) if dir
        end
        targets
      end

      def outside?(path)
        return true if path.nil?
        return false if DEVICES.include?(path)

        real = ProtectedPaths.real(path)
        return false if tmp_roots.any? { |tmp| ShellPaths.within?(real, tmp) }
        return true if @root.empty?

        !ShellPaths.within?(real, ProtectedPaths.real(@root))
      end

      def tmp_roots = @tmp_roots ||= PairCommand.tmp_roots
    end
  end
end
