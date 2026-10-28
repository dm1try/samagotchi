# frozen_string_literal: true

require_relative "../config"
require_relative "../paths"
require_relative "../memory_paths"
require_relative "../hooks/loader"
require_relative "approval"
require_relative "verdict"
require_relative "protected_paths"

module Samagotchi
  module Guardrails
    # The facts a parent agent's answer is judged by (ParentPolicy): who
    # answers as a parent (#parent_process?), what an approval is
    # (#approval?, its #scopes) and which approvals are the user's alone
    # (#protected?): a call on chi's own config dir (config.yml,
    # memories/.bundles' rules), the hooks dir or the approval store, since
    # "Allow once" on a config.yml rewrite would be "allow everything" from
    # then on. Also chi's dirs and text for the guardrails' own rules
    # (Targets, the shell rules).
    module ParentApprovals
      # Set by chi's execute and task_create for the commands they run: a
      # chi started there answers as a parent (#parent_process?).
      PARENT_SESSION_ENV = "SAMAGOTCHI_PARENT_SESSION"
      # Environment variables that say an agent runs this process: Claude
      # Code's, the AI_AGENT convention, Codex CLI's (CODEX_THREAD_ID, which
      # Codex sets on every command its shell tool runs), and chi's own.
      # They survive a PTY wrapper (script, expect). The docs list them too
      # (guardrails.md, sub-agent.md).
      AGENT_MARKERS = ["CLAUDECODE", "AI_AGENT", "CODEX_THREAD_ID", PARENT_SESSION_ENV].freeze
      # Rules only the user may allow (Verdict::PROTECTED_RULES).
      PROTECTED_RULES = Verdict::PROTECTED_RULES
      # A shell command naming chi's config, hooks, guardrails or attached
      # context as text (broad: a parent may not allow what only looks like
      # one). samagotchi/context stops before a word character or a dot, so
      # chi's own lib/samagotchi/context_*.rb isn't one.
      CHI_TEXT = %r{\.config/samagotchi|samagotchi/config\.yml|samagotchi/hooks|samagotchi/guardrails|samagotchi/context(?![\w.])|memories/\.bundles}
      # The guardrails bundle's ask before a memory removal: its paths are in
      # the config dir, yet a parent may answer it.
      MEMORY_REMOVE_RULE = "memory-remove"
      # The guardrails bundle's shell-touches-chi, for a word it can't
      # resolve to a path (Guardrails::ShellPaths): CHI_TEXT and .git/hooks.
      CHI_SHELL_TEXT = Regexp.union(CHI_TEXT, %r{\.git/hooks})

      module_function

      # Whether an answer typed into this process is a parent agent's (so
      # ParentPolicy applies to it): stdin isn't a terminal (a pipe, a file,
      # /dev/null), or an agent marker is set. A person at chi --attach or
      # the REPL has a terminal and no marker.
      def parent_process?(env: ENV, stdin: $stdin)
        return true if AGENT_MARKERS.any? { |key| !env.fetch(key, "").to_s.strip.empty? }

        !(stdin.respond_to?(:tty?) && stdin.tty?)
      end

      # Whether +pending+ asks about a call on chi's own config, hooks,
      # guardrail rules or approvals: by its rule, its paths or its command
      # (the dirs as this process's environment and config.yml name them).
      def protected?(pending) = protected_facts?(pending.approval)

      # #protected? on an approval's facts (Approval.payload's approval:),
      # at ask time.
      def protected_facts?(facts)
        return false unless facts.is_a?(Hash)
        return true if PROTECTED_RULES.include?(fetch(facts, :rule).to_s)
        return true if fetch(facts, :source).to_s == ProtectedPaths::SOURCE
        # A memory's file sits in the config dir, but removing one is the
        # memory-remove rule's ask, which a parent may answer.
        return false if fetch(facts, :rule).to_s == MEMORY_REMOVE_RULE

        chi_files?(facts)
      end

      # Whether an approval's paths or command name chi's own dirs (#chi_dirs)
      # or CHI_TEXT, whatever its rule: the part of #protected_facts? that
      # System 1's SystemOne::SelfProtect shares.
      def chi_files?(facts)
        return false unless facts.is_a?(Hash)

        dirs = chi_dirs
        paths = Array(fetch(facts, :paths)).map(&:to_s).reject(&:empty?)
        reals = paths.flat_map { |path| ProtectedPaths.reals(path) }
        return true if reals.any? { |real| dirs.any? { |dir| ProtectedPaths.within?(real, dir) } }

        command = fetch(facts, :command).to_s
        return false if command.empty?

        command.match?(CHI_TEXT) || dirs.any? { |dir| command.include?(dir) || command.include?(ProtectedPaths.real(dir)) }
      end

      # chi's config dir, the hooks dir, the approval store's dir and the
      # installed bundles' dir.
      def chi_dirs
        hooks = begin Hooks::Loader.hooks_dir rescue nil end
        bundles = begin MemoryPaths.bundles_dir rescue nil end
        [ConfigFile.config_dir, hooks, File.join(Paths.state_dir, "guardrails"), bundles, File.join(Paths.state_dir, "context")]
          .compact.map { |dir| dir.to_s.chomp("/") }.reject(&:empty?).uniq
      end

      # An approval: its kind says so, or it carries approval facts.
      def approval?(pending)
        pending.kind.to_s == Approval::KIND || !pending.approval.nil?
      end

      # The offered scopes, in option order, or nil when they are missing,
      # empty, not strings, or leave no option after them for Deny.
      def scopes(pending)
        facts = pending.approval
        scopes = facts.is_a?(Hash) ? fetch(facts, :scopes) : nil
        return nil unless scopes.is_a?(Array) && !scopes.empty? && scopes.all?(String)
        return nil unless scopes.size < options(pending).size

        scopes
      end

      def options(pending) = Array(pending.options)

      def fetch(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end
    end
  end
end
