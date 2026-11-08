# frozen_string_literal: true

require "fileutils"
require_relative "file_digest"
require_relative "bundle_hook"
require_relative "manifest"
require_relative "provenance"
require_relative "../version"

module Samagotchi
  module MemoryBundle
    autoload :Installer, File.expand_path("installer", __dir__)

    # The install of a bundle's parts that live in its own dir
    # (<bundles>/<name>/, Provenance#bundle_dir) rather than in the
    # memories dir: hooks/*.rb, guardrails/*.yml, the plugin file and
    # scripts/*. Each replaces what an earlier version installed. Installer
    # runs it after the memories; it adds to the installer's results and
    # warnings, and #run returns what the record (Provenance#write) keeps.
    # A dev install (+dev+, `chi bundle install --dev`) links each file to
    # the source instead of copying it, and warns of no checksum mismatch.
    # An edited file it replaces or removes is copied to the trash first,
    # under its subfolder (Trash#copy_edit); a link never is.
    class AssetInstaller
      # What was installed: the paths Provenance#write records (each
      # empty / nil on a dry run).
      #   hooks       every hook basename the bundle ships
      #   hook_files, guardrail_files, script_files
      #               basename => installed path
      #   plugin_file the installed plugin file, nil without one
      Installed = Data.define(:hooks, :hook_files, :guardrail_files, :plugin_file, :script_files)

      # @param source_dir [String] the normalized bundle source
      # @param manifest [Manifest, nil] nil for a non-strict install without one
      # @param existing [InstalledBundle, nil] the record before this install
      # @param results, warnings, conflicts the Installer's (results and
      #   warnings are added to)
      # @param trash [Trash] the Installer's
      # @param chi_version [String] the chi this install is for (the Installer's;
      #   a caller that checks its own bundles against another version passes it)
      def initialize(name:, source_dir:, manifest:, provenance:, existing:, results:, warnings:, conflicts:, trash:,
                     force: false, strict: true, upgrade: false, dry_run: false, dev: false, chi_version: Samagotchi::VERSION)
        @name = name
        @bundle_dir = source_dir
        @manifest = manifest
        @provenance = provenance
        @existing = existing
        @results = results
        @warnings = warnings
        @conflicts = conflicts
        @trash = trash
        @force = force
        @strict = strict
        @upgrade = upgrade
        @dry_run = dry_run
        @dev = dev
        @chi_version = chi_version
      end

      # @return [Installed]
      # @raise [Installer::InstallError] the manifest names a plugin or
      #   script the bundle doesn't have
      def run
        install_hooks
        prune_dropped_hooks if (@upgrade || (@dev && @existing&.dev)) && @existing && !@dry_run
        verify_hook_checksums if @manifest && @strict && !@dev
        incoming_rules = Dir.glob(File.join(@bundle_dir, "guardrails", "*.yml")).sort
                            .reject { |src| linked_out?(src, "guardrails/#{File.basename(src)}") }
        guardrail_files = install_guardrails(incoming_rules)
        plugin_file = install_plugin
        script_files = install_scripts
        warn_hooks_requires_chi
        warn_rules_requires_chi(incoming_rules)
        Installed.new(hooks: @bundle_hooks, hook_files: @hook_files, guardrail_files: guardrail_files,
                      plugin_file: plugin_file, script_files: script_files)
      end

      # Whether the bundle file +src+ reads through a symlink: it is one, or
      # it (or its dir, hooks/ say) resolves outside +bundle_dir+. A tar,
      # zip or git repo keeps links; copying through one would install any
      # file the user can read. MemoryFiles skips linked memories the same
      # way. ShippedUpdate's plan reads it too.
      def self.linked?(src, bundle_dir)
        return true if File.symlink?(src)

        root = File.realpath(bundle_dir)
        !File.realpath(src).start_with?("#{root}/")
      rescue SystemCallError
        true
      end

      private

      # Copies the bundle's hooks/*.rb into <bundle_dir>/hooks/: the ones
      # its manifest lists, else (no hooks: in it) every hooks/*.rb, which is
      # then added to manifest.hooks with no event (the loader skips it, the
      # record keeps it). Without a manifest every hooks/*.rb is copied.
      # Sets @bundle_hooks (every hook the bundle ships) and @hook_files
      # (basename => installed path, for the record).
      def install_hooks
        @bundle_hooks = []
        @hook_files = {}
        return install_unlisted_hooks unless @manifest

        hook_entries = @manifest.hooks
        if hook_entries.empty?
          Dir.glob(File.join(@bundle_dir, "hooks", "*.rb")).each { |p| hook_entries[File.basename(p)] = BundleHook.new }
        end
        hook_entries.keys.each do |basename|
          next unless basename.is_a?(String) && !basename.empty?

          src = File.join(@bundle_dir, "hooks", basename)
          # A linked hook isn't the bundle's: not installed, counted or recorded.
          next hook_entries.delete(basename) if (File.symlink?(src) || File.exist?(src)) && linked_out?(src, "hooks/#{basename}")

          @bundle_hooks << basename
          install_hook(basename, src) if File.exist?(src)
        end
      end

      # One listed hook; an upgrade overwrites a local edit with a warning.
      def install_hook(basename, src)
        dest = File.join(@provenance.hooks_dir, basename)
        result = result_for(src, dest, updated: @upgrade && @existing)
        return @results[basename] = planned(result) if @dry_run

        prev_sha = @existing&.hooks&.dig(basename)&.sha256
        if @upgrade && File.exist?(dest) && !@force && !Provenance.recorded_sha(prev_sha).empty? && !Provenance.sha_matches?(dest, prev_sha)
          @warnings << "Hook #{basename} was locally modified; overwriting"
        end

        FileUtils.mkdir_p(@provenance.hooks_dir)
        @trash.copy_edit(dest, as: "hooks/#{basename}", recorded: prev_sha, incoming: src)
        place(src, dest)
        @results[basename] = result
        @hook_files[basename] = dest
      end

      # No manifest (a non-strict install): every hooks/*.rb is copied.
      def install_unlisted_hooks
        Dir.glob(File.join(@bundle_dir, "hooks", "*.rb")).each do |src|
          basename = File.basename(src)
          next if linked_out?(src, "hooks/#{basename}")

          @bundle_hooks << basename
          if @dry_run
            @results[basename] = Installer::FileResult.new(word: :would_install)
          else
            FileUtils.mkdir_p(@provenance.hooks_dir)
            dest = File.join(@provenance.hooks_dir, basename)
            @trash.copy_edit(dest, as: "hooks/#{basename}", recorded: @existing&.hooks&.dig(basename)&.sha256, incoming: src)
            place(src, dest)
            @results[basename] = Installer::FileResult.new(word: :installed)
            @hook_files[basename] = dest
          end
        end
      end

      # An upgrade removes the hooks the previous version shipped and this
      # one doesn't (a local file too, with a warning; a dev link silently).
      def prune_dropped_hooks
        @existing.hooks.each_key do |old_key_str|
          next if @bundle_hooks.include?(old_key_str)

          old_dest = File.join(@provenance.hooks_dir, old_key_str)
          if File.exist?(old_dest) && !@force && !File.symlink?(old_dest)
            @warnings << "Bundle no longer includes hook #{old_key_str} but local file exists — removing"
          end
          @trash.copy_edit(old_dest, as: "hooks/#{old_key_str}", recorded: @existing.hooks[old_key_str]&.sha256)
          FileUtils.rm_f(old_dest)
        end
      end

      # Strict mode: an installed hook whose sha256 differs from the one its
      # manifest declares warns (as verify_memory_checksums does).
      def verify_hook_checksums
        @bundle_hooks.each do |basename|
          next if @conflicts.key?(basename)

          warning = FileDigest.mismatch("hook #{basename}", File.join(@provenance.hooks_dir, basename),
                                        @manifest.checksum_for_hook(basename))
          @warnings << warning if warning
        end
      end

      # The bundle's guardrails/*.yml into <bundle_dir>/guardrails/: the
      # set replaces what an earlier version installed. Same bytes as
      # installed are reported up to date, not "Installed".
      # @return [Hash{String => String}] basename => installed path ({} on a dry run)
      def install_guardrails(incoming_rules)
        target = @provenance.guardrails_dir
        results = incoming_rules.to_h { |src| [src, result_for(src, File.join(target, File.basename(src)), updated: false)] }
        if @dry_run
          results.each { |src, result| @results["guardrails/#{File.basename(src)}"] = planned(result) }
          return {}
        end

        @trash.copy_edits(target, "guardrails", @existing&.guardrails, incoming_rules.to_h { |src| [File.basename(src), src] })
        FileUtils.rm_rf(target)
        return {} if incoming_rules.empty?

        FileUtils.mkdir_p(target)
        incoming_rules.to_h do |src|
          dest = File.join(target, File.basename(src))
          place(src, dest)
          @results["guardrails/#{File.basename(src)}"] = results[src]
          [File.basename(src), dest]
        end
      end

      # Copy the manifest's plugin file into the bundle's plugin/ dir,
      # warning when its sha256 differs from the declared one or this chi
      # doesn't meet requires_chi (the Engine then won't load it).
      # @return [String, nil] the installed file (nil: none, or a dry run)
      def install_plugin
        plugin = @manifest&.plugin
        unless plugin
          unless @dry_run
            @trash.copy_edits(@provenance.plugin_dir, "plugin", @existing&.plugin_shas)
            FileUtils.rm_rf(@provenance.plugin_dir)
          end
          return nil
        end

        src = File.join(@bundle_dir, plugin[:file])
        raise Installer::InstallError, "the manifest names plugin #{plugin[:file]}, which the bundle doesn't have" unless File.file?(src)
        raise Installer::InstallError, "plugin #{plugin[:file]} is a symlink (not installed)" if linked?(src)

        if (failure = Manifest.requires_chi_failure(@manifest.requires_chi, @chi_version))
          @warnings << "Plugin #{plugin[:file]} won't load: #{failure}"
        end
        dest = File.join(@provenance.plugin_dir, plugin[:file])
        result = result_for(src, dest, updated: @upgrade && @provenance.installed?)
        if @dry_run
          @results[plugin[:file]] = planned(result)
          return nil
        end

        @trash.copy_edits(@provenance.plugin_dir, "plugin", @existing&.plugin_shas, { plugin[:file] => src })
        FileUtils.rm_rf(@provenance.plugin_dir)
        FileUtils.mkdir_p(@provenance.plugin_dir)
        place(src, dest)
        @results[plugin[:file]] = result
        warning = FileDigest.mismatch("plugin #{plugin[:file]}", dest, @manifest.checksum_for_plugin) if @strict && !@dev
        @warnings << warning if warning
        dest
      end

      # The manifest's scripts, copied into <bundle_dir>/scripts/ (the
      # folder replaced: a script the new version dropped goes). A declared
      # sha256 that differs warns, as a plugin's does.
      # @return [Hash{String => String}] file name => installed path
      def install_scripts
        scripts = @manifest&.scripts || {}
        scripts.each_key do |file|
          src = File.join(@bundle_dir, "scripts", file)
          raise Installer::InstallError, "the manifest names scripts/#{file}, which the bundle doesn't have" unless File.file?(src)
          raise Installer::InstallError, "scripts/#{file} is a symlink (not installed)" if linked?(src)

          @warnings << "scripts/#{file} is not executable; chmod +x #{src}" if @dev && !File.executable?(src) && !page_only?(file)
        end
        results = scripts.keys.to_h do |file|
          [file, result_for(File.join(@bundle_dir, "scripts", file), File.join(@provenance.scripts_dir, file),
                            updated: @upgrade && @provenance.installed?)]
        end
        if @dry_run
          results.each { |file, result| @results["scripts/#{file}"] = planned(result) }
          return {}
        end

        @trash.copy_edits(@provenance.scripts_dir, "scripts", @existing&.scripts,
                          scripts.keys.to_h { |file| [file, File.join(@bundle_dir, "scripts", file)] })
        FileUtils.rm_rf(@provenance.scripts_dir)
        return {} if scripts.empty?

        FileUtils.mkdir_p(@provenance.scripts_dir)
        scripts.to_h do |file, declared|
          dest = File.join(@provenance.scripts_dir, file)
          place(File.join(@bundle_dir, "scripts", file), dest)
          @results["scripts/#{file}"] = results[file]
          FileUtils.chmod(0o755, dest) unless @dev
          warning = FileDigest.mismatch("script #{file}", dest, declared.to_s.delete_prefix("sha256:")) if @strict && !@dev
          @warnings << warning if warning
          [file, dest]
        end
      end

      # What the real run reports for +src+ over +dest+: up to date when the
      # bytes are the same, else updated (+updated+: an upgrade over an
      # install) or installed. A dry run records #planned of it, so the two
      # can't drift.
      def result_for(src, dest, updated:)
        word = if File.file?(dest) && FileUtils.identical?(src, dest) then :up_to_date
               elsif updated then :updated
               else :installed
               end
        Installer::FileResult.new(word: word)
      end

      # A dry run's word for a result: would_install, would_update, or the
      # up to date result as it is (nothing would be written).
      def planned(result)
        case result.word
        when :installed then result.with(word: :would_install)
        when :updated then result.with(word: :would_update)
        else result
        end
      end

      # A file only a block renderer's load names: the page loads it, nothing runs it.
      def page_only?(file)
        @manifest.block_renderers.any? { |renderer| renderer.load.include?(file) } &&
          @manifest.context_providers.none? { |provider| provider.cmd.include?(file) }
      end

      # Copies +src+ to +dest+, or (a dev install) links +dest+ to it. An
      # existing link goes first: a copy over it would write into the source.
      def place(src, dest)
        FileUtils.rm_f(dest) if File.symlink?(dest)
        @dev ? File.symlink(File.realpath(src), dest) : FileUtils.cp(src, dest)
      end

      # AssetInstaller.linked? for this bundle's source.
      def linked?(src) = self.class.linked?(src, @bundle_dir)

      # linked? with a "<label> is a symlink (not installed)" warning.
      def linked_out?(src, label)
        return false unless linked?(src)

        @warnings << "#{label} is a symlink (not installed)"
        true
      end

      # The hook loader skips every hook of a bundle whose requires_chi this
      # chi doesn't meet (Hooks::BundleLoader); say so at install, as
      # install_plugin does for the plugin.
      def warn_hooks_requires_chi
        return if @manifest.nil? || @bundle_hooks.empty?

        if (failure = Manifest.requires_chi_failure(@manifest.requires_chi, @chi_version))
          @warnings << "Bundle #{@name}: its hooks won't load: #{failure}"
        end
      end

      # GuardrailWiring#bundle_rules doesn't read the rules of a bundle whose
      # requires_chi this chi doesn't meet, and a session that never loaded
      # them records a required load failure (the gate refuses guarded calls
      # until chi is updated): say so at install, as the hooks warning does.
      def warn_rules_requires_chi(rule_files)
        return if @manifest.nil? || rule_files.empty?

        if (failure = Manifest.requires_chi_failure(@manifest.requires_chi, @chi_version))
          @warnings << "Bundle #{@name}: its guardrail rules won't load: #{failure}; until chi is updated " \
                       "(chi update), guarded tool calls are refused"
        end
      end
    end
  end
end
