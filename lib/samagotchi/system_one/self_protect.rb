# frozen_string_literal: true

require_relative "../config"
require_relative "../memory_paths"
require_relative "../guardrails/protected_paths"
require_relative "../guardrails/parent_approvals"

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
      # chi's default state dir as a shell command may spell it when the
      # settings point elsewhere (the sessions and the guardrails store live
      # there).
      DEFAULT_STATE_TEXT = %r{\B~/\.local/state/samagotchi}
      # The characters that end a shell word: a memories path in a command
      # ends at the first one.
      WORD_END = %q{[\s'"`;&|<>(){}:,]}
      # A `..` segment anywhere in a command: with one, a memories path may
      # climb back out (`memories/../config.yml`, `cd memories && … ../x`),
      # so the command's memories text is not taken out.
      CLIMB = %r{(?:\A|[\s/'"=])\.\.(?:/|[\s'"]|\z)}

      module_function

      # @param approval [Hash, nil] the ask's approval facts (rule, tool,
      #   paths, command)
      # @return [Boolean] whether System 1 must not answer this ask
      def refuse?(approval)
        return false unless approval.is_a?(Hash)
        return true if NEVER_AUTO.include?(fetch(approval, :rule).to_s)
        # The test that makes an ask user_only (ParentApprovals#chi_files?:
        # chi's dirs, however a command spells them), minus the memories.
        return true if Guardrails::ParentApprovals.chi_files?(beyond_memories(approval))

        command = fetch(approval, :command).to_s
        command.match?(DEFAULT_STATE_TEXT)
      end

      # The approval's facts without what is in the memories dir (not its
      # installed bundles): the paths under it, and its spellings in the
      # command unless the command climbs with `..`.
      def beyond_memories(approval)
        memories = Guardrails::ProtectedPaths.real(MemoryPaths.system_dir)
        bundles = Guardrails::ProtectedPaths.real(MemoryPaths.bundles_dir)
        paths = Array(fetch(approval, :paths)).map(&:to_s).reject do |path|
          real = Guardrails::ProtectedPaths.real(path)
          Guardrails::ProtectedPaths.within?(real, memories) && !Guardrails::ProtectedPaths.within?(real, bundles)
        end
        command = fetch(approval, :command).to_s
        unless command.match?(CLIMB)
          command = command.gsub(memories_text) { |text| text.include?("/.bundles") ? text : "" }
        end
        { paths: paths, command: command }
      end

      # The memories dir as a command spells it: the default
      # `.config/samagotchi/memories`, or this process's own path, with the
      # rest of that shell word.
      def memories_text
        dir = ConfigFile.config_dir
        prefixes = [".config/samagotchi", dir, Guardrails::ProtectedPaths.real(dir)]
                   .map { |prefix| Regexp.escape(prefix.to_s.chomp("/")) }.uniq
        word = WORD_END.sub("[", "[^")
        Regexp.new("(?:#{prefixes.join("|")})/memories(?=/|#{WORD_END}|\\z)(?:/#{word}*)?")
      end

      def fetch(hash, key)
        hash.key?(key) ? hash[key] : hash[key.to_s]
      end
    end
  end
end
