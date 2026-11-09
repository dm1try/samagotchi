# frozen_string_literal: true

require "fileutils"
require_relative "asset_state"
require_relative "file_actions"
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
    # Each folder is one loop over its files' AssetStates (#install_set):
    # FileActions' asset tables say what each gets, the dry run reading the
    # same row. An edited file it replaces or removes is copied to the trash
    # first, under its subfolder (AssetState#edited?, Trash.edit?'s rule); a
    # link never is.
    class AssetInstaller
      # What was installed: the paths Provenance#write records (each
      # empty / nil on a dry run).
      #   guardrail_files, script_files  basename => installed path
      #   plugin_file the installed plugin file, nil without one
      Installed = Data.define(:guardrail_files, :plugin_file, :script_files)

      # The retire's summary words (Installer#summary): why the hooks went.
      RETIRED = "chi no longer loads class-file bundle hooks"

      # A dry run's word for a real run's (Installer#summary): nothing would
      # be written to a file already up to date.
      DRY_WORDS = { installed: :would_install, updated: :would_update, up_to_date: :up_to_date }.freeze

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
        guardrail_files = install_set(:rule, rules_incoming(incoming_rules))
        plugin_file = install_set(:plugin, plugin_incoming).values.first
        script_files = install_set(:script, scripts_incoming)
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
      # :would_remove) with the RETIRED note; an empty hooks/ dir goes
      # without a word. The record keeps no hooks
      # (Provenance#write).
      def retire_hooks
        dir = @provenance.hooks_dir
        return unless File.directory?(dir) || File.symlink?(dir)

        files = File.symlink?(dir) ? [] : Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.reject { |f| File.directory?(File.join(dir, f)) }
        files.each do |file|
          @results["hooks/#{file}"] = @dry_run ? retired.with(word: :would_remove) : retired
        end
        return if @dry_run

        @trash.copy_edits(dir, "hooks", @existing&.hooks&.transform_values(&:sha256))
        FileUtils.rm_rf(dir)
      end

      def retired = Installer::FileResult.new(word: :removed, note: RETIRED)

      # The bundle's guardrails/*.yml, by basename.
      def rules_incoming(incoming_rules) = incoming_rules.to_h { |src| [File.basename(src), src] }

      # The manifest's plugin file, warning when this chi doesn't meet
      # requires_chi (the Engine then won't load it). {} without one.
      # @return [Hash{String => String}] its file => the source file
      def plugin_incoming
        plugin = @manifest&.plugin
        return {} unless plugin

        src = File.join(@bundle_dir, plugin[:file])
        raise Installer::InstallError, "the manifest names plugin #{plugin[:file]}, which the bundle doesn't have" unless File.file?(src)
        raise Installer::InstallError, "plugin #{plugin[:file]} is a symlink (not installed)" if linked?(src)

        if (failure = Manifest.requires_chi_failure(@manifest.requires_chi, @chi_version))
          @warnings << "Plugin #{plugin[:file]} won't load: #{failure}"
        end
        { plugin[:file] => src }
      end

      # The manifest's scripts (a dev install warns of one it can't run).
      # @return [Hash{String => String}] file name => the source file
      def scripts_incoming
        scripts = @manifest&.scripts || {}
        scripts.keys.to_h do |file|
          src = File.join(@bundle_dir, "scripts", file)
          raise Installer::InstallError, "the manifest names scripts/#{file}, which the bundle doesn't have" unless File.file?(src)
          raise Installer::InstallError, "scripts/#{file} is a symlink (not installed)" if linked?(src)

          @warnings << "scripts/#{file} is not executable; chmod +x #{src}" if @dev && !File.executable?(src) && !page_only?(file)
          [file, src]
        end
      end

      # One folder of the bundle's own dir (guardrails/, plugin/, scripts/),
      # replaced whole by +incoming+: each file's AssetState and its action
      # (FileActions' ASSET_INSTALL, or ASSET_UPGRADE over an installed
      # bundle), one result per incoming file (a dry run's DRY_WORDS of it,
      # and nothing written), an edit copied to the trash first (save_first),
      #   then the folder replaced. A removed file is named in the summary.
      #   A plugin or script whose sha256 differs from the declared one warns
      #   (not a dev link: it is the source).
      # @param incoming [Hash{String => String}] name => the source file, in
      #   the order the results list them
      # @return [Hash{String => String}] name => installed path ({} on a dry run)
      def install_set(kind_of_file, incoming)
        dir, recorded = folder(kind_of_file)
        command = @upgrade && @provenance.installed? ? :upgrade : :install
        states = AssetState.in(dir, kind_of_file: kind_of_file, recorded: recorded, incoming: incoming)
                           .to_h { |asset| [asset.name, [asset, FileActions.for_asset(command, asset)]] }
        results = incoming.keys.to_h do |name|
          asset, action = states.fetch(name)
          [name, Installer::FileResult.new(word: @dry_run ? DRY_WORDS.fetch(action.word) : action.word, state: asset, action: action)]
        end
        dropped = states.filter_map do |name, (asset, action)|
          next unless action&.do == :remove

          [result_key(kind_of_file, name),
           Installer::FileResult.new(word: @dry_run ? :would_remove : :removed, state: asset, action: action,
                                     note: "no longer in the bundle")]
        end
        if @dry_run
          results.each { |name, result| @results[result_key(kind_of_file, name)] = result }
          dropped.each { |key, result| @results[key] = result }
          return {}
        end

        states.each_value { |asset, action| @trash.copy(asset.path, as: asset.label) if action.save_first }
        FileUtils.rm_rf(dir)
        if incoming.empty?
          dropped.each { |key, result| @results[key] = result }
          return {}
        end

        FileUtils.mkdir_p(dir)
        installed = incoming.to_h do |name, src|
          dest = File.join(dir, name)
          place(src, dest)
          @results[result_key(kind_of_file, name)] = results[name]
          FileUtils.chmod(0o755, dest) if kind_of_file == :script && !@dev
          if (declared = declared_sha(kind_of_file, name)) && results[name].action.do == :write_incoming && @strict && !@dev
            warning = FileDigest.mismatch("#{kind_of_file} #{name}", dest, declared)
            @warnings << warning if warning
          end
          [name, dest]
        end
        dropped.each { |key, result| @results[key] = result }
        installed
      end

      # The kind's folder and the record's shas for it.
      def folder(kind_of_file)
        case kind_of_file
        when :rule then [@provenance.guardrails_dir, @existing&.guardrails]
        when :plugin then [@provenance.plugin_dir, @existing&.plugin_shas]
        else [@provenance.scripts_dir, @existing&.scripts]
        end
      end

      # Its key in the Installer's results (the summary's name): a rule's
      # guardrails/r.yml, the plugin's own file name, a script's scripts/s.sh.
      def result_key(kind_of_file, name) = kind_of_file == :plugin ? name : "#{AssetState::FOLDERS.fetch(kind_of_file)}/#{name}"

      # The manifest's sha256 for a plugin or script (hex), nil for a rule.
      def declared_sha(kind_of_file, name)
        case kind_of_file
        when :plugin then @manifest.checksum_for_plugin
        when :script then @manifest.scripts[name].to_s.delete_prefix("sha256:")
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
      # until chi is updated): say so at install, as #plugin_incoming does.
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
