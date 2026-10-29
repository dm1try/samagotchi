# frozen_string_literal: true

require_relative "shell_lex"
require_relative "path_resolve"
require_relative "../redacted_inspect"

module Samagotchi
  module Guardrails
    # Whether a shell command names a path in one of some dirs (a rule's
    # touches: chi_dirs): each word is read as a path, against the dir the
    # command is in by then (cd, pushd/popd and ( … ) followed as in
    # ShellGitDirs), with ~, $HOME and the XDG dirs expanded and symlinks
    # resolved. A word names a dir when it is in it. Any path with a
    # .git/hooks part counts too, outside the tmp dirs.
    #
    # A word it can't resolve (another $VAR, $(…), a glob, a relative path
    # after cd $X) or one that reads as a script (sh -c '…', ruby -e '…':
    # spaces, quotes, operators in it) falls back to a text match (+text+);
    # so does the whole command when it holds a $(…) or backticks (the lexer
    # keeps no body), except for message heredoc bodies ShellLex.code_text
    # recognizes as data.
    module ShellPaths
      # A word that is a script rather than a path.
      SCRIPT = /[\s;&|<>()'"`]/
      GLOB = /[*?\[\]{}]/
      HOOKS_PART = %r{(?:\A|/)\.git/hooks(?:/|\z)}
      # $HOME, ${HOME} and the XDG dirs at a word's start.
      EXPANSION = /\A\$(?:\{(HOME|XDG_[A-Z_]+|TMPDIR)\}|(HOME|XDG_[A-Z_]+|TMPDIR)\b)/
      # Where XDG dirs default when unset.
      XDG_DEFAULTS = { "XDG_CONFIG_HOME" => ".config", "XDG_STATE_HOME" => ".local/state",
                       "XDG_DATA_HOME" => ".local/share", "XDG_CACHE_HOME" => ".cache" }.freeze
      # A redirection's operator at a word's start (>>file, 2>file, <file).
      REDIRECT_PREFIX = /\A\d*(?:&>>?|>>?&?|<)/

      module_function

      # @param command [String]
      # @param dirs [Array<String>] absolute dirs (resolved here)
      # @param text [Regexp] the fallback for a word that can't be resolved
      # @param cwd [String, nil] where the command starts
      # @param tmp_roots [Array<String>] where a .git/hooks part doesn't count
      def touches?(command, dirs:, text:, cwd:, home: Dir.home, env: ENV, tmp_roots: [])
        roots = dirs.compact.map { |dir| PathResolve.real(dir.to_s.chomp("/")) }.reject(&:empty?).uniq
        any_path?(command, text: text, cwd: cwd, home: home, env: env) { |path| names?(path, roots, tmp_roots) }
      end

      # Whether a word of +command+ names a path the block holds for (each
      # word resolved as #touches? resolves it); a word that can't be
      # resolved, a command with a $(…) or backticks, or one that doesn't
      # lex, by the text match +text+ instead.
      # @yieldparam path [String] an absolute path (not resolved for
      #   symlinks but for a `..` climbing out of one: Walk)
      def any_path?(command, text:, cwd:, home: Dir.home, env: ENV)
        walk = Walk.new(cwd, home, env)
        tokens = ShellLex.lex(command.to_s)
        code = ShellLex.code_text(command.to_s)
        return true if tokens.any? { |_, value| value.include?(ShellLex::SUBST) } && code.match?(text)

        ShellLex.simple_commands(tokens).any? do |words|
          walk.step(words).any? { |word, path| path ? yield(path) : word.match?(text) }
        end
      rescue ArgumentError, EncodingError
        command.to_s.scrub.match?(text)
      end

      def names?(path, roots, tmp_roots)
        PathResolve.reals(path).any? do |real|
          next true if roots.any? { |root| within?(real, root) }

          real.match?(HOOKS_PART) && tmp_roots.none? { |tmp| within?(real, tmp) }
        end
      end

      # Whether +path+ is +root+ or in it, cased alike on a disk that folds
      # case (PathResolve.under?).
      def within?(path, root) = PathResolve.under?(path, root)

      # Follows the current dir and gives, per simple command, each word
      # with its path (nil when it can't be resolved). A word is opened the
      # kernel's way, so a `..` after a symlinked dir climbs out of its
      # target: such a word comes twice, with its lexical path and its
      # physical one (PathResolve.expand), and a check reads both. A cd
      # or pushd to such a word may land at either (the shell's logical cd
      # chdirs to the physical path when the logical one doesn't exist, and
      # always with -P, set -P or zsh's chase_links/chase_dots), so the walk
      # keeps every dir the command may be in by then and resolves later
      # words against each (a word not resolvable from one of them isn't
      # resolved). A symlink without a `..` lands at the same file either
      # way.
      class Walk
        include RedactedInspect

        # More dirs than this after a cd: the dir is unknown.
        MAX_DIRS = 8

        def initialize(cwd, home, env)
          @dirs = [cwd]
          @home = home
          @env = env
          @subshells = []
          @pushed = []
        end

        # @param words [Array<String>, Symbol] a simple command, :open or :close
        # @return [Array<[String, String|nil]>]
        def step(words)
          case words
          when :open then @subshells << @dirs
                          []
          when :close then @dirs = @subshells.pop || @dirs
                           []
          else command(words)
          end
        end

        # Every dir the command may be in by now (nil for one it can't tell).
        def dirs = @dirs.dup

        # The part of +word+ that may be a path: an option's or an
        # assignment's value, a redirection's target; nil for an option
        # alone or an operator.
        def candidate(word)
          word = word.sub(REDIRECT_PREFIX, "")
          word = word.split("=", 2).last if word.match?(/\A(--?[\w-]+|[A-Za-z_]\w*)=/)
          return nil if word.empty? || word == "-" || word.match?(%r{\A-[^/]})

          word
        end

        # The absolute paths for +word+ against every dir the command may be
        # in (.paths_for), [] when it can't be resolved from one of them.
        def paths(word)
          found = @dirs.map { |dir| paths_for(word, dir) }
          found.any?(&:empty?) ? [] : found.flatten.uniq
        end

        private

        def command(words)
          verb = words.find { |w| !w.match?(/\A[A-Za-z_]\w*=/) }
          cd_args = words.drop_while { |w| w != verb }.drop(1).grep_v(/\A-./)
          resolved = words.filter_map { |word| candidate(word) }.flat_map do |word|
            paths = paths(word)
            paths.empty? ? [[word, nil]] : paths.map { |path| [word, path] }
          end
          case verb
          when "cd" then @dirs = cd_args.empty? ? [@home] : dirs_after(cd_args.first)
          when "pushd"
            @pushed << @dirs
            @dirs = cd_args.first ? dirs_after(cd_args.first) : [nil]
          when "popd" then @dirs = @pushed.pop unless @pushed.empty?
          end
          resolved
        end

        # Every dir a cd to +word+ may land at, from each current one (nil
        # for one it can't tell: `cd -` among them); [nil] past MAX_DIRS.
        def dirs_after(word)
          return [nil] if word == "-"

          dirs = @dirs.flat_map do |dir|
            found = paths_for(word, dir)
            found.empty? ? [nil] : found
          end.uniq
          dirs.size > MAX_DIRS ? [nil] : dirs
        end

        # +word+ as a file argument against +dir+: its lexical path, and its
        # physical one when a `..` in it climbs out of a symlinked dir's
        # target (PathResolve.expand); [] when it can't be resolved.
        def paths_for(word, dir)
          lexical = resolve(word, dir) or return []
          return [lexical] unless word.include?("..")

          [lexical, PathResolve.expand(expand(word), dir)].uniq
        end

        # An absolute path for +word+ against +dir+ with `..` taken
        # lexically, or nil.
        def resolve(word, dir)
          return nil if word.include?(ShellLex::SUBST) || word == ShellLex::HEREDOC || word.match?(SCRIPT)

          word = expand(word) or return nil
          return nil if word.match?(GLOB)
          return File.expand_path(word) if word.start_with?("/")

          dir && File.expand_path(word, dir)
        end

        def expand(word) = ShellPaths.expand_word(word, home: @home, env: @env)
      end

      # +word+ with a leading ~, $HOME/${HOME}, an XDG dir or $TMPDIR
      # expanded (+env+'s value, an unset XDG dir its default under +home+);
      # nil when a $ or ~ is left. ShellGitDirs expands the same way.
      def expand_word(word, home:, env:)
        word = word.sub(%r{\A~(?=/|\z)}) { home }
        word = word.sub(EXPANSION) { variable(Regexp.last_match(1) || Regexp.last_match(2), home, env) || "$" }
        return nil if word.include?("$") || word.start_with?("~")

        word
      end

      def variable(name, home, env)
        return home if name == "HOME"

        set = env[name].to_s
        return set unless set.empty?

        XDG_DEFAULTS[name] && File.join(home, XDG_DEFAULTS[name])
      end
    end
  end
end
