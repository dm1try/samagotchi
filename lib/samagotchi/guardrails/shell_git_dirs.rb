# frozen_string_literal: true

require_relative "shell_lex"

module Samagotchi
  module Guardrails
    # Where a shell command runs a git subcommand that changes a checkout
    # (commit, add, reset, …): the directories, or :unknown for one that
    # can't be read from the text ($VAR, $(…), `cd -`). Pure text: it
    # follows cd/pushd/popd, ( … ) subshells, git -C/--git-dir/--work-tree
    # and GIT_DIR/GIT_WORK_TREE. It catches honest mistakes (cd into
    # another checkout and commit there); sh -c, scripts, aliases and
    # $(…) bodies get through. Never raises on odd input.
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
      # @return [Array<String, Symbol>] absolute dirs and :unknown, unique
      def self.for(command, cwd:, home: Dir.home)
        Walk.new(cwd, home).run(ShellLex.simple_commands(ShellLex.lex(command.to_s)))
      rescue ArgumentError, EncodingError
        [] # a NUL byte, invalid UTF-8: the shell would refuse it too
      end

      # Follows the current dir through the simple commands and records
      # where each mutating git runs.
      class Walk
        def initialize(cwd, home)
          @dir = cwd
          @home = home
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
          env = {}
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
          dir = @dir
          work_tree = env["GIT_WORK_TREE"] && expand(env["GIT_WORK_TREE"], dir)
          git_dir = env["GIT_DIR"] && expand(env["GIT_DIR"], dir)
          sub = nil
          until args.empty?
            arg = args.shift
            case arg
            when *VALUE_OPTIONS
              value = args.shift.to_s
              dir = expand(value, dir) if arg == "-C"
              git_dir = expand(value, dir) if arg == "--git-dir"
              work_tree = expand(value, dir) if arg == "--work-tree"
            when /\A--git-dir=(.*)\z/m then git_dir = expand(Regexp.last_match(1), dir)
            when /\A--work-tree=(.*)\z/m then work_tree = expand(Regexp.last_match(1), dir)
            when /\A-/ then next
            else
              sub = arg
              break
            end
          end
          return unless MUTATING.include?(sub)
          return if sub == "stash" && STASH_READS.include?(args.first)

          @found << (work_tree || repo_of(git_dir) || dir || :unknown)
        end

        def repo_of(git_dir)
          return nil unless git_dir

          File.basename(git_dir) == ".git" ? File.dirname(git_dir) : git_dir
        end

        # An absolute path for +arg+ against +dir+; nil when it can't be
        # told from the text (a variable, a substitution, a relative path
        # against an unknown dir).
        def expand(arg, dir)
          return nil if arg.include?(ShellLex::SUBST)

          arg = arg.sub(%r{\A(~|\$HOME|\$\{HOME\})(?=/|\z)}) { @home }
          return nil if arg.include?("$") || arg.start_with?("~")
          return File.expand_path(arg) if arg.start_with?("/")

          dir && File.expand_path(arg, dir)
        end
      end
    end
  end
end
