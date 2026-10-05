# frozen_string_literal: true

require_relative "../config"
require_relative "../paths"
require_relative "../memory_paths"
require_relative "../hooks/loader"
require_relative "approval"
require_relative "verdict"
require_relative "protected_paths"
require_relative "parent_continue"

module Samagotchi
  module Guardrails
    # What a parent agent may allow on an approval (guardrails.parent_approvals,
    # config.yml only): off, a deny only; once, "Allow once" too, never a
    # wider scope. `chi answer` checks it before it posts; the worker checks
    # it again for an answer marked as chi answer's (CLIENT_ID), with its own
    # config. A convention for an honest but eager parent, not a security
    # boundary: any local process can post to the Bridge, with or without
    # the marker.
    #
    # An option allows when Approval.settle would allow it: its index is
    # below the approval's scopes. The scope is read by index, never by
    # label. When the scopes are missing or don't fit the options, it fails
    # closed: only a last option labelled Deny denies.
    #
    # Whatever the setting, an approval for a call on chi's own config dir
    # (config.yml, memories/.bundles' rules), the hooks dir or the approval
    # store is the user's alone (:protected): "Allow once" on a config.yml
    # rewrite would be "allow everything" from then on.
    module ParentApprovals
      KEY = "guardrails.parent_approvals"
      # The client id chi answer posts its answers with.
      CLIENT_ID = "cli:answer"
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
      # The guardrails bundle's shell-touches-chi, for a word it can't
      # resolve to a path (Guardrails::ShellPaths): CHI_TEXT and .git/hooks.
      CHI_SHELL_TEXT = Regexp.union(CHI_TEXT, %r{\.git/hooks})

      module_function

      # Whether an answer typed into this process is a parent agent's (so
      # this setting applies to it): stdin isn't a terminal (a pipe, a file,
      # /dev/null), or an agent marker is set. A person at chi --attach or
      # the REPL has a terminal and no marker.
      def parent_process?(env: ENV, stdin: $stdin)
        return true if AGENT_MARKERS.any? { |key| !env.fetch(key, "").to_s.strip.empty? }

        !(stdin.respond_to?(:tty?) && stdin.tty?)
      end

      # This process's setting: "once" or "off" (anything else is off).
      def setting
        Config.get(KEY).to_s == "once" ? "once" : "off"
      end

      # Why a parent may not give this answer, or nil.
      # @param pending [Hash] the pending question (symbol or string keys)
      # @param indices [Array<Integer, nil>] the selected options' places
      # @param setting [String, nil] "off" or "once"
      # @return [Symbol, nil] :protected (chi's own config: the user's
      #   alone), :off (no allow at all), :once_only, or nil
      def refusal(pending, indices, setting:)
        return nil unless approval?(pending)

        scopes = scopes(pending)
        allows = Array(indices).reject { |index| deny?(pending, scopes, index) }
        return nil if allows.empty?
        return :protected if protected?(pending)
        return :off unless setting.to_s == "once"
        return nil if scopes && allows.all? { |index| index.is_a?(Integer) && index >= 0 && scopes[index] == "once" }

        :once_only
      end

      # Whether +pending+ asks about a call on chi's own config, hooks,
      # guardrail rules or approvals: by its rule, its paths or its command
      # (the dirs as this process's environment and config.yml name them).
      def protected?(pending)
        facts = fetch(pending, :approval)
        return false unless facts.is_a?(Hash)
        return true if PROTECTED_RULES.include?(fetch(facts, :rule).to_s)
        return true if fetch(facts, :source).to_s == ProtectedPaths::SOURCE

        dirs = chi_dirs
        paths = Array(fetch(facts, :paths)).map(&:to_s).reject(&:empty?)
        return true if paths.any? { |path| dirs.any? { |dir| ProtectedPaths.within?(ProtectedPaths.real(path), dir) } }

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

      # The refusal as a line for the parent: deny, and tell the user.
      # Never how to allow it (the web, chi --attach): that is the user's.
      # @param reason [Symbol] what #refusal returned
      # @param typed [Boolean] the answer was typed at a ? prompt (the
      #   REPL), not given to chi answer
      def message(reason, typed: false)
        deny = typed ? "deny it (n; WHY), and tell your user" : "deny it (--option Deny --text WHY), and tell your user"
        case reason
        when :stop_only then ParentContinue.message
        when :protected then "this call changes chi's own config, hooks or guardrails, and only the user can allow it: #{deny}"
        when :off then "allowing a tool call is up to the user: #{deny}"
        else "only Allow once (#{KEY}: once) can be given here: #{deny}"
        end
      end

      # An approval: its kind says so, or it carries approval facts.
      def approval?(pending)
        fetch(pending, :kind).to_s == Approval::KIND || !fetch(pending, :approval).nil?
      end

      # The offered scopes, in option order, or nil when they are missing,
      # empty, not strings, or leave no option after them for Deny.
      def scopes(pending)
        facts = fetch(pending, :approval)
        scopes = facts.is_a?(Hash) ? fetch(facts, :scopes) : nil
        return nil unless scopes.is_a?(Array) && !scopes.empty? && scopes.all?(String)
        return nil unless scopes.size < options(pending).size

        scopes
      end

      def deny?(pending, scopes, index)
        return false unless index.is_a?(Integer) && index >= 0

        options = options(pending)
        return index >= scopes.size && index < options.size if scopes

        index == options.size - 1 && options[index].to_s == Approval::DENY
      end

      def options(pending) = Array(fetch(pending, :options))

      def fetch(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end
    end
  end
end
