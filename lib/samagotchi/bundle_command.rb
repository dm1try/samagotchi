# frozen_string_literal: true

require_relative "cli/flags"
require_relative "cli/exit"
require_relative "memory_bundle"

module Samagotchi
  # `chi bundle`: install, upgrade, uninstall, status, diff, list and build
  # memory bundles (bin/chi dispatches here before OptionParser; the
  # subcommands have their own flags).
  class BundleCommand
    USAGE = <<~TEXT
      Usage: chi bundle <install|upgrade|uninstall|status|diff|list|build|trash|new|test|check|try> [options]

        install <source> [--scope system|project] [--force]
          Install a memory bundle from a directory, zip, tar archive, or git URL.
          Source is the path/URL to the bundle (dir/zip/tar.gz/git).
          --force overwrites existing entries; default skips them.

        upgrade <source> [--scope system|project] [--force] [--dry-run] [--agent|--no-agent]
          Upgrade a bundle (3-way merge: auto-merge if not edited, conflict otherwise).
          --dry-run shows what would change. --agent launches interactive session on conflict.

        uninstall <bundle> [--scope system|project] [--force]
          Remove a bundle and its index entries (--force if locally edited).

        status [<bundle>]
          Show provenance + modification status for bundles.

        diff <bundle> [file]
          Show diffs between base/current/incoming for a bundle.

        list
          List installed bundles and the ones shipped with chi that aren't installed.

        build [--scope system|project] [--name NAME] [--version VER] [--description DESC] [--out PATH] [FILES...]
          Build local memories and installed hooks (and plugin) into a shareable bundle (dir or zip).
          --scope selects source dir (default: system). --out inferred from extension; default <name>.zip.
          FILES... optional allowlist of *.md basenames to include (default: all but installed bundles' ones);
          a named memory brings its model overlays (<name>.<model-key>.md).

        trash [--empty] [--dry-run] [--older-than DAYS]
          List bundle trash (moved files from uninstalls/upgrades).
          --empty deletes all trash folders. --older-than DAYS keeps only recent ones.

        new NAME [--dir DIR]
          Start a bundle in DIR/NAME (default ./NAME): manifest, plugin, a passing test, README.

        test [PATH] [-- ARGS]
          Run a bundle's test/*_test.rb (Minitest) or spec/ (RSpec) on chi's Ruby and lib.

        check [PATH] [--fix] [--set KEY=VALUE]
          Check a bundle you're writing (default: the current dir): manifest, files, sha256 lines,
          requires_chi, and an install + load in a sandbox. --fix rewrites stale sha256 lines.

        try PATH -p TEXT [options]
          Run one non-interactive model turn with a bundle installed in an isolated sandbox.
    TEXT

    # Each subcommand's --help (and only --help: -h and help are taken as
    # the source or name).
    INSTALL_HELP = <<~TEXT
      Usage: chi bundle install <source> [--scope system|project] [--force]
             chi bundle install --dev PATH

        install <source> [--scope system|project] [--force]
          Install a memory bundle from a directory, zip, tar archive, or git URL,
          or a bundle shipped with chi by name (see: chi bundle list).
          --force overwrites existing entries; default skips them.
        install --dev PATH
          Install the bundle in the local directory PATH as a link to it: its plugin, hooks, rules and scripts
          are PATH's own files (an edit applies at the next worker or chi web restart, with no re-install) and
          their sha256 isn't checked, for this bundle only. Its memories are copied; re-install with --force to
          pick up memory edits. Upgrade refuses it; uninstall removes the link, never PATH's files.
    TEXT
    UPGRADE_HELP = "Usage: chi bundle upgrade <source> [--scope system|project] [--force] [--dry-run] [--agent|--no-agent]"
    UNINSTALL_HELP = "Usage: chi bundle uninstall <bundle> [--scope system|project] [--force]"
    BUILD_HELP = <<~TEXT
      Usage: chi bundle build [--scope system|project] [--name NAME] [--version VER] [--description DESC] [--out PATH] [FILES...]

        build [--scope system|project] [--name NAME] [--version VER] [--description DESC] [--out PATH] [FILES...]
          Build local memories and installed hooks into a shareable bundle (dir or zip).
          --scope selects source dir (default: system). --out inferred from extension; default <name>.zip.
          FILES... optional allowlist of *.md basenames to include (default: all but installed bundles' ones);
          a named memory brings its model overlays (<name>.<model-key>.md).

        Examples:
          chi bundle build --scope system
          chi bundle build --scope project --name my-bundle --version 1.0.0 --out bundle.zip
          chi bundle build --scope system --out ./my-bundle/ identity.md work.md
    TEXT
    TRASH_HELP = "Usage: chi bundle trash [--empty] [--dry-run] [--older-than DAYS]"
    NEW_HELP = <<~TEXT
      Usage: chi bundle new NAME [--dir DIR]

        Start a bundle in DIR/NAME (default ./NAME; refused when it exists): manifest.yml (shas filled,
        requires_chi this chi), plugin.rb (a /NAME command and an after_tool_call hook), test/NAME_test.rb
        (passes as written) and README.md. Then: chi bundle test, chi bundle check, chi bundle install.
    TEXT
    TEST_HELP = <<~TEXT
      Usage: chi bundle test [PATH] [-- ARGS]

        Run the tests of the bundle at PATH (default: .) on the Ruby and the lib chi runs on, outside any Bundler env:
        test/**/*_test.rb on Minitest (require "samagotchi/testing/minitest"), or else spec/ on RSpec with the kit
        (-r samagotchi/testing/rspec). ARGS go to the test runner (-- -n /name/, -- -e "a name").
        The tests run the bundle's code as written, with your HOME (the kit's sandbox is per test): run code you'd install.
        Exit status: the tests'; 1 no tests; 2 usage, or minitest / rspec doesn't load.
    TEXT
    CHECK_HELP = <<~TEXT
      Usage: chi bundle check [PATH] [--fix] [--set KEY=VALUE]

        Check the bundle at PATH (default: .) as an install would take it, one finding per line:
          error|warn|info CODE file[:line]: message (fix: hint)
        It installs and loads the bundle in a sandbox (temp HOME, config and state), not in yours, but its plugin and
        hooks run in this process as written: run it on code you'd install.
        --fix            rewrite stale and placeholder sha256 lines in manifest.yml
        --set KEY=VALUE  a setting for the load (config.yml bundles: <name>: KEY), repeatable
        Exit status: 0 no errors, 1 errors, 2 usage.
    TEXT
    TRY_HELP = <<~TEXT
      Usage: chi bundle try PATH -p TEXT [--model NAME] [--memory NAME] [--mute NAME] [--toolkit NAME]
             [--thinking LEVEL] [--set KEY=VALUE] [--json] [--keep] [--timeout SECONDS]

        Install PATH and run one non-interactive turn in an isolated temporary config, state and work directory.
        The user's hosts, keys and ordinary runtime settings are retained; their bundles, hooks, guardrails,
        memories, prompt additions, sessions and attached context sources are not. Shipped guardrails and a
        $1 cost cap are installed for the run. --set KEY=VALUE sets the tried bundle's config.yml bundles entry;
        --set cost-cap.cap=N overrides the cap (unlike chi --set BUNDLE.KEY=VALUE, these are config settings).
        --memory and --mute accept comma-separated names and repeat. --keep retains the sandbox and debug log.
        --json prints the experimental machine-readable trace.
        Exit status: child turn's status; 1 on install failure or timeout; 2 for usage; 130 on Ctrl-C.
    TEXT

    # The subcommands' flags: --help only; a word not starting with -- is
    # a positional (install's source, -h included). --scope takes whatever
    # follows it; build's value flags not a --flag.
    INSTALL_FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A--/) do |f|
      f.value "--scope"
      f.switch "--force"
      f.switch "--dev"
    end
    UNINSTALL_FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A--/) do |f|
      f.value "--scope"
      f.switch "--force"
    end
    UPGRADE_FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A--/) do |f|
      f.value "--scope"
      f.switch "--force"
      f.switch "--dry-run"
      f.switch "--agent"
      f.switch "--no-agent", key: :agent, set: false
    end
    BUILD_FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A--/, dash_values: false) do |f|
      %w[--scope --name --version --description --out].each { |name| f.value name }
    end
    NEW_FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A--/) do |f|
      f.value "--dir"
    end
    TEST_FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A-/)
    CHECK_FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A--/) do |f|
      f.switch "--fix"
      f.value "--set", key: :set, repeat: true
    end
    TRY_FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A-/) do |f|
      f.value "-p", "--prompt", key: :prompt
      f.value "--model"
      f.value "--memory", repeat: true
      f.value "--mute", repeat: true
      f.value "--toolkit"
      f.value "--thinking"
      f.value "--set", repeat: true
      f.switch "--json"
      f.switch "--keep"
      f.value "--timeout"
      f.refuse "--attach", "--shared", "chi bundle try can't use --attach or --shared"
    end
    TRASH_FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A--/) do |f|
      f.switch "--empty"
      f.switch "--dry-run"
      f.value "--older-than"
    end

    # @param argv [Array<String>] the arguments after "bundle"
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
    end

    # @return [Integer] exit status
    def run
      sub = @argv[0]
      if sub.nil? || %w[-h --help help].include?(sub)
        @stdout.puts USAGE
        return 0
      end

      case sub
      when "install" then install(@argv[1..])
      when "upgrade" then upgrade(@argv[1..])
      when "uninstall" then uninstall(@argv[1..])
      when "status" then status(@argv[1..])
      when "diff" then diff(@argv[1..])
      when "list" then list
      when "build" then build(@argv[1..])
      when "trash" then trash(@argv[1..])
      when "new" then new_bundle(@argv[1..])
      when "test" then test_bundle(@argv[1..])
      when "check" then check(@argv[1..])
      when "try" then try_bundle(@argv[1..])
      else
        @stderr.puts "Unknown bundle subcommand: #{sub}. Use: install, upgrade, uninstall, status, diff, list, build, trash, new, test, check, try"
        CLI::Exit::USAGE
      end
    end

    private

    def install(rest)
      parsed = parse_flags(INSTALL_FLAGS, rest, "install", help: INSTALL_HELP)
      return parsed if parsed.is_a?(Integer)

      opts = parsed.options
      source = parsed.args.last
      scope = opts[:scope]
      force = opts.fetch(:force, false)
      dev = opts.fetch(:dev, false)
      if source.nil? || source.empty?
        @stderr.puts "Usage: chi bundle install <source> [--scope system|project] [--force]"
        return CLI::Exit::USAGE
      end
      if dev && (Samagotchi::MemoryBundle::SourceNormalizer.git_url?(source) || !File.directory?(source))
        @stderr.puts "chi bundle install --dev takes a local directory (the bundle's source), not #{source}"
        return CLI::Exit::USAGE
      end
      expanded_source = dev ? File.realpath(source) : expand_source(source)
      if dev && File.dirname(expanded_source) == File.realpath(Samagotchi::MemoryBundle::SourceNormalizer::SHIPPED_DIR)
        @stderr.puts "chi bundle install --dev cannot be used with chi-shipped bundles or profiles; " \
                     "use chi bundle install #{File.basename(expanded_source)} instead"
        return CLI::Exit::USAGE
      end
      if Samagotchi::MemoryBundle::Profile.shipped_meta?(expanded_source)
        return install_profile(expanded_source, scope: scope, force: force, dry_run: false, word: "Install")
      end

      prepared, bundle_name = prepare_or_fail(expanded_source, "Install")
      return 1 unless prepared
      return 1 if installed_under_another_name?(expanded_source, bundle_name, prepared, "Install")

      installer = installer_for(expanded_source, bundle_name, prepared: prepared, scope: scope, force: force, dev: dev)
      run_installer(installer, failed: "Install") do |manifest|
        print_hooks_and_plugin(manifest)
        print_provenance(bundle_name, manifest)
      end
    end

    def upgrade(rest)
      parsed = parse_flags(UPGRADE_FLAGS, rest, "upgrade", help: UPGRADE_HELP)
      return parsed if parsed.is_a?(Integer)

      opts = parsed.options
      source = parsed.args.last
      scope = opts[:scope]
      force = opts.fetch(:force, false)
      dry_run = opts.fetch(:dry_run, false)
      agent = opts[:agent]
      if source.nil? || source.empty?
        @stderr.puts UPGRADE_HELP
        return CLI::Exit::USAGE
      end
      expanded_source = expand_source(source)
      if Samagotchi::MemoryBundle::Profile.shipped_meta?(expanded_source)
        return install_profile(expanded_source, scope: scope, force: force, dry_run: dry_run, word: "Upgrade")
      end

      prepared, bundle_name = prepare_or_fail(expanded_source, "Upgrade")
      return 1 unless prepared
      return 1 if installed_under_another_name?(expanded_source, bundle_name, prepared, "Upgrade")

      unless Samagotchi::MemoryBundle::Provenance.new(name: bundle_name).installed?
        @stderr.puts "Bundle '#{bundle_name}' not installed — falling back to install"
        # (no Hooks/Plugin lines here)
        installer = installer_for(expanded_source, bundle_name, prepared: prepared, scope: scope, force: force, dry_run: dry_run)
        return run_installer(installer, failed: "Install") do |manifest|
          next dry_run_done if dry_run

          print_provenance(bundle_name, manifest)
        end
      end
      installer = installer_for(expanded_source, bundle_name, prepared: prepared, scope: scope, force: force, upgrade: true, dry_run: dry_run)
      run_installer(installer, failed: "Upgrade") do |manifest|
        print_hooks_and_plugin(manifest, plugin: !dry_run)
        next dry_run_done if dry_run
        next upgrade_conflicts(installer, bundle_name, expanded_source, agent) if installer.conflicts.any? && !force

        print_provenance(bundle_name, manifest)
      end
    end

    # The source normalized once (a git clone, a zip or tar extract) and the
    # bundle's name, its manifest's name: for every kind of source, a git URL
    # too. The Installer installs from that extract and removes it. Nil
    # after "<word> failed: …" (an unknown source, or a missing or invalid
    # manifest: an install needs one anyway), the extract removed.
    # @return [Array(MemoryBundle::PreparedSource, String), nil]
    def prepare_or_fail(expanded_source, word)
      prepared = Samagotchi::MemoryBundle::PreparedSource.prepare(expanded_source)
      named = [prepared, Samagotchi::MemoryBundle::Manifest.read(dir: prepared.dir).name]
    rescue Samagotchi::MemoryBundle::SourceNormalizer::UnknownSourceError,
           Samagotchi::MemoryBundle::Manifest::ValidationError => e
      @stderr.puts "#{word} failed: #{e.message}"
    ensure
      # Any failure (an unexpected error too) removes the extract.
      prepared&.cleanup unless named
    end

    # A bundle installed from this source under another name: a git URL
    # bundle recorded before chi named it by its manifest (it took the
    # repo's name, chi-foo for name: foo). Installing it again would load
    # both copies' plugin and hooks, so "<word> failed: … installed as
    # chi-foo" instead (the extract removed). Only when no bundle has the
    # manifest's name; sources compare by SourceIdentity.
    # @return [Boolean] refused
    def installed_under_another_name?(expanded_source, bundle_name, prepared, word)
      return false if Samagotchi::MemoryBundle::Provenance.new(name: bundle_name).installed?

      identity = Samagotchi::MemoryBundle::SourceIdentity.of(expanded_source)
      return false unless identity

      other, = Samagotchi::MemoryBundle::Provenance.each_installed.find do |name, bundle|
        name != bundle_name && !bundle.error? && Samagotchi::MemoryBundle::SourceIdentity.of(bundle.source) == identity
      end
      return false unless other

      prepared.cleanup
      @stderr.puts "#{word} failed: #{expanded_source} is installed as #{other}: `chi bundle uninstall #{other}`, then install it again"
      true
    end

    def installer_for(source, name, scope:, force:, **)
      Samagotchi::MemoryBundle::Installer.new(source: source, name: name, scope: scope, force: force, strict: true, **)
    end

    # Runs +installer+, prints its summary, then yields the manifest.
    # Ensures the extracted source dir is cleaned up even if an exception
    # occurs between installer.run and the block (e.g. summary,
    # print_hooks_and_plugin). The block (upgrade_conflicts) still sees
    # the files because cleanup happens after the block returns or raises.
    # @return [Integer] the block's exit status, or 1 after "<failed> failed: …"
    def run_installer(installer, failed:)
      _nd, manifest = installer.run
      @stdout.puts installer.summary
      yield manifest
    rescue Samagotchi::MemoryBundle::Installer::InstallError => e
      @stderr.puts "#{failed} failed: #{e.message}"
      1
    ensure
      installer.cleanup_source!
    end

    def print_hooks_and_plugin(manifest, plugin: true)
      @stdout.puts "Hooks: #{manifest.hooks.size} hook(s) (#{manifest.hooks.keys.join(", ")})" if manifest&.hooks&.any?
      @stdout.puts "Plugin: #{manifest.plugin[:file]} (loads at the next chi start)" if plugin && manifest&.plugin
    end

    # @return [Integer] 0
    def print_provenance(bundle_name, manifest)
      @stdout.puts "Provenance written to: #{Samagotchi::MemoryBundle::Provenance.bundles_dir}/#{bundle_name}/" if manifest
      0
    end

    # @return [Integer] 0
    def dry_run_done
      @stdout.puts "(dry-run: no changes written)"
      0
    end

    # An upgrade that kept edited files: launch an agent to merge them
    # (--agent, or yes on a terminal), or say how to take the bundle's.
    # An upgrade that kept edited files exits 2, as a usage error does
    # (scripts already read it so): not CLI::Exit::USAGE by meaning.
    CONFLICTS_KEPT = 2

    # @return [Integer] 0 resolved, CONFLICTS_KEPT kept the edits
    def upgrade_conflicts(installer, bundle_name, expanded_source, agent)
      @stdout.puts "\n#{installer.conflicts.size} conflict(s) need resolution."
      installer.conflicts.each { |k, _| @stdout.puts "  conflict: #{k}" }
      launch = if agent.nil? && @stdin.tty?
                 @stdout.print "Conflicts detected — launch interactive agent to resolve? [y/N] "
                 ans = begin; @stdin.gets; rescue StandardError => _e; nil; end
                 ans && ans.strip.downcase.start_with?("y")
               elsif agent.nil?
                 @stdout.puts "Non-interactive terminal: kept your edits in the file(s) above; the rest is upgraded. Re-run with --force to take the bundle's version, or --agent in a TTY to merge."
                 return CONFLICTS_KEPT
               else
                 agent
               end
      unless launch
        @stdout.puts "Kept your edits in the file(s) above; the rest is upgraded. chi bundle diff #{bundle_name} FILE shows the base; re-run with --force to take the bundle's version."
        return CONFLICTS_KEPT
      end

      prompt = build_conflict_prompt(bundle_name, installer.conflicts, expanded_source)
      @stdout.puts "Launching interactive session for conflict resolution… (/exit when done)"
      require "samagotchi/terminal_ui"
      Samagotchi::TerminalUI.new(prompt: prompt).run
      # The installer already recorded the upgrade (conflicted files kept
      # their old base); the resolved files now start from the bundle's
      # version.
      Samagotchi::MemoryBundle::Provenance.new(name: bundle_name).resolve_conflicts(installer.conflicts)
      @stdout.puts "Provenance updated after interactive resolution."
      @stdout.puts "Upgrade resolved interactively."
      0
    ensure
      # An owned source (git/zip/tar) was kept for the incoming files above;
      # the agent step is done with them now.
      installer.cleanup_source!
    end

    def uninstall(rest)
      parsed = parse_flags(UNINSTALL_FLAGS, rest, "uninstall", help: UNINSTALL_HELP)
      return parsed if parsed.is_a?(Integer)

      opts = parsed.options
      bundle_name = parsed.args.last
      scope = opts[:scope]
      force = opts.fetch(:force, false)
      if bundle_name.nil? || bundle_name.empty?
        @stderr.puts "Usage: chi bundle uninstall <bundle> [--scope system|project] [--force]"
        return CLI::Exit::USAGE
      end
      record = Samagotchi::MemoryBundle::Provenance.new(name: bundle_name).record
      return uninstall_profile(bundle_name, force: force) if Samagotchi::MemoryBundle::Profile.installed_meta?(bundle_name, record)

      uninstaller = Samagotchi::MemoryBundle::Uninstaller.new(name: bundle_name, scope: scope, force: force)
      begin
        uninstaller.run
        @stdout.puts "Uninstalled bundle '#{bundle_name}'"
        puts_trashed(uninstaller.trashed_files, uninstaller.trash_dir)
        @stdout.puts "Removed: #{uninstaller.removed_files.join(", ")}" unless uninstaller.removed_files.empty?
        hook_removed = uninstaller.removed_files.count { |f| f.start_with?("hooks/") }
        @stdout.puts "Hooks removed: #{hook_removed}" if hook_removed > 0
        uninstaller.warnings.each { |w| @stdout.puts w }
        0
      rescue Samagotchi::MemoryBundle::Uninstaller::UninstallError => e
        @stderr.puts "Uninstall failed: #{e.message}"; 1
      end
    end

    # install/upgrade of a shipped profile: its new members (Profile).
    def install_profile(dir, scope:, force:, dry_run:, word:)
      name = File.basename(dir)
      if scope.to_s.strip.downcase == "project"
        @stderr.puts "#{word} failed: #{name} is a profile: its bundles install system-wide (drop --scope project)"
        return 1
      end
      result = Samagotchi::MemoryBundle::Profile.install(dir, dry_run: dry_run, force: force)
      @stdout.puts "#{result.name} v#{result.version} (profile)"
      lines = []
      lines << "#{dry_run ? "would install" : "installed"}: #{result.installed.join(", ")}" unless result.installed.empty?
      lines << "already installed: #{result.already.join(", ")}" unless result.already.empty?
      result.skipped.each { |member, why| lines << "skipped #{member}: #{why}" }
      result.failed.each { |member, why| lines << "failed #{member}: #{why}" }
      lines << "nothing new to install" if lines.empty?
      lines.each { |line| @stdout.puts "  #{line}" }
      @stdout.puts "(dry-run: no changes written)" if dry_run
      result.failed? ? 1 : 0
    rescue Samagotchi::MemoryBundle::Manifest::ValidationError => e
      @stderr.puts "#{word} failed: #{e.message}"
      1
    end

    # uninstall of a profile: its recorded members, then itself (Profile).
    def uninstall_profile(name, force:)
      result = Samagotchi::MemoryBundle::Profile.uninstall(name, force: force)
      if result.gone
        @stdout.puts "Uninstalled bundle '#{name}'"
        @stdout.puts "Removed: #{result.removed.join(", ")}" unless result.removed.empty?
        result.trash.each_value { |files, dir| puts_trashed(files, dir) }
        result.warnings.each { |w| @stdout.puts w }
        return 0
      end
      @stdout.puts "Removed from #{name}: #{result.removed.join(", ")}" unless result.removed.empty?
      result.trash.each_value { |files, dir| puts_trashed(files, dir) }
      result.warnings.each { |w| @stdout.puts w }
      result.blocked.each { |member, why| @stdout.puts "Kept #{member}: #{why}" }
      @stderr.puts "Uninstall failed: #{name} stays installed until #{result.blocked.keys.join(", ")} goes " \
                   "(chi bundle uninstall #{name} --force)"
      1
    rescue Samagotchi::MemoryBundle::Uninstaller::UninstallError => e
      @stderr.puts "Uninstall failed: #{e.message}"
      1
    end

    # Memory files an uninstall moved to the trash (MemoryBundle::Trash).
    def puts_trashed(files, dir)
      @stdout.puts "Moved to the trash: #{files.join(", ")} (#{dir})" if dir && !files.empty?
    end

    def status(rest)
      name = rest.find { |a| !a.start_with?("--") }
      require "json"
      if name
        st = Samagotchi::MemoryBundle::Status.bundle_status(name)
        unless st
          @stdout.puts "Bundle '#{name}' not installed."
          return 0
        end
        @stdout.puts "Bundle: #{name} v#{st[:provenance].version}#{dev_label(st[:provenance])} scope=#{status_scope(st)} installed=#{st[:provenance].installed_at}"
        if st[:scope_error]
          @stdout.puts "Target: (unknown scope: this chi can't resolve it; upgrade chi or reinstall the bundle)"
        else
          @stdout.puts "Target: #{st[:target_dir]}"
        end
        st[:files].each do |k, info|
          next @stdout.puts("  #{k}: unchecked") if info[:unchecked]

          mods = []
          mods << "conflict (kept your edits over v#{st[:provenance].version}: chi bundle diff #{name} #{k})" if info[:conflict]
          mods << "modified" if info[:modified]
          mods << "missing" if info[:missing]
          mods << "no-index" unless info[:index_present] || info[:overlay]
          label = mods.empty? ? "ok" : mods.join(",")
          label += " (model overlay)" if info[:overlay]
          @stdout.puts "  #{k}: #{label}"
        end
        # Hooks
        hooks = st[:provenance].hooks
        trust = st[:provenance].trust_level || "experimental"
        commit = st[:provenance].source_commit
        @stdout.puts "  trust_level: #{trust}" if hooks.any? || trust
        @stdout.puts "  source_commit: #{commit}" if commit
        if hooks.any?
          @stdout.puts "  Hooks (#{hooks.size}):"
          hooks.each do |hk, hook|
            hook_path = File.join(Samagotchi::MemoryBundle::Provenance.new(name: name).hooks_dir, hk)
            exists = File.exist?(hook_path) ? "ok" : "missing"
            @stdout.puts "    #{hk}: event=#{hook.event} on_error=#{hook.on_error} priority=#{hook.priority} [#{exists}]"
          end
          @stdout.puts "    requires_chi: #{st[:provenance].requires_chi}" if st[:hooks_requires_failure]
          @stdout.puts "    not loaded: #{st[:hooks_requires_failure]}" if st[:hooks_requires_failure]
        end
        if (plugin = st[:plugin])
          note = plugin[:state] == "modified" ? " (edited after install: not loaded; reinstall the bundle)" : ""
          @stdout.puts "  Plugin: #{plugin[:file]} [#{plugin[:state]}]#{note}"
          @stdout.puts "    requires_chi: #{plugin[:requires_chi]}" if plugin[:requires_chi]
          @stdout.puts "    not loaded: #{plugin[:requires_failure]}" if plugin[:requires_failure]
        end
        st[:needs].each { |need| @stdout.puts "  #{Samagotchi::MemoryBundle::Status.need_line(need)}" }
        (st[:provenance].includes || []).each do |member|
          state = Samagotchi::MemoryBundle::Provenance.new(name: member).installed? ? "installed" : "not installed: chi bundle install #{member}"
          @stdout.puts "  includes #{member} [#{state}]"
        end
      else
        bundles = Samagotchi::MemoryBundle::Provenance.each_installed.to_a
        @stdout.puts "No installed bundles." if bundles.empty?
        bundles.each do |bname, record|
          next @stdout.puts("  #{bname} (manifest.json unreadable)") if record.error?

          st = Samagotchi::MemoryBundle::Status.bundle_status(bname)
          mods = st[:files].values.count { |v| v[:modified] || v[:missing] }
          hooks_count = st[:provenance].hooks.size
          hook_info = hooks_count > 0 ? " hooks=#{hooks_count}" : ""
          plugin = st[:plugin]
          mods += 1 if plugin && (plugin[:state] != "ok" || plugin[:requires_failure])
          mods += 1 if st[:hooks_requires_failure]
          mods += 1 if st[:scope_error]
          plugin_info = plugin ? " plugin=#{plugin[:file]}" : ""
          includes = st[:provenance].includes
          includes_info = includes ? " includes=#{includes.join(",")}" : ""
          @stdout.puts "  #{bname} v#{st[:provenance].version}#{dev_label(st[:provenance])} scope=#{status_scope(st)} files=#{st[:files].size}#{hook_info}#{plugin_info}#{includes_info} issues=#{mods}"
        end
      end
      0
    end

    # " dev → /path (missing)" when a dev install's source isn't there, else "".
    def dev_label(record)
      return "" unless record.dev

      " dev → #{record.source}#{" (missing)" unless File.directory?(record.source)}"
    end

    # "team (unknown)" for a scope this chi can't resolve (Status#bundle_status).
    def status_scope(st) = st[:scope_error] ? "#{st[:scope]} (unknown)" : st[:scope]

    def diff(rest)
      args = rest.reject { |a| a.start_with?("--") }
      bname = args[0]
      file_arg = args[1]
      if bname.nil? || bname.empty?
        @stderr.puts "Usage: chi bundle diff <bundle> [file]"; return CLI::Exit::USAGE
      end
      prov = Samagotchi::MemoryBundle::Provenance.new(name: bname)
      record = prov.record
      unless record
        @stderr.puts "Bundle '#{bname}' not installed"; return 1
      end
      scope = record.effective_scope
      begin
        target_dir = Samagotchi::MemoryPaths.scope_dir!(scope)
      rescue ArgumentError => e
        @stderr.puts "Bundle '#{bname}': #{e.message}"; return 1
      end
      files = record.files
      hooks = record.hooks
      plugin_path = prov.plugin_path(record)
      plugin_file = plugin_path && File.basename(plugin_path)
      show_plugin = lambda do
        @stdout.puts "=== plugin/#{plugin_file} ==="
        @stdout.puts "--- base (provenance) ---"
        base = prov.plugin_base_path(plugin_file)
        @stdout.puts File.exist?(base) ? File.read(base) : "(no base)"
        @stdout.puts "--- current (on-disk) ---"
        @stdout.puts File.exist?(plugin_path) ? File.read(plugin_path) : "(missing)"
        @stdout.puts "--- metadata: sha256=#{record.plugin.sha256}#{" requires_chi=#{record.requires_chi}" if record.requires_chi}"
      end
      if file_arg
        # Try file first, then hook
        if record.owns?(file_arg)
          base = prov.base_path(file_arg)
          cur = File.join(target_dir, file_arg)
          @stdout.puts "=== #{file_arg} ==="
          @stdout.puts "--- base (provenance) ---"
          @stdout.puts File.exist?(base) ? File.read(base) : "(no base)"
          @stdout.puts "--- current (on-disk) ---"
          @stdout.puts File.exist?(cur) ? File.read(cur) : "(missing)"
        elsif hooks.key?(file_arg)
          base = prov.base_path(file_arg)
          cur = File.join(prov.hooks_dir, file_arg)
          @stdout.puts "=== hooks/#{file_arg} ==="
          @stdout.puts "--- base (provenance) ---"
          @stdout.puts File.exist?(base) ? File.read(base) : "(no base)"
          @stdout.puts "--- current (on-disk) ---"
          @stdout.puts File.exist?(cur) ? File.read(cur) : "(missing)"
          # Show hook metadata
          @stdout.puts hook_metadata_line(hooks[file_arg])
        elsif plugin_file && [plugin_file, "plugin/#{plugin_file}"].include?(file_arg)
          show_plugin.call
        else
          @stdout.puts "=== #{file_arg} ==="
          @stdout.puts "(not found in bundle)"
        end
        @stdout.puts ""
      else
        files.each_key do |k|
          base = prov.base_path(k)
          cur = File.join(target_dir, k)
          @stdout.puts "=== #{k} ==="
          @stdout.puts "--- base (provenance) ---"
          @stdout.puts File.exist?(base) ? File.read(base) : "(no base)"
          @stdout.puts "--- current (on-disk) ---"
          @stdout.puts File.exist?(cur) ? File.read(cur) : "(missing)"
          @stdout.puts ""
        end
        # Hooks diff
        hooks.each do |k, hook|
          base = prov.base_path(k)
          cur = File.join(prov.hooks_dir, k)
          @stdout.puts "=== hooks/#{k} ==="
          @stdout.puts "--- base (provenance) ---"
          @stdout.puts File.exist?(base) ? File.read(base) : "(no base)"
          @stdout.puts "--- current (on-disk) ---"
          @stdout.puts File.exist?(cur) ? File.read(cur) : "(missing)"
          @stdout.puts hook_metadata_line(hook)
          @stdout.puts ""
        end
        if plugin_file
          show_plugin.call
          @stdout.puts ""
        end
      end
      0
    end

    def list
      listing = Samagotchi::MemoryBundle::Listing
      shipped = listing.shipped
      installed = listing.installed(shipped: shipped)
      available = listing.available(shipped: shipped, installed: installed)

      # One column width for both sections, so the names line up.
      name_w = (installed.map { |b| b.name.length } + available.map { |s| s.source.length }).max.to_i
      ver_w = (installed.map { |b| (b.version || "?").to_s.length } + available.map { |s| s.version.length }).max.to_i + 1

      if installed.empty?
        @stdout.puts "No installed bundles."
      else
        @stdout.puts "Installed:"
        installed.each do |b|
          next @stdout.puts("  #{b.name.ljust(name_w)}  (#{b.error})") if b.error

          line = "  #{b.name.ljust(name_w)}  #{"v#{b.version || "?"}".ljust(ver_w)}  scope=#{b.scope || "?"}  " \
                 "#{b.includes ? profile_members(b.includes, installed) : "files=#{b.files}"}  installed=#{b.installed_at || "?"}"
          line += "  (shipped v#{b.upgrade.version}: chi bundle upgrade #{b.upgrade.source})" if b.upgrade
          @stdout.puts line
        end
        @stdout.puts "  (or all at once: chi update)" if installed.any?(&:upgrade)
      end
      unless available.empty?
        @stdout.puts ""
        @stdout.puts "Available (shipped with chi, install with: chi bundle install <name>):"
        available.each do |s|
          members = s.includes.empty? ? "" : " (#{s.includes.join(", ")})"
          @stdout.puts "  #{s.source.ljust(name_w)}  #{"v#{s.version}".ljust(ver_w)}  #{s.description}#{members}".rstrip
        end
      end
      0
    end

    # An installed profile's list cell: its recorded members still
    # installed, and the ones left out (uninstalled by the user).
    def profile_members(members, installed)
      names = installed.map(&:name)
      here, gone = members.partition { |m| names.include?(m) }
      "includes=#{here.join(",")}#{"  left out=#{gone.join(",")}" unless gone.empty?}"
    end

    def hook_metadata_line(hook)
      "--- metadata: event=#{hook.event} on_error=#{hook.on_error} priority=#{hook.priority} sha256=#{hook.sha256}"
    end

    def build(rest)
      parsed = parse_flags(BUILD_FLAGS, rest, "build", help: BUILD_HELP)
      return parsed if parsed.is_a?(Integer)

      scope, name, version, out = parsed.options.values_at(:scope, :name, :version, :out)
      description = parsed.options.fetch(:description, "")
      filter_files = parsed.args.empty? ? nil : parsed.args
      # Validate scope if given
      if scope && !%w[system project].include?(scope.to_s.strip.downcase)
        @stderr.puts "Invalid scope '#{scope}', expected system or project"
        return CLI::Exit::USAGE
      end
      begin
        builder = Samagotchi::MemoryBundle::Builder.new(
          scope: scope,
          name: name,
          version: version,
          description: description,
          out: out,
          files: filter_files
        )
        result = builder.run
        @stdout.puts "Built #{result[:files].size} file(s) to #{result[:out_path]}"
        @stdout.puts "Bundle: #{result[:name]} v#{result[:version]} scope=#{result[:scope]}"
        @stdout.puts "Files: #{result[:files].join(", ")}" unless result[:files].empty?
        builder.warnings.each { |w| @stdout.puts w }
        unless result[:placeholder_warnings].empty?
          @stdout.puts "Placeholders:"
          result[:placeholder_warnings].each { |w| @stdout.puts "  #{w}" }
        end
        0
      rescue Samagotchi::MemoryBundle::Builder::BuildError => e
        @stderr.puts "Build failed: #{e.message}"
        1
      end
    end

    def trash(rest)
      parsed = parse_flags(TRASH_FLAGS, rest, "trash", help: TRASH_HELP)
      return parsed if parsed.is_a?(Integer)

      opts = parsed.options
      empty = opts.fetch(:empty, false)
      dry_run = opts.fetch(:dry_run, false)
      older_than = opts[:older_than]

      # --older-than and --dry-run without --empty are a usage error
      if (older_than || dry_run) && !empty
        @stderr.puts "Usage: chi bundle trash [--empty] [--dry-run] [--older-than DAYS]"
        return CLI::Exit::USAGE
      end

      # Validate older_than if given
      if older_than
        if older_than.to_s.match?(/\A\d+\z/) && older_than.to_i > 0
          older_than = older_than.to_i
        else
          @stderr.puts "Usage: chi bundle trash [--empty] [--dry-run] [--older-than DAYS]"
          return CLI::Exit::USAGE
        end
      end

      if empty
        do_empty(older_than_days: older_than, dry_run: dry_run)
      else
        do_list
      end
    end

    def do_list
      entries = Samagotchi::MemoryBundle::Trash.entries
      if entries.empty?
        @stdout.puts "The bundle trash is empty."
        return 0
      end

      entries.each do |e|
        @stdout.puts "  #{e.name}  #{e.files} file#{"s" unless e.files == 1}  #{format_bytes(e.bytes)}  #{format_age(e.time)}"
      end
      @stdout.puts "\nEmpty it with: chi bundle trash --empty [--older-than DAYS]"
      0
    end

    def do_empty(older_than_days:, dry_run:)
      entries = Samagotchi::MemoryBundle::Trash.empty!(
        older_than_days: older_than_days,
        dry_run: dry_run
      )
      if entries.empty?
        @stdout.puts "The bundle trash is empty."
        return 0
      end

      total_files = entries.sum(&:files)
      if dry_run
        entries.each do |e|
          @stdout.puts "Would delete: #{e.name} (#{e.files} file#{"s" unless e.files == 1}, #{format_bytes(e.bytes)})"
        end
        @stdout.puts "\n(dry-run: #{entries.size} folder#{"s" unless entries.size == 1}, #{total_files} file#{"s" unless total_files == 1})"
      else
        @stdout.puts "Deleted #{entries.size} folder#{"s" unless entries.size == 1} (#{total_files} file#{"s" unless total_files == 1}) from the trash."
      end
      0
    end

    # Format bytes as human-readable (B, KB, MB with one decimal)
    def format_bytes(bytes)
      return "0 B" if bytes == 0

      if bytes < 1024
        "#{bytes} B"
      elsif bytes < 1_048_576
        "#{(bytes / 1024.0).round(1)} KB"
      else
        "#{(bytes / 1_048_576.0).round(1)} MB"
      end
    end

    # Format age as "just now", "N minutes ago", "N hours ago", "N days ago"
    def format_age(time)
      now = Time.now
      diff = now - time
      if diff < 60
        "just now"
      elsif diff < 3600
        "#{(diff / 60).to_i} minutes ago"
      elsif diff < 86_400
        "#{(diff / 3600).to_i} hours ago"
      else
        "#{(diff / 86_400).to_i} days ago"
      end
    end

    def new_bundle(rest)
      parsed = parse_flags(NEW_FLAGS, rest, "new", help: NEW_HELP)
      return parsed if parsed.is_a?(Integer)

      unless parsed.args.size == 1
        @stderr.puts NEW_HELP.lines.first
        return CLI::Exit::USAGE
      end
      require_relative "bundle_command/scaffold"
      scaffold = Scaffold.new(parsed.args.first, parent: parsed.options.fetch(:dir, "."))
      begin
        written = scaffold.write
      rescue ArgumentError => e
        @stderr.puts "chi bundle new: #{e.message}"
        return CLI::Exit::FAILED
      end
      shown = scaffold.dir.start_with?("#{Dir.pwd}/") ? scaffold.dir.delete_prefix("#{Dir.pwd}/") : scaffold.dir
      @stdout.puts "Created #{shown}/: #{written.join(", ")}"
      @stdout.puts <<~TEXT
        Next: cd #{shown}, edit plugin.rb and the test, then
          chi bundle test           its tests, on chi's Ruby and lib
          chi bundle check --fix    shas, requires_chi, an install and load in a sandbox
          chi bundle install .      then a new session loads it
      TEXT
      CLI::Exit::OK
    end

    # ARGS after "--" go to the test runner untouched.
    def test_bundle(rest)
      split = rest.index("--")
      own, args = split ? [rest[0...split], rest[(split + 1)..]] : [rest, []]
      parsed = parse_flags(TEST_FLAGS, own, "test", help: TEST_HELP)
      return parsed if parsed.is_a?(Integer)

      dir = parsed.args.first || "."
      unless parsed.args.size <= 1 && File.directory?(dir)
        @stderr.puts parsed.args.size > 1 ? TEST_HELP.lines.first : "chi bundle test: #{dir} isn't a folder"
        return CLI::Exit::USAGE
      end
      require_relative "bundle_command/test_run"
      TestRun.new(dir, args: args, stdout: @stdout, stderr: @stderr).run
    end

    def check(rest)
      parsed = parse_flags(CHECK_FLAGS, rest, "check", help: CHECK_HELP)
      return parsed if parsed.is_a?(Integer)

      settings = check_settings(parsed.options.fetch(:set, []), label: "check") or return CLI::Exit::USAGE
      if parsed.args.size > 1
        @stderr.puts "chi bundle check takes one PATH (#{parsed.args.join(" ")})"
        return CLI::Exit::USAGE
      end
      dir = parsed.args.first || "."
      unless File.directory?(dir)
        @stderr.puts "chi bundle check: #{dir} isn't a folder"
        return CLI::Exit::USAGE
      end
      require_relative "bundle_command/check"
      Check.new(dir, fix: parsed.options.fetch(:fix, false), settings: settings, stdout: @stdout).run
    end

    def try_bundle(rest)
      parsed = parse_flags(TRY_FLAGS, rest, "try", help: TRY_HELP)
      return parsed if parsed.is_a?(Integer)

      options = parsed.options
      if options[:prompt].nil? || parsed.args.size != 1
        @stderr.puts "Usage: chi bundle try PATH -p TEXT [options]"
        return CLI::Exit::USAGE
      end
      path = parsed.args.first
      unless File.directory?(path)
        @stderr.puts "chi bundle try: #{path} isn't a folder"
        return CLI::Exit::USAGE
      end
      if options.values_at(:model, :toolkit, :thinking, :memory, :mute).flatten.compact.any?(&:empty?)
        @stderr.puts "chi bundle try: model, toolkit, thinking, memory and mute values cannot be empty"
        return CLI::Exit::USAGE
      end
      require_relative "thinking"
      if options[:thinking] && !Thinking::LEVELS.map(&:to_s).include?(options[:thinking])
        @stderr.puts "chi bundle try: --thinking takes #{Thinking::LEVELS.join(", ")}, not #{options[:thinking]}"
        return CLI::Exit::USAGE
      end

      timeout = parse_try_timeout(options[:timeout])
      return CLI::Exit::USAGE unless timeout

      set_pairs = []
      cost_cap = 1
      cost_cap_override = false
      require_relative "bundle_session_settings"
      Array(options[:set]).each do |pair|
        key, sep, value = pair.partition("=")
        if sep.empty?
          @stderr.puts "chi bundle try: --set takes KEY=VALUE, not #{pair}"
          return CLI::Exit::USAGE
        end
        if key == "cost-cap.cap"
          cost_cap = BundleSessionSettings.typed(value)
          cost_cap_override = true
          unless (cost_cap.is_a?(Numeric) && cost_cap >= 0) || cost_cap == false
            @stderr.puts "chi bundle try: --set cost-cap.cap takes a non-negative number or off"
            return CLI::Exit::USAGE
          end
        else
          set_pairs << pair
        end
      end
      settings = check_settings(set_pairs, label: "try")
      return CLI::Exit::USAGE unless settings

      require_relative "bundle_command/try/sandbox"
      require_relative "bundle_command/try/run"
      require_relative "bundle_command/try/trace"
      sandbox = nil
      begin
        sandbox = Try::Sandbox.new(path, bundle_settings: settings, cost_cap: cost_cap,
                                   cost_cap_override: cost_cap_override)
        sandbox.install
        result = Try::Run.new(sandbox).run(prompt: options[:prompt], options: options, timeout: timeout)
        trace = Try::TraceReader.new(state_home: sandbox.state_home, session_id: result.session_id)
                              .read(exit_code: result.exit_status, answer: result.stdout, stderr: result.stderr,
                                    sandbox: options[:keep] ? sandbox.root : nil, timed_out: result.timed_out)
        render_try_trace(trace, json: options[:json], child_stderr: result.stderr)
        @stderr.puts "chi bundle try: timed out after #{timeout} seconds" if result.timed_out
        result.exit_status
      rescue Try::Sandbox::Error => e
        @stderr.puts e.message
        e.status
      ensure
        report_try_sandbox(sandbox) if options[:keep] && sandbox
        sandbox&.cleanup unless options[:keep]
      end
    end

    def render_try_trace(trace, json:, child_stderr:)
      error_lines = child_stderr.lines.reject { |line| line.start_with?("Session: ") }
      @stderr.write(error_lines.join)
      if json
        render_trace_lines(trace, @stderr, include_answer: false)
        @stdout.puts JSON.generate(trace.to_h.transform_keys(&:to_s))
      else
        render_trace_lines(trace, @stdout, include_answer: true)
      end
    end

    def report_try_sandbox(sandbox)
      @stderr.puts "sandbox: #{sandbox.root}"
      @stderr.puts "debug log: #{File.join(sandbox.state_home, "samagotchi", "samagotchi.log")}"
    end

    def render_trace_lines(trace, output, include_answer:)
      output.puts "tools:"
      trace.tools.each do |tool|
        output.puts format("  %d %-16s %-7s %dms  %s", tool[:index], tool[:name], tool[:status],
                           tool[:duration_ms], JSON.generate(tool[:args].to_s[0, 60]))
      end
      trace.notices.each { |notice| output.puts "notices: [#{notice["hook"] || "hook"}] #{notice["text"]}" }
      trace.cards.each do |card|
        output.puts "card: #{[card["title"], card["body"]].compact.join(" — ")}"
      end
      trace.questions.each do |entry|
        question = entry.dig("pending_question", "question").to_s
        outcome = if entry["cancelled"] && entry["reason"] == "non_interactive"
                    "unanswerable (non_interactive)"
                  elsif entry["cancelled"]
                    "cancelled (#{entry["reason"]})"
                  elsif entry["answer"]
                    "answered"
                  else
                    "unanswered"
                  end
        output.puts "questions: #{JSON.generate(question)} -> #{outcome}"
      end
      if trace.interactive_blocked
        count = trace.denied.size + trace.questions.count { |question| question["cancelled"] && question["reason"] == "non_interactive" }
        output.puts "warn: #{count} question(s)/call(s) couldn't be answered"
      end
      if include_answer
        answer_lines = trace.answer.lines
        output.puts "answer:"
        answer_lines.first(10).each { |line| output.puts "  #{line.chomp}" }
        output.puts "  … (truncated)" if answer_lines.size > 10
      end
      tokens = trace.tokens
      prompt = tokens[:prompt] || "unknown"
      completion = tokens[:completion] || "unknown"
      cost = if trace.cost
               "#{"~" if trace.cost_is_estimate}$#{format("%.4f", trace.cost)}"
             else
               "unknown"
             end
      output.puts "tokens: #{prompt} in / #{completion} out  cost #{cost}  exit #{trace.exit_code}" \
                  "#{"  (#{trace.session_id})" if trace.session_id}"
    end

    def parse_try_timeout(value)
      return 300 unless value

      timeout = Float(value)
      return timeout if timeout.positive? && timeout.finite?

      @stderr.puts "chi bundle try: --timeout must be a positive number"
      nil
    rescue ArgumentError
      @stderr.puts "chi bundle try: --timeout must be a positive number"
      nil
    end

    # --set KEY=VALUE values as typed (BundleSessionSettings.typed), or nil
    # after saying what's wrong.
    def check_settings(pairs, label:)
      require_relative "bundle_session_settings"
      pairs.each_with_object({}) do |pair, out|
        key, sep, value = pair.partition("=")
        unless !sep.empty? && key.match?(BundleSessionSettings::KEY)
          @stderr.puts "chi bundle #{label}: --set takes KEY=VALUE, not #{pair}"
          return nil
        end
        out[key] = BundleSessionSettings.typed(value)
      end
    end

    # +rest+ through +flags+, stopping at the first --help or error.
    #
    # @return [CLI::Flags::Result, Integer] the result, or the exit status
    #   after the help or an unknown flag (a value flag without its value
    #   reads as one)
    def parse_flags(flags, rest, sub, help:)
      parsed = flags.parse(rest)
      if parsed.help
        @stdout.puts help
        return 0
      end
      if parsed.error
        @stderr.puts "Unknown bundle #{sub} flag: #{parsed.error.arg}"
        return CLI::Exit::USAGE
      end
      parsed
    end

    # The source as given: a git URL as is, a shipped bundle's name as its
    # dir, anything else as an expanded path.
    def expand_source(src)
      return src if Samagotchi::MemoryBundle::SourceNormalizer.git_url?(src)

      Samagotchi::MemoryBundle::SourceNormalizer.shipped_bundle_dir(src) || File.expand_path(src)
    end

    def build_conflict_prompt(bundle_name, conflicts, expanded_source)
      lines = []
      lines << "Memory bundle upgrade has conflicts that need interactive resolution."
      lines << "Bundle: #{bundle_name}"
      lines << "Source: #{expanded_source}"
      lines << "Conflicts (#{conflicts.size} file(s)):"
      conflicts.each do |file_key, info|
        lines << "  - #{file_key}"
        lines << "    base:     #{info[:base]} (provenance snapshot)"
        lines << "    current:  #{info[:current]} (on-disk, has local edits)"
        lines << "    incoming: #{info[:incoming]} (new bundle version)"
        begin
          if File.exist?(info[:current]) && File.exist?(info[:incoming])
            _base_content = File.exist?(info[:base]) ? File.read(info[:base]) : ""
            cur = File.read(info[:current])
            inc = File.read(info[:incoming])
            lines << "    --- current vs incoming preview ---"
            # simple line diff preview (first 40 lines)
            cur_lines = cur.lines
            inc_lines = inc.lines
            max = [cur_lines.size, inc_lines.size].max
            preview = []
            max.times do |i|
              break if preview.size >= 30

              c = cur_lines[i]
              n = inc_lines[i]
              if c != n
                preview << "- #{c.chomp}" if c
                preview << "+ #{n.chomp}" if n
              end
            end
            lines.concat(preview)
            lines << "    --- end preview ---"
          end
        rescue StandardError
          # No preview for a file that can't be read: the diff lines stand alone.
        end
      end
      lines << ""
      lines << "Your task: resolve each conflict by editing the file in place using the memory_write tool."
      lines << "Use memory_read to inspect current content if needed. The correct scope for memory_write is the bundle's scope."
      lines << "When all conflicts are resolved, type /exit to finish. If you stop early, the files stay as they are (the rest of the upgrade is already applied)."
      lines.join("\n")
    end
  end
end
