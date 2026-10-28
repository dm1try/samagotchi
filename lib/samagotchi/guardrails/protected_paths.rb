# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # Core checks on what the file tools (write, edit, memory_write) touch,
    # after the hooks and before the rules. Paths are compared with
    # symlinks resolved (on the longest existing parent, `..` taken
    # physically, a dangling symlink followed: .reals, the lexical answer
    # and where the write lands, a vote when either is protected).
    #   deny: the approval store's dir, installed bundles (.bundles/:
    #         hooks, rules, manifests) and attached context (a source's
    #         command runs later, outside the gate; chi context writes
    #         it); nothing legitimate writes there through the file tools.
    #   ask (once / session): config.yml and the plain hooks dir. The
    #         system bundle's config protocol edits config.yml with
    #         write/edit, so this keeps the user in the loop without
    #         breaking it.
    # execute can still write all of them (the guardrails bundle adds a
    # text match for that).
    class ProtectedPaths
      FILE_TOOLS = %w[write edit memory_write].freeze
      SOURCE = "core"

      # @param store_dir [String] <state dir>/guardrails
      # @param bundles_dir [String] <memories>/.bundles
      # @param config_path [String] config.yml
      # @param hooks_dir [String] the plain hooks dir
      # @param context_dir [String, nil] <state dir>/context (ContextSources.root)
      def initialize(store_dir:, bundles_dir:, config_path:, hooks_dir:, context_dir: nil)
        @deny = [
          ["guardrail-store", store_dir, "the approval store belongs to the user"],
          ["installed-bundles", bundles_dir, "installed bundles (hooks, rules, manifests) are changed by chi bundle install"],
          ["chi-context", context_dir, "attached context sources run commands; change them with chi context"]
        ]
        @ask = [
          ["chi-config", config_path, "changes chi's config.yml"],
          ["chi-hooks", hooks_dir, "changes chi's hooks"]
        ]
      end

      # Vote on +verdict+ (its targets).
      def check(verdict)
        targets = verdict.targets
        return verdict unless targets && FILE_TOOLS.include?(targets.tool)

        paths = targets.paths.flat_map { |p| self.class.reals(p) }
        @deny.each do |rule, root, reason|
          next unless paths.any? { |p| self.class.within?(p, root) }

          verdict.deny!(reason, rule: rule, source: SOURCE, decided_by: "core")
        end
        @ask.each do |rule, root, reason|
          next unless paths.any? { |p| self.class.within?(p, root) }

          verdict.ask!(reason, scopes: %w[once session], rule: rule, source: SOURCE, decided_by: "core")
        end
        verdict
      end

      # +path+ as an absolute path the way the kernel opens it: ~ expanded,
      # relative to +base+, and each `..` taken from where the dir before it
      # really is (a `..` after a symlinked dir climbs out of its target,
      # not back to the link's parent as File.expand_path has it). It
      # differs from File.expand_path only for such a climb; the parts
      # after the last `..` are kept as given (symlinks not resolved).
      # A shell's cd keeps the logical `..` (ShellPaths::Walk); a file
      # argument and a tool's path go through this.
      # @param path [String]
      # @param base [String, nil] for a relative path (Dir.pwd when nil)
      def self.expand(path, base = nil)
        path = path.to_s
        head, sep, tail = path.partition("/")
        path = "#{File.expand_path(head)}#{sep}#{tail}" if head.start_with?("~")
        path = File.join(File.expand_path(base || Dir.pwd), path) unless path.start_with?("/")
        parts = []
        path.split("/").each do |part|
          next if part.empty? || part == "."

          part == ".." ? parts = climb(parts) : parts << part
        end
        "/#{parts.join("/")}"
      end

      # The parts of +parts+'s parent dir: the lexical one unless the dir
      # is (or goes through) a symlink whose target's parent is elsewhere.
      def self.climb(parts)
        lexical = parts[0...-1]
        dir = "/#{parts.join("/")}"
        return lexical unless parts.any? && File.directory?(dir)

        physical = File.dirname(File.realpath(dir))
        return lexical if File.realpath("/#{lexical.join("/")}") == physical

        physical.split("/").reject(&:empty?)
      rescue SystemCallError
        lexical
      end
      private_class_method :climb

      # How many symlinks .real follows on a path that doesn't exist
      # (about the kernel's own ELOOP limit).
      MAX_LINKS = 40

      # +path+ (.expand) with symlinks resolved on its longest existing
      # parent: where the kernel lands for it. A part that is a dangling
      # symlink is followed to its target (a write there creates the
      # target), up to MAX_LINKS times; the missing tail is kept as given.
      def self.real(path)
        path = expand(path)
        MAX_LINKS.times do
          resolved = existing_prefix_real(path)
          return resolved unless resolved.is_a?(Array)

          path = resolved.first
        end
        path
      rescue SystemCallError
        path
      end

      # The old, lexical answer: File.expand_path (lexical `..`), then
      # realpath of the longest existing prefix, stopping at a dangling
      # symlink. .reals keeps it beside .real.
      def self.lexical_real(path)
        path = File.expand_path(path)
        rest = []
        current = path
        until File.exist?(current) || current == File.dirname(current)
          rest.unshift(File.basename(current))
          current = File.dirname(current)
        end
        File.join(File.realpath(current), *rest)
      rescue SystemCallError
        path
      end

      # Every place +path+ may be judged as: .lexical_real (what these
      # checks always looked at) and .real (where the kernel lands), one
      # entry when they agree. A check that holds for any of them (a
      # protected dir, a secret) or refuses unless all of them are inside
      # (the project, tmp) refuses at least what it did with the lexical
      # answer alone.
      # @return [Array<String>]
      def self.reals(path) = [lexical_real(path), real(path)].uniq

      # realpath of +path+'s longest existing prefix with the rest
      # appended (a String), or [the path with the first dangling symlink
      # on the way replaced by its target] to resolve again.
      def self.existing_prefix_real(path)
        rest = []
        current = path
        until File.exist?(current) || current == File.dirname(current)
          if File.symlink?(current)
            target = expand(File.readlink(current), File.dirname(current))
            return [expand(File.join(target, *rest))]
          end
          rest.unshift(File.basename(current))
          current = File.dirname(current)
        end
        File.join(File.realpath(current), *rest)
      end
      private_class_method :existing_prefix_real

      # Whether +path+ (resolved) is +root+ or in it, +root+ resolved
      # either way (.reals).
      def self.within?(path, root)
        return false if root.nil? || root.to_s.empty?

        reals(root.to_s.chomp("/")).any? { |dir| path == dir || path.start_with?(File.join(dir, "")) }
      end
    end
  end
end
