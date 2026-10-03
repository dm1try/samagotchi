# frozen_string_literal: true

require_relative "shell_lex"
require_relative "protected_paths"

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
    # so does the whole command when it holds a $(…) or backticks (the
    # lexer keeps no body).
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
        roots = dirs.compact.map { |dir| ProtectedPaths.real(dir.to_s.chomp("/")) }.reject(&:empty?).uniq
        walk = Walk.new(cwd, home, env)
        tokens = ShellLex.lex(command.to_s)
        return true if tokens.any? { |_, value| value.include?(ShellLex::SUBST) } && command.to_s.match?(text)

        ShellLex.simple_commands(tokens).any? do |words|
          walk.step(words).any? { |word, path| path ? names?(path, roots, tmp_roots) : word.match?(text) }
        end
      rescue ArgumentError, EncodingError
        command.to_s.scrub.match?(text)
      end

      def names?(path, roots, tmp_roots)
        real = ProtectedPaths.real(path)
        return true if roots.any? { |root| within?(real, root) }

        real.match?(HOOKS_PART) && tmp_roots.none? { |tmp| within?(real, tmp) }
      end

      def within?(path, root) = path == root || path.start_with?(File.join(root, ""))

      # Follows the current dir and gives, per simple command, each word
      # with its path (nil when it can't be resolved).
      class Walk
        def initialize(cwd, home, env)
          @dir = cwd
          @home = home
          @env = env
          @subshells = []
          @pushed = []
        end

        # @param words [Array<String>, Symbol] a simple command, :open or :close
        # @return [Array<[String, String|nil]>]
        def step(words)
          case words
          when :open then @subshells << @dir
                          []
          when :close then @dir = @subshells.pop || @dir
                           []
          else command(words)
          end
        end

        # An absolute path for +word+ against the current dir, or nil.
        def path(word) = resolve(word, @dir)

        private

        def command(words)
          verb = words.find { |w| !w.match?(/\A[A-Za-z_]\w*=/) }
          resolved = words.filter_map { |word| candidate(word) }.map { |word| [word, resolve(word, @dir)] }
          cd_args = words.drop_while { |w| w != verb }.drop(1).grep_v(/\A-/)
          case verb
          when "cd" then @dir = cd_args.empty? ? @home : resolve(cd_args.first, @dir)
          when "pushd"
            @pushed << @dir
            @dir = cd_args.first && resolve(cd_args.first, @dir)
          when "popd" then @dir = @pushed.pop unless @pushed.empty?
          end
          resolved
        end

        # The part of +word+ that may be a path: an option's or an
        # assignment's value, a redirection's target; nil for an option
        # alone or an operator.
        def candidate(word)
          word = word.sub(REDIRECT_PREFIX, "")
          word = word.split("=", 2).last if word.match?(/\A(--?[\w-]+|[A-Za-z_]\w*)=/)
          return nil if word.empty? || word == "-" || word.match?(/\A-[^\/]/)

          word
        end

        # An absolute path for +word+ against +dir+, or nil.
        def resolve(word, dir)
          return nil if word.include?(ShellLex::SUBST) || word.match?(SCRIPT)

          word = expand(word) or return nil
          return nil if word.match?(GLOB)
          return File.expand_path(word) if word.start_with?("/")

          dir && File.expand_path(word, dir)
        end

        def expand(word)
          word = word.sub(/\A~(?=\/|\z)/) { @home }
          word = word.sub(EXPANSION) { value(Regexp.last_match(1) || Regexp.last_match(2)) || "$" }
          return nil if word.include?("$") || word.start_with?("~")

          word
        end

        def value(name)
          return @home if name == "HOME"

          set = @env[name].to_s
          return set unless set.empty?

          XDG_DEFAULTS[name] && File.join(@home, XDG_DEFAULTS[name])
        end
      end
    end
  end
end
