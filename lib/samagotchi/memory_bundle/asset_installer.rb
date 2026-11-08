# frozen_string_literal: true

require "fileutils"
require_relative "file_digest"
require_relative "manifest"
require_relative "provenance"
require_relative "../version"

module Samagotchi
  module MemoryBundle
    autoload :Installer, File.expand_path("installer", __dir__)

    # The install of a bundle's parts that live in its own dir
    # (<bundles>/<name>/, Provenance#bundle_dir) rather than in the
    # memories dir: guardrails/*.yml, the plugin file and scripts/*. Each
    # replaces what an earlier version installed. An older chi's record
    # with class-file hooks has them removed (#retire_hooks): chi no longer
    # loads them, and the Installer refuses a source that has any. Installer
    # runs it after the memories; it adds to the installer's results and
    # warnings, and #run returns what the record (Provenance#write) keeps.
    # A dev install (+dev+, `chi bundle install --dev`) links each file to
    # the source instead of copying it, and warns of no checksum mismatch.
    # An edited file it replaces or removes is copied to the trash first,
    # under its subfolder (Trash#copy_edits); a link never is.
    class AssetInstaller
      # What was installed: the paths Provenance#write records (each
      # empty / nil on a dry run).
      #   guardrail_files, script_files  basename => installed path
      #   plugin_file the installed plugin file, nil without one
      Installed = Data.define(:guardrail_files, :plugin_file, :script_files)

      # The retire's summary words (Installer#summary): why the hooks went.
      RETIRED = "chi no longer loads class-file bundle hooks"

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
        incoming_rules = Dir.glob(File.join(@bundle_dir, "guardrails", "*.yml")).sort
                            .reject { |src| linked_out?(src, "guardrails/#{File.basename(src)}") }
        guardrail_files = install_guardrails(incoming_rules)
        plugin_file = install_plugin
        script_files = install_scripts
        # After the plugin and scripts, which raise for a file the manifest
        # names and the bundle lacks: a refused install leaves hooks/ as it was.
        retire_hooks
        warn_rules_requires_chi(incoming_rules)
        Installed.new(guardrail_files: guardrail_files, plugin_file: plugin_file, script_files: script_files)
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

      # The hooks/ an older chi installed (class-file hooks, which no longer
      # load): every file in it goes, an edited one (or one the record
      # doesn't know) copied to the trash first, a dev link never (it points
      # at the source, which stays). Each is a :removed result (a dry run's
      # :would_remove, through #planned) with the RETIRED note; an empty
      # hooks/ dir goes without a word. The record keeps no hooks
      # (Provenance#write).
      def retire_hooks
        dir = @provenance.hooks_dir
        return unless File.directory?(dir) || File.symlink?(dir)

        files = File.symlink?(dir) ? [] : Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.reject { |f| File.directory?(File.join(dir, f)) }
        files.each do |file|
          @results["hooks/#{file}"] = @dry_run ? planned(retired) : retired
        end
        return if @dry_run

        @trash.copy_edits(dir, "hooks", @existing&.hooks&.transform_values(&:sha256))
        FileUtils.rm_rf(dir)
      end

      def retired = Installer::FileResult.new(word: :removed, note: RETIRED)

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
      # install, of a file that is there) or installed. A dry run records #planned of it, so the two
      # can't drift.
      def result_for(src, dest, updated:)
        word = if File.file?(dest) && FileUtils.identical?(src, dest) then :up_to_date
               elsif updated && File.exist?(dest) then :updated
               else :installed
               end
        Installer::FileResult.new(word: word)
      end

      # A dry run's word for a result: would_install, would_update,
      # would_remove, or the up to date result as it is (nothing would be
      # written).
      def planned(result)
        case result.word
        when :installed then result.with(word: :would_install)
        when :updated then result.with(word: :would_update)
        when :removed then result.with(word: :would_remove)
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

      # GuardrailWiring#bundle_rules doesn't read the rules of a bundle whose
      # requires_chi this chi doesn't meet, and a session that never loaded
      # them records a required load failure (the gate refuses guarded calls
      # until chi is updated): say so at install, as install_plugin does.
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
