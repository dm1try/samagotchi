# frozen_string_literal: true

require_relative "verdict"
require_relative "targets"

module Samagotchi
  module Guardrails
    # Declarative rules from config.yml's `guardrails:` section (and, later,
    # installed bundles). All the fields a rule gives must match:
    #   tool:    a tool name, a list, or "shell" (execute + task_create)
    #   command: a Ruby regex on a shell tool's command
    #   path:    "outside_repo", or a glob on the resolved paths (absolute
    #            or "**/…" globs match the absolute path; others the path
    #            relative to the repo root, the cwd outside one)
    # verdict ask|deny, reason, scopes (for an ask; default all).
    # A rule that doesn't parse raises ParseError: the Engine then denies
    # every call (a rule set that silently vanished is what this guards
    # against). Unknown keys are errors for the same reason (a typo).
    class Rules
      class ParseError < StandardError; end

      KEYS = %w[id tool command path verdict reason scopes].freeze
      VERDICTS = %w[ask deny].freeze
      GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB

      Rule = Struct.new(:id, :tools, :command, :path, :verdict, :reason, :scopes, :source, keyword_init: true) do
        def matches?(targets)
          return false unless targets
          return false if tools && !tools.include?(targets.tool)
          return false if command && !(targets.command && command.match?(targets.command))
          return false if path && !path_matches?(targets)

          true
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
                 path: path_of(raw["path"], label), verdict: verdict.to_sym,
                 reason: (raw["reason"] || "rule #{id}").to_s, scopes: scopes_of(raw["scopes"], label), source: source)
      end

      def self.tools_of(value, label)
        return nil if value.nil?

        names = Array(value).map(&:to_s)
        raise ParseError, "#{label}: tool must be a name or a list of names" if names.empty? || names.any?(&:empty?)

        names.flat_map { |n| n == "shell" ? Targets::SHELL_TOOLS : [n] }.uniq
      end

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

      def self.scopes_of(value, label)
        return nil if value.nil?

        scopes = Array(value).map(&:to_s)
        bad = scopes - Verdict::SCOPES
        raise ParseError, "#{label}: unknown scope(s) #{bad.join(", ")}" unless bad.empty?

        scopes
      end

      attr_reader :rules

      # @param rules [Array<Rule>] in order: config first, then bundles by name
      # @param enabled [Boolean] false: no rules, and hooks' asks are dropped
      def initialize(rules = [], enabled: true)
        @rules = rules
        @enabled = enabled
      end

      def enabled? = @enabled

      # A core check: every matching rule votes (strictest wins).
      def check(verdict)
        return verdict unless @enabled

        @rules.each do |rule|
          next unless rule.matches?(verdict.targets)

          if rule.verdict == :deny
            verdict.deny!(rule.reason, rule: rule.id, source: rule.source, decided_by: "rule")
          else
            verdict.ask!(rule.reason, scopes: rule.scopes, rule: rule.id, source: rule.source, decided_by: "rule")
          end
        end
        verdict
      end

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
