# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # Programs that write outside the folder they run in with no word of
    # the command naming where: a global install (npm -g, gem install, brew,
    # cargo/go install, pipx, uv tool), a user config file (npm config set
    # writes ~/.npmrc, gh config set ~/.config/gh), the system's defaults, a
    # launchd job. A pair turn's "a write outside the project always asks"
    # counts them as outside writes (PairCommand#outside_writes?).
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
      GLOBAL = %w[-g --global --location=global].freeze
      NPM_CHANGES = %w[install i in add isntall uninstall un unlink remove rm r update up upgrade link ln].freeze
      # program => the word groups of a call that writes outside: its
      # arguments hold a word of every group of one entry.
      BY_VERB = {
        "npm" => [[NPM_CHANGES, GLOBAL], [%w[config c], %w[set delete rm edit fix]],
                  [%w[set login adduser add-user logout]]],
        "yarn" => [[%w[global]], [%w[config], %w[set delete unset]]],
        "pnpm" => [[NPM_CHANGES, GLOBAL], [%w[config], %w[set delete]], [%w[setup]]],
        "bun" => [[NPM_CHANGES, GLOBAL]],
        "pip" => [[%w[install uninstall]], [%w[config], %w[set unset edit]]],
        "gem" => [[%w[install i update uninstall cleanup pristine]],
                  [%w[sources], %w[-a --add -r --remove -c --clear-all]]],
        "defaults" => [[%w[write delete rename import]]],
        "cargo" => [[%w[install uninstall]]],
        "go" => [[%w[install]], [%w[env], %w[-w -u]]],
        "uv" => [[%w[tool], %w[install uninstall upgrade update-shell]], [%w[python], %w[install uninstall]],
                 [%w[self], %w[update]]],
        "gh" => [[%w[auth], %w[login logout refresh setup-git switch]], [%w[config], %w[set]],
                 [%w[extension extensions ext], %w[install upgrade remove]], [%w[alias], %w[set delete import]]]
      }.freeze
      # program => the verbs (its first argument) that only read: every
      # other one writes outside.
      READ_VERBS = {
        "brew" => %w[list ls info search desc deps uses outdated leaves config doctor --prefix --cellar --repository
                     --version -v --help -h help],
        "pipx" => %w[list environment --version --help -h],
        "launchctl" => %w[list print print-cache print-disabled blame procinfo hostinfo examine version help]
      }.freeze
      # Installers whose program named by a path into the project (a
      # project venv's pip) install there, and the options that say where.
      LOCAL_INSTALLERS = %w[pip].freeze
      PLACE_OPTIONS = /\A(?:-t|--target|--prefix|--root)(?:=|\z)/
      # pip3, pip3.12 → pip.
      ALIASES = { /\Apip\d*(?:\.\d+)?\z/ => "pip" }.freeze

      module_function

      # The table's name for +program+ (a word's basename).
      def name(program)
        base = File.basename(program.to_s)
        ALIASES.each { |pattern, to| return to if base.match?(pattern) }
        base
      end

      # Whether +program+ (its word) run with +args+ writes outside the
      # folder it runs in with no word naming where. +local+ says the
      # program's word is a path into the project (LOCAL_INSTALLERS).
      def outside?(program, args, local: false)
        program = name(program)
        if (verbs = READ_VERBS[program])
          return !(args.empty? || verbs.include?(args.first))
        end

        entries = BY_VERB[program] or return false
        return false unless entries.any? { |groups| groups.all? { |group| args.intersect?(group) } }
        return true unless LOCAL_INSTALLERS.include?(program)
        return true if args.include?("--user")

        !(local || args.any? { |arg| arg.match?(PLACE_OPTIONS) })
      end
    end
  end
end
