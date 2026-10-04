# frozen_string_literal: true

require "rbconfig"

module Samagotchi
  module Tools
    # The shell a model's (or the user's `!`) command runs in: execute,
    # task_create and the shell bang. Non-login (a login shell re-sources
    # profile files, which can rebuild PATH and shadow the inherited toolchain).
    #
    # macOS's /bin/sh is bash 3.2, which can't parse an apostrophe in a
    # heredoc inside "$( )" -- the usual `git commit -m "$(cat <<'EOF' ...`.
    # There, zsh in sh emulation runs instead (it reads no rc files in that
    # mode), with the options that keep bash habits working: `{1..3}` brace
    # expansion, unquoted `( )` in `[[ =~ ]]`, BASH_REMATCH, and echo
    # expanding `\t` as macOS's sh does. Elsewhere (Linux) /bin/sh as before.
    module Shell
      ZSH = "/bin/zsh"
      ZSH_SH_MODE = [ZSH, "--emulate", "sh", "+o", "ignore_braces", "+o", "sh_glob", "-o", "bash_rematch",
                     "+o", "bsd_echo"].freeze
      SH = ["/bin/sh"].freeze

      # @return [Array<String>] the argv that runs +command+
      def self.argv(command) = [*program, "-c", command]

      # @return [Array<String>] the shell and its options, without -c
      def self.program(host_os: RbConfig::CONFIG["host_os"], zsh: File.executable?(ZSH))
        host_os.to_s.include?("darwin") && zsh ? ZSH_SH_MODE : SH
      end
    end
  end
end
