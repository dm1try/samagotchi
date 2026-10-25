# frozen_string_literal: true

require_relative "../paths"
require_relative "../config"
require_relative "../memory_paths"
require_relative "../hooks/loader"
require_relative "../guardrails/protected_paths"

module Samagotchi
  module SystemOne
    # The calls System 1 may never answer for, whatever the rule's record
    # says: one that changes chi itself. An auto-allow on config.yml, the
    # hooks, the installed bundles or the guardrails store would let the
    # agent widen its own guardrails without the user (docs/guardrails.md,
    # "System 1"). The memories dir is deliberately not one of them:
    # reading and appending a memory file stays eligible.
    #
    # Pure: it only reads the paths as this process's environment names them,
    # and answers on the approval's own facts (Guardrails::Approval.payload's
    # approval:), the same shape ParentApprovals.protected_facts? takes.
    module SelfProtect
      # The rules that let one agent answer chi's questions: an auto-allow
      # there is one agent approving another's, so the user decides them even
      # when they are listed in `guardrails.system_one.rules`.
      NEVER_AUTO = %w[chi-answer-piped chi-answer-http chi-broadcast].freeze
      # chi's config file, however the user names it in config.yml.
      CONFIG_FILE = /\Aconfig[\w-]*\.ya?ml\z/i
      # The dirs as a shell command may spell them when the settings point
      # elsewhere: chi's default config dir and default state dir. A path
      # into the memories dir is not a control file.
      DEFAULT_CONFIG_TEXT = %r{\B~/\.config/samagotchi(?!/memories)}
      DEFAULT_STATE_TEXT = %r{\B~/\.local/state/samagotchi}

      module_function

      # @param approval [Hash, nil] the ask's approval facts (rule, tool,
      #   paths, command)
      # @return [Boolean] whether System 1 must not answer this ask
      def refuse?(approval)
        return false unless approval.is_a?(Hash)
        return true if NEVER_AUTO.include?(fetch(approval, :rule).to_s)

        dirs = control_dirs
        paths = Array(fetch(approval, :paths)).map(&:to_s).reject(&:empty?)
        return true if paths.any? { |path| control_path?(path, dirs) }

        command = fetch(approval, :command).to_s
        !command.empty? && control_text?(command, dirs)
      end

      # The dirs whose files are chi's own: its hooks, its installed bundles,
      # the guardrails store (approvals.json and judgments.jsonl).
      # @return [Array<String>]
      def control_dirs
        [Hooks::Loader.hooks_dir, MemoryPaths.bundles_dir, File.join(Paths.state_dir, "guardrails")]
          .compact.map { |dir| dir.to_s.chomp("/") }.reject(&:empty?)
      end

      def control_path?(path, dirs)
        real = Guardrails::ProtectedPaths.real(path)
        return true if dirs.any? { |dir| Guardrails::ProtectedPaths.within?(real, dir) }
        return true if config_file?(real)

        control_text?(path, dirs)
      end

      # config.yml in chi's config dir — not the memories beside it.
      def config_file?(path)
        Guardrails::ProtectedPaths.within?(path, ConfigFile.config_dir) && File.basename(path).match?(CONFIG_FILE)
      end

      # A command or path naming one of those dirs, in the spelling this
      # process uses or the default `~/.config/samagotchi` one.
      def control_text?(text, dirs)
        dirs.any? { |dir| text.include?(dir) || text.include?(File.expand_path(dir)) } ||
          text.match?(config_text) || text.match?(DEFAULT_CONFIG_TEXT) || text.match?(DEFAULT_STATE_TEXT)
      end

      # chi's config dir as text — everything under it except the memories,
      # which the model works with.
      def config_text
        Regexp.new("#{Regexp.escape(ConfigFile.config_dir)}(?![/]memories)")
      end

      def fetch(hash, key)
        hash.key?(key) ? hash[key] : hash[key.to_s]
      end
    end
  end
end
