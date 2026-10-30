# frozen_string_literal: true

require_relative "path_resolve"

module Samagotchi
  module Guardrails
    # Core checks on what the file tools (write, edit, memory_write) touch,
    # after the hooks and before the rules. Paths are compared with
    # symlinks resolved (on the longest existing parent, `..` taken
    # physically, a dangling symlink followed: PathResolve.reals, the
    # lexical answer and where the write lands, a vote when either is
    # protected).
    #   deny: the approval store's dir, installed bundles (.bundles/:
    #         hooks, rules, manifests) and attached context (a source's
    #         command runs later, outside the gate; chi context writes
    #         it); nothing legitimate writes there through the file tools.
    #   ask (once / session): config.yml, home.json (the chi home: the
    #         Ruby every chi launch boots), the chi shim (ChiShim: the
    #         `chi` every tool runs) and the plain hooks dir. The
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
      # @param home_path [String, nil] home.json (ChiHome.path)
      # @param shim_path [String, nil] the chi shim (ChiShim.path)
      def initialize(store_dir:, bundles_dir:, config_path:, hooks_dir:, context_dir: nil, home_path: nil, shim_path: nil)
        @deny = [
          ["guardrail-store", store_dir, "the approval store belongs to the user"],
          ["installed-bundles", bundles_dir, "installed bundles (hooks, rules, manifests) are changed by chi bundle install"],
          ["chi-context", context_dir, "attached context sources run commands; change them with chi context"]
        ]
        @ask = [
          ["chi-config", config_path, "changes chi's config.yml"],
          ["chi-home", home_path, "changes the Ruby every chi launch boots"],
          ["chi-shim", shim_path, "changes the chi every tool's chi runs"],
          ["chi-hooks", hooks_dir, "changes chi's hooks"]
        ].select { |_, root, _| root }
      end

      # Vote on +verdict+ (its targets).
      def check(verdict)
        targets = verdict.targets
        return verdict unless targets && FILE_TOOLS.include?(targets.tool)

        paths = targets.paths.flat_map { |p| PathResolve.reals(p) }
        @deny.each do |rule, root, reason|
          next unless paths.any? { |p| PathResolve.within?(p, root) }

          verdict.deny!(reason, rule: rule, source: SOURCE, decided_by: "core")
        end
        @ask.each do |rule, root, reason|
          next unless paths.any? { |p| PathResolve.within?(p, root) }

          verdict.ask!(reason, scopes: %w[once session], rule: rule, source: SOURCE, decided_by: "core")
        end
        verdict
      end

      # The path primitives (PathResolve) as this class has long named
      # them; specs and older callers reach them here.
      def self.expand(path, base = nil) = PathResolve.expand(path, base)
      def self.real(path) = PathResolve.real(path)
      def self.lexical_real(path) = PathResolve.lexical_real(path)
      def self.reals(path) = PathResolve.reals(path)
      def self.within?(path, root) = PathResolve.within?(path, root)
      def self.under?(path, dir) = PathResolve.under?(path, dir)
      def self.folds_case?(path) = PathResolve.folds_case?(path)
    end
  end
end
