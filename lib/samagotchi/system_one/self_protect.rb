# frozen_string_literal: true

require_relative "../config"
require_relative "../memory_paths"
require_relative "../paths"
require_relative "../guardrails/protected_paths"
require_relative "../guardrails/parent_approvals"
require_relative "../guardrails/shell_lex"
require_relative "../guardrails/shell_paths"

module Samagotchi
  module SystemOne
    # The calls System 1 may never answer for, whatever the rule's record
    # says: one that changes chi itself. An auto-allow on config.yml, the
    # hooks, the installed bundles or the guardrails store would let the
    # agent widen its own guardrails without the user (docs/guardrails.md,
    # "System 1"). The memories dir is deliberately not one of them:
    # reading and appending a memory file stays eligible.
    #
    # A file tool's paths and a shell command's words are judged against
    # the same dirs (.chi_dirs: chi's whole state dir among them). The
    # words are resolved as Guardrails::ShellPaths resolves them (cd
    # chains, ~, $HOME and the XDG dirs, symlinks, `..` both ways), under
    # chi's env and the call's env: when the caller hands its Targets; one
    # landing in chi's dirs outside the memories refuses.
    # The memories text is taken out of the command (the exemption) only
    # when its text shows no climb (CLIMB: a `..`, a `$`, backticks, a `~`
    # other than the home one, `cd -`) and every word either resolved or is
    # data (Words#plain: a script or heredoc body, a phrase, a glob with no
    # `/`) read while the dir was known. A word the walk can't follow
    # otherwise (`${PWD%/*}`, `$(dirname $PWD)`, `cd -`) may climb out of the
    # memories dir without saying so, so its memories text stays in and the
    # text check refuses it.
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

      # A climb out of a dir as a command's text may spell it: a `..`
      # segment (`cd ..;`, `../x`, inside a script body too), any `$`
      # expansion or backticks, a `~` that isn't the home one (`~-`, `~+`,
      # `~user`), or `cd -` / `pushd -`.
      CLIMB = Regexp.union(
        /(?<![\w.])\.\.(?![\w.])/, /[$`]/, %r{(?:\A|[\s=:'"(])~(?![/\s'";&|)]|\z)},
        /(?:\A|[\s;&|(])(?:cd|pushd)\s+-(?=[\s;&|)]|\z)/
      )

      # What resolving a command's words found: whether one lands in chi's
      # dirs (outside the memories dir, or in its installed bundles), and
      # whether every word resolved or is data (#plain).
      Words = Data.define(:chi, :plain)

      module_function

      # @param approval [Hash, nil] the ask's approval facts (rule, tool,
      #   paths, command, cwd)
      # @param targets [Guardrails::Targets, nil] the call's targets, for its
      #   env: (Targets#shell_envs, #redefines_shell?)
      # @return [Boolean] whether System 1 must not answer this ask
      def refuse?(approval, targets: nil)
        return false unless approval.is_a?(Hash)
        return true if NEVER_AUTO.include?(fetch(approval, :rule).to_s)
        # An env: that redefines the shell (BASH_ENV, BASH_FUNC_…) runs what
        # no word of the command says.
        return true if targets&.redefines_shell?

        command = fetch(approval, :command).to_s
        words = command.empty? ? nil : words(command, cwd: fetch(approval, :cwd), targets: targets)
        return true if words&.chi
        return true if chi_paths?(approval)
        # The test that makes an ask user_only (ParentApprovals#chi_files?:
        # chi's dirs as the command spells them), minus the memories.
        return true if Guardrails::ParentApprovals.chi_files?(beyond_memories(approval, exempt: exempt?(command, words)))

        command.match?(DEFAULT_STATE_TEXT)
      end

      # Whether a path of the approval lands in chi's dirs (#chi_dirs: its
      # whole state dir too, as a command's words are judged) outside the
      # memories dir, or in its installed bundles.
      def chi_paths?(approval)
        memories = Guardrails::ProtectedPaths.real(MemoryPaths.system_dir)
        bundles = Guardrails::ProtectedPaths.real(MemoryPaths.bundles_dir)
        dirs = chi_dirs
        Array(fetch(approval, :paths)).map(&:to_s).reject(&:empty?).any? do |path|
          Guardrails::ProtectedPaths.reals(path).any? do |real|
            dirs.any? { |dir| Guardrails::ProtectedPaths.within?(real, dir) } && !memory?(real, memories, bundles)
          end
        end
      end

      # The approval's facts without what is in the memories dir (not its
      # installed bundles): the paths under it, and its spellings in the
      # command when +exempt+ (.exempt?).
      def beyond_memories(approval, exempt:)
        memories = Guardrails::ProtectedPaths.real(MemoryPaths.system_dir)
        bundles = Guardrails::ProtectedPaths.real(MemoryPaths.bundles_dir)
        paths = Array(fetch(approval, :paths)).map(&:to_s).reject do |path|
          Guardrails::ProtectedPaths.reals(path).all? { |real| memory?(real, memories, bundles) }
        end
        command = fetch(approval, :command).to_s
        command = command.gsub(memories_text) { |text| text.include?("/.bundles") ? text : "" } if exempt
        { paths: paths, command: command }
      end

      # Whether the command's memories text may be taken out: no command,
      # or one whose text shows no climb (CLIMB) and whose words are plain.
      def exempt?(command, words)
        words.nil? || (words.plain && !command.match?(CLIMB))
      end

      # The command's words resolved (ShellPaths::Walk) from +cwd+ (else
      # this process's dir) under each of the call's shell envs: Words.
      def words(command, cwd:, targets:)
        memories = Guardrails::ProtectedPaths.real(MemoryPaths.system_dir)
        bundles = Guardrails::ProtectedPaths.real(MemoryPaths.bundles_dir)
        dirs = chi_dirs
        tokens = Guardrails::ShellLex.lex(command)
        plain = !Guardrails::ShellLex.unterminated?(command) &&
                tokens.none? { |_, value| value.include?(Guardrails::ShellLex::SUBST) }
        chi = false
        commands = Guardrails::ShellLex.simple_commands(tokens)
        envs = targets ? targets.shell_envs : [[Dir.home, ENV]]
        envs.each do |home, env|
          walk = Guardrails::ShellPaths::Walk.new(cwd.to_s.empty? ? Dir.pwd : cwd.to_s, home, env)
          commands.each do |simple|
            # A cd the walk couldn't follow: no later word is data.
            known = !simple.is_a?(Array) || !walk.paths(".").empty?
            walk.step(simple).each do |word, path|
              next plain &&= known && data?(word) unless path

              chi ||= Guardrails::ProtectedPaths.reals(path).any? do |real|
                dirs.any? { |dir| Guardrails::ShellPaths.within?(real, dir) } && !memory?(real, memories, bundles)
              end
            end
          end
        end
        Words.new(chi: chi, plain: plain)
      rescue ArgumentError, EncodingError
        Words.new(chi: false, plain: false)
      end

      # Whether a word the walk couldn't resolve is data rather than a path
      # spelt some other way: a heredoc body, a script or a phrase (spaces,
      # quotes, operators: `python3 -c '…'`, `'- a note'`), or a glob with
      # no `/`. A `$` or `~` left in it is not (CLIMB refuses those anyway).
      def data?(word)
        return true if word == Guardrails::ShellLex::HEREDOC
        return false if word.include?("$") || word.include?("~")
        return true if word.match?(Guardrails::ShellPaths::SCRIPT)

        word.match?(Guardrails::ShellPaths::GLOB) && !word.include?("/")
      end

      # chi's own dirs (ParentApprovals.chi_dirs) and its whole state dir
      # (DEFAULT_STATE_TEXT's), resolved.
      def chi_dirs
        [*Guardrails::ParentApprovals.chi_dirs, Paths.state_dir]
          .map { |dir| Guardrails::ProtectedPaths.real(dir.to_s.chomp("/")) }.reject(&:empty?).uniq
      end

      # Whether +real+ is in the memories dir and not in its installed bundles.
      def memory?(real, memories, bundles)
        Guardrails::ProtectedPaths.within?(real, memories) && !Guardrails::ProtectedPaths.within?(real, bundles)
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
