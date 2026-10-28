# frozen_string_literal: true

require_relative "shell_lex"
require_relative "protected_paths"

module Samagotchi
  module Guardrails
    # Where a shell command runs a git subcommand that changes a checkout
    # (commit, add, reset, …): the directories, or :unknown for one that
    # can't be read from the text ($VAR, $(…), `cd -`). Read from the text:
    # it follows cd/pushd/popd, ( … ) subshells, git -C/--git-dir/--work-tree
    # and GIT_DIR/GIT_WORK_TREE. A cd keeps the shell's logical `..` (`cd
    # link/..` is back where it started); git's -C and dir options are
    # opened the kernel's way, so where a `..` in one climbs out of a
    # symlinked dir's target, that git counts twice: from the lexical path
    # and from the physical one (ProtectedPaths.expand, the only look at the
    # disk). It catches honest mistakes (cd into another checkout and commit
    # there); sh -c, scripts, aliases and $(…) bodies get through. Never
    # raises on odd input.
    module ShellGitDirs
      MUTATING = %w[commit add reset checkout switch rebase merge push stash rm mv
                    cherry-pick revert pull restore am].freeze
      STASH_READS = %w[list show].freeze
      PREFIXES = %w[command builtin exec time nohup env ! { if then else elif do while until].freeze
      # git global options that take the next word as their value.
      VALUE_OPTIONS = %w[-C -c --git-dir --work-tree --namespace].freeze

      # @param command [String] the shell command
      # @param cwd [String] where it starts (the call's cwd:, else the session's)
      # @param home [String] for ~, $HOME, ${HOME} and a bare cd
      # @param env [Hash{String=>String}] the call's env: (task_create's):
      #   its GIT_DIR / GIT_WORK_TREE hold for each git unless it sets its own
      # @return [Array<String, Symbol>] absolute dirs and :unknown, unique
      def self.for(command, cwd:, home: Dir.home, env: {})
        Walk.new(cwd, home, env).run(ShellLex.simple_commands(ShellLex.lex(command.to_s)))
      rescue ArgumentError, EncodingError
        [] # a NUL byte, invalid UTF-8: the shell would refuse it too
      end

      # Follows the current dir through the simple commands and records
      # where each mutating git runs.
      class Walk
        def initialize(cwd, home, env = {})
          @dir = cwd
          @home = home
          @env = env.slice("GIT_DIR", "GIT_WORK_TREE")
          @subshells = []
          @pushed = []
          @found = []
        end

        def run(commands)
          commands.each do |words|
            case words
            when :open then @subshells << @dir
            when :close then @dir = @subshells.pop || @dir
            else simple(words.dup)
            end
          end
          @found.uniq
        end

        private

        def simple(words)
          env = @env.dup
          while (word = words.first)
            if word.match?(/\A[A-Za-z_]\w*=/)
              key, value = word.split("=", 2)
              env[key] = value
            elsif !PREFIXES.include?(word)
              break
            end
            words.shift
          end
          verb = words.shift or return
          args = words.grep_v(ShellLex::REDIRECT)
          case verb
          when "cd" then cd(args)
          when "pushd"
            @pushed << @dir
            @dir = args.first ? expand(args.first, @dir) : nil
          when "popd" then @dir = @pushed.pop unless @pushed.empty?
          else git(args, env) if verb == "git" || verb.end_with?("/git")
          end
        end

        def cd(args)
          target = args.reject { |a| %w[-P -L -e -@].include?(a) }.first
          @dir = if target.nil? then @home
                 elsif target == "-" then nil
                 else expand(target, @dir)
                 end
        end

        def git(args, env)
          @found.concat([false, true].filter_map { |physical| where_git(args.dup, env, physical) })
        end

        # Where a mutating git runs (a dir or :unknown), nil for another
        # git; +physical+: its dir options' `..` taken the kernel's way.
        def where_git(args, env, physical)
          expand = ->(arg, base) { expand(arg, base, physical: physical) }
          dir = @dir
          work_tree = env["GIT_WORK_TREE"] && expand.call(env["GIT_WORK_TREE"], dir)
          git_dir = env["GIT_DIR"] && expand.call(env["GIT_DIR"], dir)
          sub = nil
          until args.empty?
            arg = args.shift
            case arg
            when *VALUE_OPTIONS
              value = args.shift.to_s
              dir = expand.call(value, dir) if arg == "-C"
              git_dir = expand.call(value, dir) if arg == "--git-dir"
              work_tree = expand.call(value, dir) if arg == "--work-tree"
            when /\A--git-dir=(.*)\z/m then git_dir = expand.call(Regexp.last_match(1), dir)
            when /\A--work-tree=(.*)\z/m then work_tree = expand.call(Regexp.last_match(1), dir)
            when /\A-/ then next
            else
              sub = arg
              break
            end
          end
          return nil unless MUTATING.include?(sub)
          return nil if sub == "stash" && STASH_READS.include?(args.first)

          work_tree || repo_of(git_dir) || dir || :unknown
        end

        def repo_of(git_dir)
          return nil unless git_dir

          File.basename(git_dir) == ".git" ? File.dirname(git_dir) : git_dir
        end

        # An absolute path for +arg+ against +dir+ (`..` lexical, as cd
        # takes it, or +physical+: ProtectedPaths.expand); nil when it can't
        # be told from the text (a variable, a substitution, a relative path
        # against an unknown dir).
        def expand(arg, dir, physical: false)
          return nil if arg.include?(ShellLex::SUBST)

          arg = arg.sub(%r{\A(~|\$HOME|\$\{HOME\})(?=/|\z)}) { @home }
          return nil if arg.include?("$") || arg.start_with?("~")
          return nil unless arg.start_with?("/") || dir

          physical ? ProtectedPaths.expand(arg, dir) : File.expand_path(arg, dir)
        end
      end
    end
  end
end
