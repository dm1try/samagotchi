# frozen_string_literal: true

require_relative "shell_lex"
require_relative "shell_git_dirs"

module Samagotchi
  module Guardrails
    # Whether a shell command runs git that changes what every checkout of
    # the repository shares (its common git dir), wherever it runs: from a
    # worktree these reach the main checkout and the siblings too.
    #   config     a write without --worktree (or --file/--blob, whose
    #              path the caller checks); --get, --list, `config get`
    #              and a lone key only read
    #   update-ref always
    #   worktree   add, remove, move, prune, lock, unlock, repair
    #   stash      drop, clear, pop (one stash list for all)
    #   tag        creating or deleting one (not listing or verifying)
    #   branch     delete, force or a forced move/copy, of a branch other
    #              than +own_branch+ (any, when that is unknown)
    # Pure text, as ShellGitDirs: sh -c, aliases and $(…) get through.
    module SharedGit
      WORKTREE_CHANGES = %w[add remove move prune lock unlock repair].freeze
      STASH_CHANGES = %w[drop clear pop].freeze
      CONFIG_READS = %w[--get --get-all --get-regexp --get-urlmatch --list -l --get-color --get-colorbool].freeze
      CONFIG_WRITES = %w[--unset --unset-all --add --replace-all --rename-section --remove-section -e --edit].freeze
      CONFIG_OWN_FILE = %w[--worktree -f --file --blob].freeze
      # config options that take the next word as their value.
      CONFIG_VALUES = %w[--type --default --comment -f --file --blob].freeze
      TAG_READS = %w[-l --list -n -v --verify --contains --no-contains --points-at --merged --no-merged].freeze
      TAG_WRITES = %w[-d --delete -f --force -a --annotate -s --sign -u -m -F].freeze
      BRANCH_DELETE = %w[-d -D --delete].freeze
      BRANCH_MOVE = %w[-m --move -c --copy].freeze
      BRANCH_FORCED_MOVE = %w[-M -C].freeze

      module_function

      # @param command [String]
      # @param own_branch [String, nil] the branch checked out where the
      #   session works
      def changes?(command, own_branch: nil)
        ShellLex.simple_commands(ShellLex.lex(command.to_s)).any? do |words|
          next false unless words.is_a?(Array)

          sub, args = git_call(words)
          sub && changes_shared?(sub, args, own_branch)
        end
      rescue ArgumentError, EncodingError
        false
      end

      # [subcommand, its args] of a git simple command, or nil.
      def git_call(words)
        words = words.drop_while { |w| w.match?(/\A[A-Za-z_]\w*=/) || ShellGitDirs::PREFIXES.include?(w) }
        verb = words.first
        return nil unless verb == "git" || verb.to_s.end_with?("/git")

        args = words.drop(1).grep_v(ShellLex::REDIRECT)
        until args.empty?
          arg = args.shift
          if ShellGitDirs::VALUE_OPTIONS.include?(arg) then args.shift
          elsif !arg.start_with?("-") then return [arg, args]
          end
        end
        nil
      end

      def changes_shared?(sub, args, own_branch)
        case sub
        when "config" then config_writes?(args)
        when "update-ref" then true
        when "worktree" then WORKTREE_CHANGES.include?(args.first)
        when "stash" then STASH_CHANGES.include?(args.first)
        when "tag" then tag_changes?(args)
        when "branch" then branch_changes?(args, own_branch)
        else false
        end
      end

      def config_writes?(args)
        return false if args.any? { |a| CONFIG_OWN_FILE.include?(a) || a.start_with?("--file=", "--blob=") }
        return false if %w[get list].include?(args.first)
        return true if %w[set unset rename-section remove-section edit].include?(args.first)
        return false if args.any? { |a| CONFIG_READS.include?(a) }
        return true if args.any? { |a| CONFIG_WRITES.include?(a) }

        operands(args, CONFIG_VALUES).size >= 2
      end

      def tag_changes?(args)
        return true if args.any? { |a| TAG_WRITES.include?(a) }
        return false if args.empty? || args.any? { |a| TAG_READS.include?(a) || a.start_with?("--list=", "--contains=", "--points-at=") }

        !operands(args, []).empty?
      end

      # The branches a branch command deletes or overwrites (a plain -m/-c
      # only moves its source; its new name doesn't exist yet).
      def branch_changes?(args, own_branch)
        names = operands(args, %w[-u --set-upstream-to -t --track])
        targets = if args.any? { |a| BRANCH_DELETE.include?(a) } then names
                  elsif args.any? { |a| BRANCH_FORCED_MOVE.include?(a) } then names.size >= 2 ? names : [own_branch, *names]
                  elsif args.any? { |a| BRANCH_MOVE.include?(a) } then names.size >= 2 ? [names.first] : []
                  elsif args.any? { |a| %w[-f --force].include?(a) } then names.first(1)
                  else []
                  end
        targets.any? { |name| own_branch.nil? || name != own_branch }
      end

      def operands(args, value_options)
        rest = args.dup
        found = []
        until rest.empty?
          arg = rest.shift
          if value_options.include?(arg) then rest.shift
          elsif arg == "--" then found.concat(rest)
                                 break
          elsif !arg.start_with?("-") then found << arg
          end
        end
        found
      end
    end
  end
end
