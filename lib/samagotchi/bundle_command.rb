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
      Usage: chi bundle <install|upgrade|uninstall|status|diff|list|build|trash> [options]

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
          FILES... optional allowlist of *.md basenames to include (default: all but installed bundles' ones).

        trash [--empty] [--dry-run] [--older-than DAYS]
          List bundle trash (moved files from uninstalls/upgrades).
          --empty deletes all trash folders. --older-than DAYS keeps only recent ones.
    TEXT

    # Each subcommand's --help (and only --help: -h and help are taken as
    # the source or name).
    INSTALL_HELP = <<~TEXT
      Usage: chi bundle install <source> [--scope system|project] [--force]

        install <source> [--scope system|project] [--force]
          Install a memory bundle from a directory, zip, tar archive, or git URL,
          or a bundle shipped with chi by name (see: chi bundle list).
          --force overwrites existing entries; default skips them.
    TEXT
    UPGRADE_HELP = "Usage: chi bundle upgrade <source> [--scope system|project] [--force] [--dry-run] [--agent|--no-agent]"
    UNINSTALL_HELP = "Usage: chi bundle uninstall <bundle> [--scope system|project] [--force]"
    BUILD_HELP = <<~TEXT
      Usage: chi bundle build [--scope system|project] [--name NAME] [--version VER] [--description DESC] [--out PATH] [FILES...]

        build [--scope system|project] [--name NAME] [--version VER] [--description DESC] [--out PATH] [FILES...]
          Build local memories and installed hooks into a shareable bundle (dir or zip).
          --scope selects source dir (default: system). --out inferred from extension; default <name>.zip.
          FILES... optional allowlist of *.md basenames to include (default: all but installed bundles' ones).

        Examples:
          chi bundle build --scope system
          chi bundle build --scope project --name my-bundle --version 1.0.0 --out bundle.zip
          chi bundle build --scope system --out ./my-bundle/ identity.md work.md
    TEXT
    TRASH_HELP = "Usage: chi bundle trash [--empty] [--dry-run] [--older-than DAYS]"

    # The subcommands' flags: --help only; a word not starting with -- is
    # a positional (install's source, -h included). --scope takes whatever
    # follows it; build's value flags not a --flag.
    INSTALL_FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A--/) do |f|
      f.value "--scope"
      f.switch "--force"
    end
    UNINSTALL_FLAGS = INSTALL_FLAGS
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
      else
        @stderr.puts "Unknown bundle subcommand: #{sub}. Use: install, upgrade, uninstall, status, diff, list, build, trash"
        return CLI::Exit::USAGE
      end
    end

    private

    def install(rest)
      parsed = parse_flags(INSTALL_FLAGS, rest, "install", help: INSTALL_HELP)
      return parsed if parsed.is_a?(Integer)

      opts, source = parsed.options, parsed.args.last
      scope = opts[:scope]
      force = opts.fetch(:force, false)
      if source.nil? || source.empty?
        @stderr.puts "Usage: chi bundle install <source> [--scope system|project] [--force]"
        return CLI::Exit::USAGE
      end
      expanded_source = expand_source(source)
      if Samagotchi::MemoryBundle::Profile.shipped_meta?(expanded_source)
        return install_profile(expanded_source, scope: scope, force: force, dry_run: false, word: "Install")
      end
      bundle_name = bundle_name_or_fail(expanded_source, "Install") or return 1
      run_installer(installer_for(expanded_source, bundle_name, scope: scope, force: force), failed: "Install") do |manifest|
        print_hooks_and_plugin(manifest)
        print_provenance(bundle_name, manifest)
      end
    end

    def upgrade(rest)
      parsed = parse_flags(UPGRADE_FLAGS, rest, "upgrade", help: UPGRADE_HELP)
      return parsed if parsed.is_a?(Integer)

      opts, source = parsed.options, parsed.args.last
      scope = opts[:scope]
      force = opts.fetch(:force, false)
      dry_run = opts.fetch(:dry_run, false)
      agent = opts[:agent]
      if source.nil? || source.empty?
        @stderr.puts "Usage: chi bundle upgrade <source> [--scope system|project] [--force] [--dry-run]"
        return CLI::Exit::USAGE
      end
      expanded_source = expand_source(source)
      if Samagotchi::MemoryBundle::Profile.shipped_meta?(expanded_source)
        return install_profile(expanded_source, scope: scope, force: force, dry_run: dry_run, word: "Upgrade")
      end
      bundle_name = bundle_name_or_fail(expanded_source, "Upgrade") or return 1
      unless Samagotchi::MemoryBundle::Provenance.new(name: bundle_name).installed?
        @stderr.puts "Bundle '#{bundle_name}' not installed — falling back to install"
        # (no Hooks/Plugin lines here)
        installer = installer_for(expanded_source, bundle_name, scope: scope, force: force, dry_run: dry_run)
        return run_installer(installer, failed: "Install") do |manifest|
          next dry_run_done if dry_run

          print_provenance(bundle_name, manifest)
        end
      end
      installer = installer_for(expanded_source, bundle_name, scope: scope, force: force, upgrade: true, dry_run: dry_run)
      run_installer(installer, failed: "Upgrade") do |manifest|
        print_hooks_and_plugin(manifest, plugin: !dry_run)
        next dry_run_done if dry_run
        next upgrade_conflicts(installer, bundle_name, expanded_source, agent) if installer.conflicts.any? && !force

        print_provenance(bundle_name, manifest)
      end
    end

    # The bundle's name, or nil after "<word> failed: …".
    def bundle_name_or_fail(expanded_source, word)
      bundle_name_for(expanded_source)
    rescue Samagotchi::MemoryBundle::SourceNormalizer::UnknownSourceError => e
      @stderr.puts "#{word} failed: #{e.message}"
      nil
    end

    def installer_for(source, name, scope:, force:, **options)
      Samagotchi::MemoryBundle::Installer.new(source: source, name: name, scope: scope, force: force, strict: true, **options)
    end

    # Runs +installer+, prints its summary, then yields the manifest.
    # @return [Integer] the block's exit status, or 1 after "<failed> failed: …"
    def run_installer(installer, failed:)
      _nd, manifest = installer.run
      @stdout.puts installer.summary
      yield manifest
    rescue Samagotchi::MemoryBundle::Installer::InstallError => e
      @stderr.puts "#{failed} failed: #{e.message}"
      1
    end

    def print_hooks_and_plugin(manifest, plugin: true)
      @stdout.puts "Hooks: #{manifest.hooks.size} hook(s) (#{manifest.hooks.keys.join(', ')})" if manifest&.hooks&.any?
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
                 ans = begin; @stdin.gets; rescue => _e; nil; end
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

      opts, bundle_name = parsed.options, parsed.args.last
      scope = opts[:scope]
      force = opts.fetch(:force, false)
      if bundle_name.nil? || bundle_name.empty?
        @stderr.puts "Usage: chi bundle uninstall <bundle> [--scope system|project] [--force]"
        return CLI::Exit::USAGE
      end
      data = Samagotchi::MemoryBundle::Provenance.new(name: bundle_name).read
      return uninstall_profile(bundle_name, force: force) if Samagotchi::MemoryBundle::Profile.installed_meta?(bundle_name, data)

      uninstaller = Samagotchi::MemoryBundle::Uninstaller.new(name: bundle_name, scope: scope, force: force)
      begin
        uninstaller.run
        @stdout.puts "Uninstalled bundle '#{bundle_name}'"
        puts_trashed(uninstaller.trashed_files, uninstaller.trash_dir)
        @stdout.puts "Removed: #{uninstaller.removed_files.join(', ')}" unless uninstaller.removed_files.empty?
        hook_removed = uninstaller.removed_files.count { |f| f.start_with?("hooks/") }
        @stdout.puts "Hooks removed: #{hook_removed}" if hook_removed > 0
        uninstaller.warnings.each { |w| @stdout.puts w }
        return 0
      rescue Samagotchi::MemoryBundle::Uninstaller::UninstallError => e
        @stderr.puts "Uninstall failed: #{e.message}"; return 1
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
        @stdout.puts "Bundle: #{name} v#{st[:provenance][:version]} scope=#{status_scope(st)} installed=#{st[:provenance][:installed_at]}"
        if st[:scope_error]
          @stdout.puts "Target: (unknown scope: this chi can't resolve it; upgrade chi or reinstall the bundle)"
        else
          @stdout.puts "Target: #{st[:target_dir]}"
        end
        st[:files].each do |k, info|
          next @stdout.puts("  #{k}: unchecked") if info[:unchecked]

          mods = []
          mods << "conflict (kept your edits over v#{st[:provenance][:version]}: chi bundle diff #{name} #{k})" if info[:conflict]
          mods << "modified" if info[:modified]
          mods << "missing" if info[:missing]
          mods << "no-index" unless info[:index_present] || info[:overlay]
          label = mods.empty? ? "ok" : mods.join(",")
          label += " (model overlay)" if info[:overlay]
          @stdout.puts "  #{k}: #{label}"
        end
        # Hooks
        hooks = st[:provenance][:hooks] || {}
        trust = st[:provenance][:trust_level] || "experimental"
        commit = st[:provenance][:source_commit]
        @stdout.puts "  trust_level: #{trust}" if hooks.any? || trust
        @stdout.puts "  source_commit: #{commit}" if commit
        if hooks.any?
          @stdout.puts "  Hooks (#{hooks.size}):"
          hooks.each do |hk, meta|
            m = meta.is_a?(Hash) ? meta.transform_keys(&:to_s) : {}
            event = m["event"] || ""
            on_error = m["on_error"] || "skip"
            prio = m["priority"] || 100
            hook_path = File.join(Samagotchi::MemoryBundle::Provenance.new(name: name).hooks_dir, hk.to_s)
            exists = File.exist?(hook_path) ? "ok" : "missing"
            @stdout.puts "    #{hk}: event=#{event} on_error=#{on_error} priority=#{prio} [#{exists}]"
          end
          @stdout.puts "    requires_chi: #{st[:provenance][:requires_chi]}" if st[:hooks_requires_failure]
          @stdout.puts "    not loaded: #{st[:hooks_requires_failure]}" if st[:hooks_requires_failure]
        end
        if (plugin = st[:plugin])
          note = plugin[:state] == "modified" ? " (edited after install: not loaded; reinstall the bundle)" : ""
          @stdout.puts "  Plugin: #{plugin[:file]} [#{plugin[:state]}]#{note}"
          @stdout.puts "    requires_chi: #{plugin[:requires_chi]}" if plugin[:requires_chi]
          @stdout.puts "    not loaded: #{plugin[:requires_failure]}" if plugin[:requires_failure]
        end
        st[:needs].each { |need| @stdout.puts "  #{Samagotchi::MemoryBundle::Status.need_line(need)}" }
        (st[:provenance][:includes] || []).each do |member|
          state = Samagotchi::MemoryBundle::Provenance.new(name: member.to_s).installed? ? "installed" : "not installed: chi bundle install #{member}"
          @stdout.puts "  includes #{member} [#{state}]"
        end
      else
        bundles = Samagotchi::MemoryBundle::Provenance.each_installed.to_a
        @stdout.puts "No installed bundles." if bundles.empty?
        bundles.each do |bname, data|
          next @stdout.puts("  #{bname} (manifest.json unreadable)") if data[:error]

          st = Samagotchi::MemoryBundle::Status.bundle_status(bname)
          mods = st[:files].values.count { |v| v[:modified] || v[:missing] }
          hooks_count = (st[:provenance][:hooks] || {}).size
          hook_info = hooks_count > 0 ? " hooks=#{hooks_count}" : ""
          plugin = st[:plugin]
          mods += 1 if plugin && (plugin[:state] != "ok" || plugin[:requires_failure])
          mods += 1 if st[:hooks_requires_failure]
          mods += 1 if st[:scope_error]
          plugin_info = plugin ? " plugin=#{plugin[:file]}" : ""
          includes = st[:provenance][:includes]
          includes_info = includes ? " includes=#{includes.join(",")}" : ""
          @stdout.puts "  #{bname} v#{st[:provenance][:version]} scope=#{status_scope(st)} files=#{st[:files].size}#{hook_info}#{plugin_info}#{includes_info} issues=#{mods}"
        end
      end
      return 0
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
      data = prov.read
      unless data
        @stderr.puts "Bundle '#{bname}' not installed"; return 1
      end
      scope = data[:scope]&.to_s || "system"
      begin
        target_dir = Samagotchi::MemoryPaths.scope_dir!(scope)
      rescue ArgumentError => e
        @stderr.puts "Bundle '#{bname}': #{e.message}"; return 1
      end
      files = data[:files] || {}
      hooks = data[:hooks] || {}
      plugin_path = prov.plugin_path(data)
      plugin_file = plugin_path && File.basename(plugin_path)
      show_plugin = lambda do
        @stdout.puts "=== plugin/#{plugin_file} ==="
        @stdout.puts "--- base (provenance) ---"
        base = prov.plugin_base_path(plugin_file)
        @stdout.puts File.exist?(base) ? File.read(base) : "(no base)"
        @stdout.puts "--- current (on-disk) ---"
        @stdout.puts File.exist?(plugin_path) ? File.read(plugin_path) : "(missing)"
        @stdout.puts "--- metadata: sha256=#{data[:plugin][:sha256]}#{data[:requires_chi] ? " requires_chi=#{data[:requires_chi]}" : ""}"
      end
      if file_arg
        # Try file first, then hook
        if files.key?(file_arg.to_sym) || files.key?(file_arg)
          base = prov.base_path(file_arg)
          cur = File.join(target_dir, file_arg)
          @stdout.puts "=== #{file_arg} ==="
          @stdout.puts "--- base (provenance) ---"
          @stdout.puts File.exist?(base) ? File.read(base) : "(no base)"
          @stdout.puts "--- current (on-disk) ---"
          @stdout.puts File.exist?(cur) ? File.read(cur) : "(missing)"
        elsif hooks.key?(file_arg.to_sym) || hooks.key?(file_arg)
          base = prov.base_path(file_arg)
          cur = File.join(prov.hooks_dir, file_arg)
          @stdout.puts "=== hooks/#{file_arg} ==="
          @stdout.puts "--- base (provenance) ---"
          @stdout.puts File.exist?(base) ? File.read(base) : "(no base)"
          @stdout.puts "--- current (on-disk) ---"
          @stdout.puts File.exist?(cur) ? File.read(cur) : "(missing)"
          # Show hook metadata
          meta = hooks[file_arg.to_sym] || hooks[file_arg]
          if meta
            m = meta.transform_keys(&:to_s)
            @stdout.puts "--- metadata: event=#{m['event']} on_error=#{m['on_error']} priority=#{m['priority']} sha256=#{m['sha256']}"
          end
        elsif plugin_file && [plugin_file, "plugin/#{plugin_file}"].include?(file_arg)
          show_plugin.call
        else
          @stdout.puts "=== #{file_arg} ==="
          @stdout.puts "(not found in bundle)"
        end
        @stdout.puts ""
      else
        keys = files.keys.map(&:to_s)
        keys.each do |k|
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
        hooks.keys.map(&:to_s).each do |k|
          base = prov.base_path(k)
          cur = File.join(prov.hooks_dir, k)
          @stdout.puts "=== hooks/#{k} ==="
          @stdout.puts "--- base (provenance) ---"
          @stdout.puts File.exist?(base) ? File.read(base) : "(no base)"
          @stdout.puts "--- current (on-disk) ---"
          @stdout.puts File.exist?(cur) ? File.read(cur) : "(missing)"
          meta = hooks[k.to_sym] || hooks[k]
          if meta
            m = meta.transform_keys(&:to_s)
            @stdout.puts "--- metadata: event=#{m['event']} on_error=#{m['on_error']} priority=#{m['priority']} sha256=#{m['sha256']}"
          end
          @stdout.puts ""
        end
        if plugin_file
          show_plugin.call
          @stdout.puts ""
        end
      end
      return 0
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
      return 0
    end

    # An installed profile's list cell: its recorded members still
    # installed, and the ones left out (uninstalled by the user).
    def profile_members(members, installed)
      names = installed.map(&:name)
      here, gone = members.partition { |m| names.include?(m) }
      "includes=#{here.join(",")}#{gone.empty? ? "" : "  left out=#{gone.join(",")}"}"
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
        @stdout.puts "Files: #{result[:files].join(', ')}" unless result[:files].empty?
        builder.warnings.each { |w| @stdout.puts w }
        unless result[:placeholder_warnings].empty?
          @stdout.puts "Placeholders:"
          result[:placeholder_warnings].each { |w| @stdout.puts "  #{w}" }
        end
        return 0
      rescue Samagotchi::MemoryBundle::Builder::BuildError => e
        @stderr.puts "Build failed: #{e.message}"
        return 1
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
        @stdout.puts "  #{e.name}  #{e.files} file#{'s' unless e.files == 1}  #{format_bytes(e.bytes)}  #{format_age(e.time)}"
      end
      @stdout.puts "\nEmpty it with: chi bundle trash --empty [--older-than DAYS]"
      0
    end

    def do_empty(older_than_days:, dry_run:)
      entries = Samagotchi::MemoryBundle::Trash.empty!(
        older_than_days: older_than_days,
        dry_run: dry_run,
      )
      if entries.empty?
        @stdout.puts "The bundle trash is empty."
        return 0
      end

      total_files = entries.sum(&:files)
      if dry_run
        entries.each do |e|
          @stdout.puts "Would delete: #{e.name} (#{e.files} file#{'s' unless e.files == 1}, #{format_bytes(e.bytes)})"
        end
        @stdout.puts "\n(dry-run: #{entries.size} folder#{'s' unless entries.size == 1}, #{total_files} file#{'s' unless total_files == 1})"
      else
        @stdout.puts "Deleted #{entries.size} folder#{'s' unless entries.size == 1} (#{total_files} file#{'s' unless total_files == 1}) from the trash."
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

    # helpers for bundle_name derivation
    def expand_source(src)
      return src if Samagotchi::MemoryBundle::SourceNormalizer.git_url?(src)
      Samagotchi::MemoryBundle::SourceNormalizer.shipped_bundle_dir(src) || File.expand_path(src)
    end

    def bundle_name_for(expanded_src)
      # Try to derive from manifest if possible (skip git clone for speed if possible)
      if Samagotchi::MemoryBundle::SourceNormalizer.git_url?(expanded_src)
        # For git URLs, avoid double clone: derive name from URL basename if no manifest yet
        # Let Installer do the real manifest read; fallback to URL basename
        base = expanded_src.split("/").last.to_s.split("#").first.to_s
        base = base.sub(/\.git\z/i, "")
        return base.empty? ? "bundle" : base
      end
      require "yaml"
      nd = nil
      owned = false
      begin
        nd, owned = Samagotchi::MemoryBundle::SourceNormalizer.normalize(expanded_src)
        m = Samagotchi::MemoryBundle::Manifest.read(dir: nd)
        return m.name
      rescue Samagotchi::MemoryBundle::Manifest::ValidationError
        # Fallback to source basename without archive extensions
        src = expanded_src
        name = File.basename(src)
        name = name.sub(/\.tar\.gz\z/i, "").sub(/\.tgz\z/i, "").sub(/\.zip\z/i, "").sub(/\.tar\z/i, "")
        return name.empty? ? File.basename(nd || src) : name
      ensure
        Samagotchi::MemoryBundle::SourceNormalizer.cleanup(nd) if owned
      end
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
        rescue => _e
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
