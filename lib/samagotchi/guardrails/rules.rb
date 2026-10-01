# frozen_string_literal: true

require_relative "verdict"
require_relative "targets"
require_relative "model_size"

module Samagotchi
  module Guardrails
    # Declarative rules from config.yml's `guardrails:` section (and, later,
    # installed bundles). All the fields a rule gives must match:
    #   tool:    a tool name, a list, or "shell" (execute + task_create);
    #            a name may be a glob ("mcp_*", "mcp_{git,gh}_*")
    #   command: a Ruby regex on a shell tool's command
    #   path:    "outside_repo", or a glob on the resolved paths (absolute
    #            or "**/…" globs match the absolute path; others the path
    #            relative to the repo root, the cwd outside one)
    #   models:  "small" (Guardrails::ModelSize, guardrails.small_models),
    #            or a glob on the bare model name or the model key, or a
    #            list of them: the rule only votes for a model that matches
    #            (no model matches none; missing = every model)
    # verdict ask|deny, reason, scopes (for an ask; default all).
    # `guardrails.disable` switches single rules off (#parse_disable).
    # A rule that doesn't parse raises ParseError: the Engine then denies
    # every call (a rule set that silently vanished is what this guards
    # against). Unknown keys are errors for the same reason (a typo).
    class Rules
      class ParseError < StandardError; end

      KEYS = %w[id tool command path models verdict reason scopes].freeze
      VERDICTS = %w[ask deny].freeze
      GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB

      Rule = Struct.new(:id, :tools, :command, :path, :models, :verdict, :reason, :scopes, :source, keyword_init: true) do
        def matches?(targets)
          return false unless targets
          return false if models && !models_match?(targets)
          return false if tools && !tool_matches?(targets.tool)
          return false if command && !(targets.command && command.match?(targets.command))
          return false if path && !path_matches?(targets)

          true
        end

        def tool_matches?(name)
          tools.any? { |tool| Rules.glob?(tool) ? File.fnmatch(tool, name.to_s, File::FNM_EXTGLOB) : tool == name }
        end

        # Whether the effective model is one of the rule's models:.
        def models_match?(targets)
          name = targets.model_name
          return false if name.nil? || name.empty?

          models.any? do |entry|
            if entry == "small"
              targets.small_model?
            else
              [name, targets.model_key].compact.any? { |c| File.fnmatch(entry, c, ModelSize::GLOB_FLAGS) }
            end
          end
        end

        def path_matches?(targets)
          return targets.outside_repo? if path == "outside_repo"

          base = targets.repo_root || targets.cwd
          glob = path.start_with?("~") ? File.expand_path(path) : path
          targets.paths.any? do |p|
            candidate = glob.start_with?("/", "**") ? p : relative(p, base)
            candidate && File.fnmatch(glob, candidate, GLOB_FLAGS)
          end
        end

        def relative(path, base)
          prefix = File.join(base, "")
          path.start_with?(prefix) ? path.delete_prefix(prefix) : nil
        end
      end

      # @param list [Array<Hash>, nil] the YAML rules
      # @param source [String] "config", "bundle <name>"
      # @return [Array<Rule>]
      def self.parse(list, source:)
        return [] if list.nil?
        raise ParseError, "rules must be a list" unless list.is_a?(Array)

        list.each_with_index.map { |raw, idx| parse_rule(raw, idx, source) }
      end

      def self.parse_rule(raw, idx, source)
        raise ParseError, "rule #{idx + 1} is not a mapping" unless raw.is_a?(Hash)

        raw = raw.transform_keys(&:to_s)
        id = raw["id"].to_s.strip
        label = id.empty? ? "rule #{idx + 1}" : "rule #{id}"
        unknown = raw.keys - KEYS
        raise ParseError, "#{label}: unknown key(s) #{unknown.join(", ")}" unless unknown.empty?
        raise ParseError, "#{label}: id is required" if id.empty?

        verdict = raw["verdict"].to_s
        raise ParseError, "#{label}: verdict must be ask or deny (got #{verdict.inspect})" unless VERDICTS.include?(verdict)
        unless %w[tool command path].any? { |k| raw.key?(k) }
          raise ParseError, "#{label}: give at least one of tool, command, path"
        end

        Rule.new(id: id, tools: tools_of(raw["tool"], label), command: regex_of(raw["command"], label),
                 path: path_of(raw["path"], label), models: models_of(raw["models"], label), verdict: verdict.to_sym,
                 reason: (raw["reason"] || "rule #{id}").to_s, scopes: scopes_of(raw["scopes"], label), source: source)
      end

      def self.tools_of(value, label)
        return nil if value.nil?

        names = Array(value).map(&:to_s)
        raise ParseError, "#{label}: tool must be a name or a list of names" if names.empty? || names.any?(&:empty?)

        names.flat_map { |n| n == "shell" ? Targets::SHELL_TOOLS : [n] }.uniq
      end

      # Whether a rule's tool name is a glob.
      def self.glob?(name) = name.match?(/[*?\[{]/)

      def self.regex_of(value, label)
        return nil if value.nil?

        Regexp.new(value.to_s)
      rescue RegexpError => e
        raise ParseError, "#{label}: command is not a valid regex: #{e.message}"
      end

      def self.path_of(value, label)
        return nil if value.nil?
        raise ParseError, "#{label}: path must be a string" unless value.is_a?(String) && !value.empty?

        value
      end

      def self.models_of(value, label)
        return nil if value.nil?

        names = Array(value)
        unless !names.empty? && names.all? { |n| n.is_a?(String) && !n.strip.empty? }
          raise ParseError, "#{label}: models must be small, a glob or a list of them"
        end

        names.map(&:strip)
      end

      def self.scopes_of(value, label)
        return nil if value.nil?

        scopes = Array(value).map(&:to_s)
        bad = scopes - Verdict::SCOPES
        raise ParseError, "#{label}: unknown scope(s) #{bad.join(", ")}" unless bad.empty?

        scopes
      end

      # config.yml's `guardrails.disable`: rule ids ("git-rebase", any
      # source) or "<bundle>:<id>" (that bundle's rule only).
      # @return [Array<String>]
      def self.parse_disable(value)
        return [] if value.nil?

        ids = Array(value)
        unless ids.all? { |id| id.is_a?(String) && !id.strip.empty? }
          raise ParseError, "disable must be a list of rule ids (id or bundle:id)"
        end

        ids.map(&:strip)
      end

      attr_reader :rules

      # @param rules [Array<Rule>] in order: config first, then bundles by name
      # @param enabled [Boolean] false: no rules, and hooks' asks are dropped
      # @param disable [Array<String>] from #parse_disable: rules that don't vote
      def initialize(rules = [], enabled: true, disable: [])
        @rules = rules
        @enabled = enabled
        @disable = disable
      end

      def enabled? = @enabled

      def disabled?(rule)
        @disable.any? { |entry| disables?(entry, rule) }
      end

      # The disable entries no loaded rule has (a typo, or an uninstalled bundle).
      def unmatched_disables
        @disable.reject { |entry| @rules.any? { |rule| disables?(entry, rule) } }
      end

      # A core check: every matching rule votes (strictest wins).
      def check(verdict)
        return verdict unless @enabled

        @rules.each do |rule|
          next if disabled?(rule)
          next unless rule.matches?(verdict.targets)

          if rule.verdict == :deny
            verdict.deny!(rule.reason, rule: rule.id, source: rule.source, decided_by: "rule")
          else
            verdict.ask!(rule.reason, scopes: rule.scopes, rule: rule.id, source: rule.source, decided_by: "rule")
          end
        end
        verdict
      end

      def disables?(entry, rule)
        bundle, id = entry.include?(":") ? entry.split(":", 2) : [nil, entry]
        id == rule.id && (bundle.nil? || rule.source == "bundle #{bundle}")
      end
      private :disables?

      # A core check that runs right after the hooks: with guardrails
      # disabled, a hook's ask is dropped (a deny still applies).
      def hook_asks
        rules = self
        Object.new.tap do |check|
          check.define_singleton_method(:check) do |verdict|
            verdict.drop_ask! if !rules.enabled? && verdict.ask? && verdict.decided_by == "hook"
            verdict
          end
        end
      end
    end
  end
end
