# frozen_string_literal: true

require_relative "outside"
require_relative "protected_paths"
require_relative "shell_lex"
require_relative "shell_paths"
require_relative "shared_git"

module Samagotchi
  module Guardrails
    # A delegate child asks before it changes anything outside its folder
    # (+root+: the work tree top of its working_directory, never Dir.pwd,
    # so a child whose worktree is gone still has one). A core check, on in
    # every guardrails mode and with guardrails.enabled: false, for delegate
    # sessions only (GuardrailWiring#checks), so ordinary sessions and a
    # parent's own flows never get it. It asks, once or for the session
    # (a repo or rule answer would hold in every worktree, for every child),
    # when:
    #   write, edit: a path is outside root (Outside: tmp dirs and memory
    #     files never are);
    #   execute, task_create: mutating git runs in a dir outside root
    #     (ShellGitDirs), or a command that isn't read-only starts outside
    #     root (its cwd:, else Dir.pwd) or names a path in the repository's
    #     other checkouts (the main one and sibling worktrees) or its
    #     common git dir; or it runs git that changes what all checkouts
    #     share, from anywhere (SharedGit: config, update-ref, worktree add,
    #     stash clear, tags, another branch's delete).
    # Paths elsewhere in a command (/usr/bin, ~/.gem) don't count, and
    # read-only commands never ask. Text heuristics: sh -c bodies, scripts
    # and $(…) aren't looked into.
    class ChildBoundary
      RULE = "child-boundary"
      SOURCE = "core"
      SCOPES = %w[once session].freeze
      SHELL_TOOLS = %w[execute task_create].freeze

      # @param root [#call] → String, nil: the child's folder (nil: no check)
      # @param worktrees [#call] → Array<String>: every checkout of root's
      #   repository (GitInfo#worktrees); root's own is left out here
      # @param common_dir [#call] → String, nil: root's common git dir (in
      #   a bare layout it is in no checkout)
      # @param branch [#call] → String, nil: the branch checked out in root
      def initialize(root:, worktrees: -> { [] }, common_dir: -> {}, branch: -> {})
        @root = root
        @worktrees = worktrees
        @common_dir = common_dir
        @branch = branch
      end

      # Vote on +verdict+ (its targets).
      def check(verdict)
        targets = verdict.targets
        root = targets && @root.call
        return verdict unless root && !root.to_s.empty?

        crossing = crosses?(targets, root) or return verdict

        what = crossing == :shared ? "git state every checkout of the repository shares, from its folder" : "something outside its folder"
        verdict.ask!("a delegate child changes #{what} #{root}: ask the user",
                     scopes: SCOPES, rule: RULE, source: SOURCE, decided_by: "core")
      end

      private

      def crosses?(targets, root)
        case targets.tool
        when "write", "edit" then targets.paths.any? { |path| Outside.outside?(path, root: root) }
        when *SHELL_TOOLS then shell_crosses?(targets, root)
        else false
        end
      end

      def shell_crosses?(targets, root)
        return true if targets.git_dirs.any? { |dir| dir.is_a?(String) && Outside.outside?(dir, root: root) }
        return :shared if SharedGit.changes?(targets.command, own_branch: @branch.call)
        return false if targets.read_only?
        return true if targets.cwd && Outside.outside?(targets.cwd, root: root)

        names_other_checkout?(targets.command, targets.cwd, root)
      end

      # Whether a word of +command+ resolves into another checkout of the
      # repository (and not into root, which may sit inside the main one).
      def names_other_checkout?(command, cwd, root)
        real_root = ProtectedPaths.real(root)
        others = [*@worktrees.call, @common_dir.call].compact.map { |dir| ProtectedPaths.real(dir) } - [real_root]
        return false if others.empty?

        walk = ShellPaths::Walk.new(cwd, Dir.home, ENV)
        ShellLex.simple_commands(ShellLex.lex(command.to_s)).any? do |words|
          walk.step(words).any? do |_word, path|
            next false unless path

            real = ProtectedPaths.real(path)
            !ShellPaths.within?(real, real_root) && others.any? { |dir| ShellPaths.within?(real, dir) }
          end
        end
      rescue ArgumentError, EncodingError
        false
      end
    end
  end
end
