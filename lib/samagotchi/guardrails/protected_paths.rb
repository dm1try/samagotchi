# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # Core checks on what the file tools (write, edit, memory_write) touch,
    # after the hooks and before the rules. Paths are compared with
    # symlinks resolved (on the longest existing parent).
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

        paths = targets.paths.map { |p| self.class.real(p) }
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

      # +path+ with symlinks resolved on its longest existing parent.
      def self.real(path)
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

      def self.within?(path, root)
        return false if root.nil? || root.to_s.empty?

        root = real(root.to_s.chomp("/"))
        path == root || path.start_with?(File.join(root, ""))
      end
    end
  end
end
