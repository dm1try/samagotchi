# frozen_string_literal: true

require_relative "memory_bundle"

module Samagotchi
  # `chi bundle`: install, upgrade, uninstall, status, diff, list and build
  # memory bundles (bin/chi dispatches here before OptionParser; the
  # subcommands have their own flags).
  class BundleCommand
    USAGE = <<~TEXT
      Usage: chi bundle <install|upgrade|uninstall|status|diff|list|build> [options]

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
          FILES... optional allowlist of *.md basenames to include (default: all).
    TEXT

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
      when "install"
        rest = @argv[1..]
        source = nil
        scope = nil
        force = false
        i = 0
        while i < rest.size
          arg = rest[i]
          if arg.start_with?("--")
            nxt = rest[i + 1]
            if %w[-h --help help].include?(arg)
              @stdout.puts "Usage: chi bundle install <source> [--scope system|project] [--force]"
              @stdout.puts ""
              @stdout.puts "  install <source> [--scope system|project] [--force]"
              @stdout.puts "    Install a memory bundle from a directory, zip, tar archive, or git URL,"
              @stdout.puts "    or a bundle shipped with chi by name (see: chi bundle list)."
              @stdout.puts "    --force overwrites existing entries; default skips them."
              return 0
            elsif arg == "--scope" && nxt
              scope = nxt
              i += 2
            elsif arg.start_with?("--scope=")
              scope = arg.split("=", 2).last
              i += 1
            elsif arg == "--force"
              force = true
              i += 1
            else
              @stderr.puts "Unknown bundle install flag: #{arg}"
              return 1
            end
          else
            source = arg
            i += 1
          end
        end
        if source.nil? || source.empty?
              @stderr.puts "Usage: chi bundle install <source> [--scope system|project] [--force]"
          return 1
        end
        expanded_source = chi_expand_source(source)
        bundle_name = chi_bundle_name_for(expanded_source)
        installer = Samagotchi::MemoryBundle::Installer.new(
          source: expanded_source,
          name: bundle_name,
          scope: scope,
          force: force,
          strict: true
        )
        begin
          _nd, manifest = installer.run
          @stdout.puts installer.summary
          if manifest && manifest.hooks && !manifest.hooks.empty?
            hook_cnt = manifest.hooks.size
            @stdout.puts "Hooks: #{hook_cnt} hook(s) (#{manifest.hooks.keys.join(', ')})"
          end
          @stdout.puts "Plugin: #{manifest.plugin[:file]} (loads at the next chi start)" if manifest&.plugin
          @stdout.puts "Provenance written to: #{Samagotchi::MemoryBundle::Provenance.bundles_dir}/#{bundle_name}/" if manifest
          return 0
        rescue Samagotchi::MemoryBundle::Installer::InstallError => e
          @stderr.puts "Install failed: #{e.message}"
          return 1
        end

      when "upgrade"
        rest = @argv[1..]
        source = nil
        scope = nil
        force = false
        dry_run = false
        agent = nil
        i = 0
        while i < rest.size
          arg = rest[i]
          if arg.start_with?("--")
            nxt = rest[i + 1]
            if %w[-h --help help].include?(arg)
              @stdout.puts "Usage: chi bundle upgrade <source> [--scope system|project] [--force] [--dry-run] [--agent|--no-agent]"
              return 0
            elsif arg == "--scope" && nxt
              scope = nxt; i += 2
            elsif arg.start_with?("--scope=")
              scope = arg.split("=", 2).last; i += 1
            elsif arg == "--force"
              force = true; i += 1
            elsif arg == "--dry-run"
              dry_run = true; i += 1
            elsif arg == "--agent"
              agent = true; i += 1
            elsif arg == "--no-agent"
              agent = false; i += 1
            else
              @stderr.puts "Unknown bundle upgrade flag: #{arg}"
              return 1
            end
          else
            source = arg; i += 1
          end
        end
        if source.nil? || source.empty?
              @stderr.puts "Usage: chi bundle upgrade <source> [--scope system|project] [--force] [--dry-run]"
          return 1
        end
        expanded_source = chi_expand_source(source)
        bundle_name = chi_bundle_name_for(expanded_source)
        provenance = Samagotchi::MemoryBundle::Provenance.new(name: bundle_name)
        unless provenance.installed?
          @stderr.puts "Bundle '#{bundle_name}' not installed — falling back to install"
          installer = Samagotchi::MemoryBundle::Installer.new(source: expanded_source, name: bundle_name, scope: scope, force: force, strict: true)
          begin
            _nd, manifest = installer.run
            @stdout.puts installer.summary
            @stdout.puts "Provenance written to: #{Samagotchi::MemoryBundle::Provenance.bundles_dir}/#{bundle_name}/" if manifest
            return 0
          rescue Samagotchi::MemoryBundle::Installer::InstallError => e
            @stderr.puts "Install failed: #{e.message}"; return 1
          end
        end
        installer = Samagotchi::MemoryBundle::Installer.new(
          source: expanded_source,
          name: bundle_name,
          scope: scope,
          force: force,
          strict: true,
          upgrade: true,
          dry_run: dry_run
        )
        begin
          _nd, manifest = installer.run
          @stdout.puts installer.summary
          if manifest && manifest.hooks && !manifest.hooks.empty?
            @stdout.puts "Hooks: #{manifest.hooks.size} hook(s) (#{manifest.hooks.keys.join(', ')})"
          end
          @stdout.puts "Plugin: #{manifest.plugin[:file]} (loads at the next chi start)" if manifest&.plugin && !dry_run
          if dry_run
            @stdout.puts "(dry-run: no changes written)" 
            return 0
          end
          if installer.conflicts.any? && !force
            @stdout.puts "\n#{installer.conflicts.size} conflict(s) need resolution."
            installer.conflicts.each { |k, _| @stdout.puts "  conflict: #{k}" }
            # Decide whether to launch agent
            launch = false
            if agent == false
              launch = false
            elsif agent == true
              launch = true
            elsif @stdin.tty?
              @stdout.print "Conflicts detected — launch interactive agent to resolve? [y/N] "
              ans = begin; @stdin.gets; rescue => _e; nil; end
              launch = ans && ans.strip.downcase.start_with?("y")
            else
              @stdout.puts "Non-interactive terminal: kept your edits in the file(s) above; the rest is upgraded. Re-run with --force to take the bundle's version, or --agent in a TTY to merge."
              return 2
            end
            if launch
              prompt = chi_build_conflict_prompt(bundle_name, installer.conflicts, expanded_source)
              @stdout.puts "Launching interactive session for conflict resolution… (/exit when done)"
              require "samagotchi/terminal_ui"
              Samagotchi::TerminalUI.new(prompt: prompt).run
              # The installer already recorded the upgrade (conflicted files
              # kept their old base); the resolved files now start from the
              # bundle's version.
              Samagotchi::MemoryBundle::Provenance.new(name: bundle_name).resolve_conflicts(installer.conflicts)
              @stdout.puts "Provenance updated after interactive resolution."
              @stdout.puts "Upgrade resolved interactively."
              return 0
            else
              @stdout.puts "Kept your edits in the file(s) above; the rest is upgraded. chi bundle diff #{bundle_name} FILE shows the base; re-run with --force to take the bundle's version."
              return 2
            end
          end
          @stdout.puts "Provenance written to: #{Samagotchi::MemoryBundle::Provenance.bundles_dir}/#{bundle_name}/" if manifest
          return 0
        rescue Samagotchi::MemoryBundle::Installer::InstallError => e
          @stderr.puts "Upgrade failed: #{e.message}"; return 1
        end

      when "uninstall"
        rest = @argv[1..]
        bundle_name = nil
        scope = nil
        force = false
        i = 0
        while i < rest.size
          arg = rest[i]
          if arg.start_with?("--")
            nxt = rest[i + 1]
            if %w[-h --help help].include?(arg)
              @stdout.puts "Usage: chi bundle uninstall <bundle> [--scope system|project] [--force]"
              return 0
            elsif arg == "--scope" && nxt
              scope = nxt; i += 2
            elsif arg.start_with?("--scope=")
              scope = arg.split("=", 2).last; i += 1
            elsif arg == "--force"
              force = true; i += 1
            else
              @stderr.puts "Unknown bundle uninstall flag: #{arg}"; return 1
            end
          else
            bundle_name = arg; i += 1
          end
        end
        if bundle_name.nil? || bundle_name.empty?
              @stderr.puts "Usage: chi bundle uninstall <bundle> [--scope system|project] [--force]"
          return 1
        end
        # Propagate overrides
        Samagotchi::MemoryBundle::Uninstaller.system_dir_override = Samagotchi::MemoryBundle::Installer.system_dir_override
        Samagotchi::MemoryBundle::Uninstaller.project_dir_base_override = Samagotchi::MemoryBundle::Installer.project_dir_base_override
        uninstaller = Samagotchi::MemoryBundle::Uninstaller.new(name: bundle_name, scope: scope, force: force)
        begin
          uninstaller.run
          @stdout.puts "Uninstalled bundle '#{bundle_name}'"
          @stdout.puts "Removed: #{uninstaller.removed_files.join(', ')}" unless uninstaller.removed_files.empty?
          hook_removed = uninstaller.removed_files.count { |f| f.start_with?("hooks/") }
          @stdout.puts "Hooks removed: #{hook_removed}" if hook_removed > 0
          uninstaller.warnings.each { |w| @stdout.puts w }
          return 0
        rescue Samagotchi::MemoryBundle::Uninstaller::UninstallError => e
          @stderr.puts "Uninstall failed: #{e.message}"; return 1
        end

      when "status"
        rest = @argv[1..]
        name = rest.find { |a| !a.start_with?("--") }
        require "json"
        if name
          st = Samagotchi::MemoryBundle::Status.bundle_status(name)
          unless st
            @stdout.puts "Bundle '#{name}' not installed."
            return 0
          end
          @stdout.puts "Bundle: #{name} v#{st[:provenance][:version]} scope=#{st[:scope]} installed=#{st[:provenance][:installed_at]}"
          @stdout.puts "Target: #{st[:target_dir]}"
          st[:files].each do |k, info|
            mods = []
            mods << "conflict (kept your edits over v#{st[:provenance][:version]}: chi bundle diff #{name} #{k})" if info[:conflict]
            mods << "modified" if info[:modified]
            mods << "missing" if info[:missing]
            mods << "no-index" unless info[:index_present]
            label = mods.empty? ? "ok" : mods.join(",")
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
          end
          if (plugin = st[:plugin])
            note = plugin[:state] == "modified" ? " (edited after install: not loaded; reinstall the bundle)" : ""
            @stdout.puts "  Plugin: #{plugin[:file]} [#{plugin[:state]}]#{note}"
            @stdout.puts "    requires_chi: #{plugin[:requires_chi]}" if plugin[:requires_chi]
            @stdout.puts "    not loaded: #{plugin[:requires_failure]}" if plugin[:requires_failure]
          end
          st[:needs].each { |need| @stdout.puts "  #{Samagotchi::MemoryBundle::Status.need_line(need)}" }
        else
          bundles_dir = Samagotchi::MemoryBundle::Provenance.bundles_dir
          unless File.directory?(bundles_dir)
            @stdout.puts "No installed bundles."; return 0
          end
          entries = Dir.entries(bundles_dir).reject { |e| e.start_with?(".") }
          if entries.empty?
            @stdout.puts "No installed bundles."
          else
            entries.sort.each do |bname|
              st = Samagotchi::MemoryBundle::Status.bundle_status(bname)
              next unless st
              mods = st[:files].values.count { |v| v[:modified] || v[:missing] }
              hooks_count = (st[:provenance][:hooks] || {}).size
              hook_info = hooks_count > 0 ? " hooks=#{hooks_count}" : ""
              plugin = st[:plugin]
              mods += 1 if plugin && (plugin[:state] != "ok" || plugin[:requires_failure])
              plugin_info = plugin ? " plugin=#{plugin[:file]}" : ""
              @stdout.puts "  #{bname} v#{st[:provenance][:version]} scope=#{st[:scope]} files=#{st[:files].size}#{hook_info}#{plugin_info} issues=#{mods}"
            end
          end
        end
        return 0

      when "diff"
        rest = @argv[1..]
        args = rest.reject { |a| a.start_with?("--") }
        bname = args[0]
        file_arg = args[1]
        if bname.nil? || bname.empty?
              @stderr.puts "Usage: chi bundle diff <bundle> [file]"; return 1
        end
        prov = Samagotchi::MemoryBundle::Provenance.new(name: bname)
        data = prov.read
        unless data
          @stderr.puts "Bundle '#{bname}' not installed"; return 1
        end
        scope = data[:scope]&.to_s || "system"
        target_dir = Samagotchi::MemoryBundle::Installer.new(source: ".", name: bname, scope: scope).send(:resolve_target_dir, scope)
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

      when "list"
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
            line = "  #{b.name.ljust(name_w)}  #{"v#{b.version || "?"}".ljust(ver_w)}  scope=#{b.scope || "?"}  files=#{b.files}  installed=#{b.installed_at || "?"}"
            line += "  (shipped v#{b.upgrade.version}: chi bundle upgrade #{b.upgrade.source})" if b.upgrade
            @stdout.puts line
          end
          @stdout.puts "  (or all at once: chi update)" if installed.any?(&:upgrade)
        end
        unless available.empty?
          @stdout.puts ""
          @stdout.puts "Available (shipped with chi, install with: chi bundle install <name>):"
          available.each do |s|
            @stdout.puts "  #{s.source.ljust(name_w)}  #{"v#{s.version}".ljust(ver_w)}  #{s.description}".rstrip
          end
        end
        return 0

      when "build"
        rest = @argv[1..]
        scope = nil
        name = nil
        version = nil
        description = ""
        out = nil
        filter_files = []
        i = 0
        while i < rest.size
          arg = rest[i]
          if arg.start_with?("--")
            nxt = rest[i + 1]
            if %w[-h --help help].include?(arg)
              @stdout.puts "Usage: chi bundle build [--scope system|project] [--name NAME] [--version VER] [--description DESC] [--out PATH] [FILES...]"
              @stdout.puts ""
              @stdout.puts "  build [--scope system|project] [--name NAME] [--version VER] [--description DESC] [--out PATH] [FILES...]"
              @stdout.puts "    Build local memories and installed hooks into a shareable bundle (dir or zip)."
              @stdout.puts "    --scope selects source dir (default: system). --out inferred from extension; default <name>.zip."
              @stdout.puts "    FILES... optional allowlist of *.md basenames to include (default: all)."
              @stdout.puts ""
              @stdout.puts "  Examples:"
              @stdout.puts "    chi bundle build --scope system"
              @stdout.puts "    chi bundle build --scope project --name my-bundle --version 1.0.0 --out bundle.zip"
              @stdout.puts "    chi bundle build --scope system --out ./my-bundle/ identity.md work.md"
              return 0
            elsif arg == "--scope" && nxt && !nxt.start_with?("--")
              scope = nxt; i += 2
            elsif arg.start_with?("--scope=")
              scope = arg.split("=", 2).last; i += 1
            elsif arg == "--name" && nxt && !nxt.start_with?("--")
              name = nxt; i += 2
            elsif arg.start_with?("--name=")
              name = arg.split("=", 2).last; i += 1
            elsif arg == "--version" && nxt && !nxt.start_with?("--")
              version = nxt; i += 2
            elsif arg.start_with?("--version=")
              version = arg.split("=", 2).last; i += 1
            elsif arg == "--description" && nxt && !nxt.start_with?("--")
              description = nxt; i += 2
            elsif arg.start_with?("--description=")
              description = arg.split("=", 2).last; i += 1
            elsif arg == "--out" && nxt && !nxt.start_with?("--")
              out = nxt; i += 2
            elsif arg.start_with?("--out=")
              out = arg.split("=", 2).last; i += 1
            else
              @stderr.puts "Unknown bundle build flag: #{arg}"
              return 1
            end
          else
            filter_files << arg
            i += 1
          end
        end
        # Validate scope if given
        if scope && !%w[system project].include?(scope.to_s.strip.downcase)
          @stderr.puts "Invalid scope '#{scope}', expected system or project"
          return 1
        end
        filter_files = nil if filter_files.empty?
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
          unless result[:placeholder_warnings].empty?
            @stdout.puts "Placeholders:"
            result[:placeholder_warnings].each { |w| @stdout.puts "  #{w}" }
          end
          return 0
        rescue Samagotchi::MemoryBundle::Builder::BuildError => e
          @stderr.puts "Build failed: #{e.message}"
          return 1
        end

      else
        @stderr.puts "Unknown bundle subcommand: #{sub}. Use: install, upgrade, uninstall, status, diff, list, build"
        return 1
      end
    end

    private

    # helpers for bundle_name derivation
    def chi_expand_source(src)
      return src if Samagotchi::MemoryBundle::SourceNormalizer.git_url?(src)
      Samagotchi::MemoryBundle::SourceNormalizer.shipped_bundle_dir(src) || File.expand_path(src)
    end

    def chi_bundle_name_for(expanded_src)
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

    def chi_build_conflict_prompt(bundle_name, conflicts, expanded_source)
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
