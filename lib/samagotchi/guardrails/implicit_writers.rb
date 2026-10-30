# frozen_string_literal: true

require_relative "shell_lex"

module Samagotchi
  module Guardrails
    # Programs that write outside the folder they run in with no word of
    # the command naming where: a global install (npm -g, gem install, brew,
    # cargo/go install, pipx, uv tool), a user config file (npm config set
    # writes ~/.npmrc, gh config set ~/.config/gh, bundle config set), the
    # system's defaults, a launchd job, a tool manager's global version, git
    # maintenance's schedule and git lfs's global filters. A pair turn's "a
    # write outside the project always asks" counts them as outside writes
    # (PairCommand#outside_writes?). The table holds examples, not a closed
    # set: a program it doesn't know runs unasked.
    #
    # pip counts with or without --user: it writes into its interpreter's
    # site-packages, which no word names and which a plain `pip` (the
    # worker's PATH, any VIRTUAL_ENV it inherited) may place anywhere. A pip
    # or python named by a path into the project (.venv/bin/pip) installs
    # into the project, and -t/--target/--prefix/--root name where it
    # writes (their value is checked as any word): those don't count
    # (PairCommand checks the program's path: LOCAL_INSTALLERS).
    #
    # Not counted: a project install (npm install, bundle install, uv sync)
    # and the caches every build writes (~/.npm, ~/.cache, go's module
    # cache): they hold downloads, not what runs as the owner.
    module ImplicitWriters
      NPM_CHANGES = %w[install i in add isntall uninstall un unlink remove rm r update up upgrade link ln].freeze
      # program => the word groups of a call that writes outside: its
      # arguments hold a word of every group of one entry (:global: npm's
      # global flag in any spelling, .global?; [] alone: any call).
      BY_VERB = {
        "npm" => [[NPM_CHANGES, :global], [%w[link ln]], [%w[config c], %w[set delete rm edit fix]],
                  [%w[set login adduser add-user logout]]],
        "yarn" => [[%w[global]], [%w[link]], [%w[config], %w[set delete unset]]],
        "pnpm" => [[NPM_CHANGES, :global], [%w[config], %w[set delete]], [%w[setup]]],
        "bun" => [[NPM_CHANGES, :global], [%w[link]]],
        "pip" => [[%w[install uninstall]], [%w[config], %w[set unset edit]]],
        "ensurepip" => [[]],
        "easy_install" => [[]],
        "pipenv" => [[%w[install uninstall sync update]]],
        "poetry" => [[%w[self]]],
        "conda" => [[%w[install remove uninstall update upgrade create]]],
        "gem" => [[%w[install i update uninstall cleanup pristine]],
                  [%w[sources], %w[-a --add -r --remove -c --clear-all]]],
        "bundle" => [[%w[install], %w[--system]]],
        "defaults" => [[%w[write delete rename import]]],
        "cargo" => [[%w[install uninstall]]],
        "go" => [[%w[install]], [%w[env], %w[-w -u]]],
        "uv" => [[%w[tool], %w[install uninstall upgrade update-shell]], [%w[python], %w[install uninstall]],
                 [%w[self], %w[update]], [%w[pip], %w[install uninstall sync], %w[--system]]],
        "deno" => [[%w[install uninstall], :global]],
        "dotnet" => [[%w[tool], %w[install update uninstall], %w[-g --global --tool-path]]],
        "corepack" => [[%w[enable disable]], [%w[install], :global]],
        "pyenv" => [[%w[global install uninstall rehash]]],
        "rbenv" => [[%w[global install uninstall rehash]]],
        "nodenv" => [[%w[global install uninstall rehash]]],
        "asdf" => [[%w[install uninstall global plugin reshim]]],
        "volta" => [[%w[install uninstall setup fetch]]],
        "nvm" => [[%w[install uninstall alias unalias]]],
        "code" => [[%w[--install-extension --uninstall-extension]]],
        "gh" => [[%w[auth], %w[login logout refresh setup-git switch]], [%w[config], %w[set]],
                 [%w[extension extensions ext], %w[install upgrade remove]], [%w[alias], %w[set delete import]]],
        # the global config and a launchd/cron schedule; git lfs's global filters
        # (git's first group is its subcommand: .git_outside?)
        "git" => [[%w[maintenance], %w[register start unregister stop]], [%w[lfs], %w[install uninstall update]]],
        "git-maintenance" => [[%w[register start unregister stop]]],
        "git-lfs" => [[%w[install uninstall update]]],
        "scalar" => [[%w[register unregister clone reconfigure delete]]]
      }.freeze
      # program => the verbs (its first argument) that only read: every
      # other one writes outside.
      READ_VERBS = {
        "brew" => %w[list ls info search desc deps uses outdated leaves config doctor --prefix --cellar --repository
                     --version -v --help -h help],
        "pipx" => %w[list environment --version --help -h],
        "launchctl" => %w[list print print-cache print-disabled blame procinfo hostinfo examine version help],
        "rustup" => %w[show which --version -V help --help -h completions]
      }.freeze
      # Installers whose program named by a path into the project (a
      # project venv's pip) install there, and the options that say where.
      LOCAL_INSTALLERS = %w[pip ensurepip easy_install].freeze
      PLACE_OPTIONS = /\A(?:-t|--target|--prefix|--root)(?:=|\z)/
      # pip3, pip3.12 → pip.
      ALIASES = { /\Apip\d*(?:\.\d+)?\z/ => "pip" }.freeze
      # npm's global flag: -g, --global, --global=true, --location=global
      # (and --location global, two words: .global?).
      GLOBAL = /\A(?:-g|--global|--global=(?!false\z).*|--location=global)\z/
      # npm reads its config from the environment too.
      NPM_ENV_GLOBAL = /\Anpm_config_(?:global|location)\z/i

      module_function

      # The table's name for +program+ (its word's ShellLex.program_name).
      def name(program)
        base = ShellLex.program_name(program)
        ALIASES.each { |pattern, to| return to if base.match?(pattern) }
        base
      end

      # Whether +program+ (its word) run with +args+ writes outside the
      # folder it runs in with no word naming where. +local+ says the
      # program's word is a path into the project (LOCAL_INSTALLERS);
      # +assigned+ the variables the command sets before it.
      def outside?(program, args, local: false, assigned: {})
        program = name(program)
        if (verbs = READ_VERBS[program])
          return !(args.empty? || verbs.include?(args.first))
        end
        return bundle_config_outside?(args) if program == "bundle" && args.first == "config"

        entries = BY_VERB[program] or return false
        return git_outside?(entries, args, assigned) if program == "git"
        return false unless entries.any? { |groups| groups.all? { |group| group?(group, args, assigned) } }
        return true unless LOCAL_INSTALLERS.include?(program)
        return true if args.include?("--user")

        !(local || args.any? { |arg| arg.match?(PLACE_OPTIONS) })
      end

      # git's entries match from its subcommand on (PairCommand.git_command_starts:
      # git -C . maintenance start), the first group holding the subcommand,
      # not its words anywhere (git add maintenance start, git commit -m lfs -m install).
      def git_outside?(entries, args, assigned)
        PairCommand.git_command_starts(args).grep(Integer).any? do |i|
          entries.any? do |first, *rest|
            first.include?(args[i]) && rest.all? { |group| group?(group, args[(i + 1)..], assigned) }
          end
        end
      end

      def group?(group, args, assigned)
        group == :global ? global?(args, assigned) : args.intersect?(group)
      end

      # npm's (pnpm's, bun's, deno's, corepack's) global flag, in any of
      # its spellings or the environment's (npm_config_global=true).
      def global?(args, assigned = {})
        args.any? { |arg| arg.match?(GLOBAL) } || args.each_cons(2).include?(%w[--location global]) ||
          assigned.any? { |key, value| key.match?(NPM_ENV_GLOBAL) && !%w[false local project].include?(value.to_s) }
      end

      # bundle config set/unset writes ~/.bundle/config unless --local, and
      # so does the old form `bundle config NAME VALUE`; a list or a get
      # (or a NAME alone) only reads.
      def bundle_config_outside?(args)
        rest = args.drop(1)
        return false if rest.include?("--local")

        words = rest.reject { |arg| arg.start_with?("-") }
        return false if words.empty? || %w[list get].include?(words.first)

        %w[set unset].include?(words.first) || words.size > 1
      end
    end
  end
end
