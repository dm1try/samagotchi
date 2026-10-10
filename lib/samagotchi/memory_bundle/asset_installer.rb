# frozen_string_literal: true

require "fileutils"
require "digest"
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
      def initialize(name:, source_dir:, manifest:, provenance:, existing:, results:, warnings:, conflicts:,
                     force: false, strict: true, upgrade: false, dry_run: false)
        @name = name
        @bundle_dir = source_dir
        @manifest = manifest
        @provenance = provenance
        @existing = existing
        @results = results
        @warnings = warnings
        @conflicts = conflicts
        @force = force
        @strict = strict
        @upgrade = upgrade
        @dry_run = dry_run
      end

      # @return [Installed]
      # @raise [Installer::InstallError] the manifest names a plugin or
      #   script the bundle doesn't have
      def run
        install_hooks
        prune_dropped_hooks if @upgrade && @existing && !@dry_run
        verify_hook_checksums if @manifest && @strict
        incoming_rules = Dir.glob(File.join(@bundle_dir, "guardrails", "*.yml")).sort
        guardrail_files = install_guardrails(incoming_rules)
        plugin_file = install_plugin
        script_files = install_scripts
        warn_hooks_requires_chi
        warn_rules_requires_chi(incoming_rules)
        Installed.new(hooks: @bundle_hooks, hook_files: @hook_files, guardrail_files: guardrail_files,
                      plugin_file: plugin_file, script_files: script_files)
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
        hook_entries.each_key do |basename|
          next unless basename.is_a?(String) && !basename.empty?

          @bundle_hooks << basename
          src = File.join(@bundle_dir, "hooks", basename)
          install_hook(basename, src) if File.exist?(src)
        end
      end

      # One listed hook; an upgrade overwrites a local edit with a warning.
      def install_hook(basename, src)
        dest = File.join(@provenance.hooks_dir, basename)
        if @dry_run
          @results[basename] = { status: File.exist?(dest) && !@force ? "would_skip" : "would_install" }
          return
        end

        prev_sha = @existing&.hooks&.dig(basename)&.sha256
        if @upgrade && File.exist?(dest) && !@force && !Provenance.recorded_sha(prev_sha).empty? && !Provenance.sha_matches?(dest, prev_sha)
          @warnings << "Hook #{basename} was locally modified; overwriting"
        end

        FileUtils.mkdir_p(@provenance.hooks_dir)
        unchanged = File.exist?(dest) && FileUtils.identical?(src, dest)
        FileUtils.cp(src, dest)
        @results[basename] = if unchanged
                               { status: "skipped", reason: "already up to date" }
                             elsif @upgrade && @existing
                               { status: "updated" }
                             else
                               { status: "installed" }
                             end
        @hook_files[basename] = dest
      end

      # No manifest (a non-strict install): every hooks/*.rb is copied.
      def install_unlisted_hooks
        Dir.glob(File.join(@bundle_dir, "hooks", "*.rb")).each do |src|
          basename = File.basename(src)
          @bundle_hooks << basename
          if @dry_run
            @results[basename] = { status: "would_install" }
          else
            FileUtils.mkdir_p(@provenance.hooks_dir)
            dest = File.join(@provenance.hooks_dir, basename)
            FileUtils.cp(src, dest)
            @results[basename] = { status: "installed" }
            @hook_files[basename] = dest
          end
        end
      end

      # An upgrade removes the hooks the previous version shipped and this
      # one doesn't (a local file too, with a warning).
      def prune_dropped_hooks
        @existing.hooks.each_key do |old_key_str|
          next if @bundle_hooks.include?(old_key_str)

          old_dest = File.join(@provenance.hooks_dir, old_key_str)
          if File.exist?(old_dest) && !@force
            @warnings << "Bundle no longer includes hook #{old_key_str} but local file exists — removing"
          end
          FileUtils.rm_f(old_dest)
        end
      end

      # Strict mode: an installed hook whose sha256 differs from the one its
      # manifest declares warns (as verify_memory_checksums does).
      def verify_hook_checksums
        @bundle_hooks.each do |basename|
          next if @conflicts.key?(basename)

          expected = @manifest.checksum_for_hook(basename)
          next unless expected

          dest = File.join(@provenance.hooks_dir, basename)
          next unless File.exist?(dest)

          actual = Digest::SHA256.hexdigest(File.read(dest))
          if actual != expected
            @warnings << "Checksum mismatch for hook #{basename}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
          end
        end
      end

      # The bundle's guardrails/*.yml into <bundle_dir>/guardrails/: the
      # set replaces what an earlier version installed. Same bytes as
      # installed are reported up to date, not "Installed".
      # @return [Hash{String => String}] basename => installed path ({} on a dry run)
      def install_guardrails(incoming_rules)
        if @dry_run
          incoming_rules.each { |src| @results["guardrails/#{File.basename(src)}"] = { status: "would_install" } }
          return {}
        end

        target = @provenance.guardrails_dir
        unchanged = incoming_rules.select do |src|
          dest = File.join(target, File.basename(src))
          File.file?(dest) && FileUtils.identical?(src, dest)
        end
        FileUtils.rm_rf(target)
        return {} if incoming_rules.empty?

        FileUtils.mkdir_p(target)
        incoming_rules.to_h do |src|
          dest = File.join(target, File.basename(src))
          FileUtils.cp(src, dest)
          @results["guardrails/#{File.basename(src)}"] =
            unchanged.include?(src) ? { status: "skipped", reason: "already up to date" } : { status: "installed" }
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
          FileUtils.rm_rf(@provenance.plugin_dir) unless @dry_run
          return nil
        end

        src = File.join(@bundle_dir, plugin[:file])
        raise Installer::InstallError, "the manifest names plugin #{plugin[:file]}, which the bundle doesn't have" unless File.file?(src)

        if (failure = Manifest.requires_chi_failure(@manifest.requires_chi, Samagotchi::VERSION))
          @warnings << "Plugin #{plugin[:file]} won't load: #{failure}"
        end
        if @dry_run
          @results[plugin[:file]] = { status: "would_install" }
          return nil
        end

        dest = File.join(@provenance.plugin_dir, plugin[:file])
        unchanged = File.file?(dest) && FileUtils.identical?(src, dest)
        FileUtils.rm_rf(@provenance.plugin_dir)
        FileUtils.mkdir_p(@provenance.plugin_dir)
        FileUtils.cp(src, dest)
        @results[plugin[:file]] = if unchanged
                                    { status: "skipped", reason: "already up to date" }
                                  elsif @upgrade && @provenance.installed?
                                    { status: "updated" }
                                  else
                                    { status: "installed" }
                                  end
        expected = @manifest.checksum_for_plugin
        actual = Digest::SHA256.hexdigest(File.binread(dest))
        if @strict && expected && actual != expected
          @warnings << "Checksum mismatch for plugin #{plugin[:file]}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
        end
        dest
      end

      # The manifest's scripts, copied into <bundle_dir>/scripts/ (the
      # folder replaced: a script the new version dropped goes). A declared
      # sha256 that differs warns, as a plugin's does.
      # @return [Hash{String => String}] file name => installed path
      def install_scripts
        scripts = @manifest&.scripts || {}
        scripts.each_key do |file|
          next if File.file?(File.join(@bundle_dir, "scripts", file))

          raise Installer::InstallError, "the manifest names scripts/#{file}, which the bundle doesn't have"
        end
        return {} if @dry_run

        unchanged = scripts.keys.select do |file|
          dest = File.join(@provenance.scripts_dir, file)
          File.file?(dest) && FileUtils.identical?(File.join(@bundle_dir, "scripts", file), dest)
        end
        FileUtils.rm_rf(@provenance.scripts_dir)
        return {} if scripts.empty?

        FileUtils.mkdir_p(@provenance.scripts_dir)
        scripts.to_h do |file, declared|
          dest = File.join(@provenance.scripts_dir, file)
          FileUtils.cp(File.join(@bundle_dir, "scripts", file), dest)
          @results["scripts/#{file}"] = if unchanged.include?(file) then { status: "skipped", reason: "already up to date" }
                                        elsif @upgrade && @provenance.installed? then { status: "updated" }
                                        else { status: "installed" }
                                        end
          FileUtils.chmod(0o755, dest)
          actual = Digest::SHA256.hexdigest(File.binread(dest))
          expected = declared.to_s.delete_prefix("sha256:")
          if @strict && !expected.empty? && actual != expected
            @warnings << "Checksum mismatch for script #{file}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
          end
          [file, dest]
        end
      end

      # The hook loader skips every hook of a bundle whose requires_chi this
      # chi doesn't meet (Hooks::BundleLoader); say so at install, as
      # install_plugin does for the plugin.
      def warn_hooks_requires_chi
        return if @manifest.nil? || @bundle_hooks.empty?

        if (failure = Manifest.requires_chi_failure(@manifest.requires_chi, Samagotchi::VERSION))
          @warnings << "Bundle #{@name}: its hooks won't load: #{failure}"
        end
      end

      # GuardrailWiring#bundle_rules doesn't read the rules of a bundle whose
      # requires_chi this chi doesn't meet, and a session that never loaded
      # them records a required load failure (the gate refuses guarded calls
      # until chi is updated): say so at install, as the hooks warning does.
      def warn_rules_requires_chi(rule_files)
        return if @manifest.nil? || rule_files.empty?

        if (failure = Manifest.requires_chi_failure(@manifest.requires_chi, Samagotchi::VERSION))
          @warnings << "Bundle #{@name}: its guardrail rules won't load: #{failure}; until chi is updated " \
                       "(chi update), guarded tool calls are refused"
        end
      end
    end
  end
end
