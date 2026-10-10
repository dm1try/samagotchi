# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require_relative "bundle_hook"
require_relative "manifest"
require_relative "placeholder"
require_relative "../context_providers"
require_relative "../memory_paths"
require_relative "../model_overlay"

module Samagotchi
  module MemoryBundle
    # Builds local memories and installed hooks into a shareable bundle.
    #
    # Inverse of Installer: reads from the resolved scope directory,
    # computes SHA256 checksums, writes manifest.yml via Manifest.write,
    # and optionally zips/tars the staging directory.
    class Builder
      class BuildError < StandardError; end

      DEFAULT_VERSION = "1.0.0"
      DEFAULT_SYSTEM_NAME = "chi_system_memories"

      # What a build takes from the installed bundle of the same name (its
      # record and its dir), else from the scope dir:
      #   record      the InstalledBundle, nil when none is installed (or
      #               it doesn't read)
      #   hooks       basename => BundleHook; hook_files basename => path
      #   rules       guardrails/*.yml paths
      #   plugin      the installed plugin file, nil without one
      #   scripts     file name => path; context_providers the parsed list
      InstalledParts = Data.define(:record, :hooks, :hook_files, :rules, :plugin, :scripts, :context_providers)

      attr_reader :built_files, :warnings, :placeholder_warnings, :out_path, :staging_dir

      def initialize(scope: nil, name: nil, version: nil, description: "", out: nil, files: nil, trust_level: nil)
        @scope = normalize_scope(scope) || "system"
        @name = sanitize_name(name) if name && !name.to_s.strip.empty?
        @version = version&.to_s&.strip
        @version = nil if @version && @version.empty?
        @description = description.to_s
        @out = out&.to_s&.strip
        @out = nil if @out && @out.empty?
        @filter_files = files # nil or Array<String> basenames
        @trust_level = trust_level&.to_s&.strip
        @built_files = []
        @warnings = []
        @placeholder_warnings = []
        @out_path = nil
        @staging_dir = nil
      end

      def run
        target_dir = MemoryPaths.scope_dir(@scope) or raise BuildError, "invalid scope: #{@scope}"
        resolved_name = @name || default_name(@scope)
        resolved_version = @version || DEFAULT_VERSION

        validate_name!(resolved_name)
        validate_version!(resolved_version)
        raise BuildError, "invalid scope: #{@scope}" unless %w[system project].include?(@scope)

        refuse_profile!(resolved_name)

        candidates = select_memories(target_dir, resolved_name)
        files_map = checksum_memories(candidates)

        parts = installed_parts(resolved_name, target_dir)
        resolved_out, format = resolve_out_path(@out, resolved_name)

        staging = Dir.mktmpdir("samagotchi-build-")
        @staging_dir = staging
        begin
          stage_files(staging, candidates, parts)
          write_manifest(staging, resolved_name, resolved_version, files_map, parts)
          write_out(staging, resolved_out, format)
          @out_path = resolved_out
        ensure
          FileUtils.rm_rf(staging) if staging && File.directory?(staging)
          @staging_dir = nil
        end

        {
          out_path: @out_path,
          format: format,
          name: resolved_name,
          version: resolved_version,
          scope: @scope,
          files: @built_files.dup,
          placeholder_warnings: @placeholder_warnings.dup
        }
      end

      def summary
        lines = []
        lines << "Built #{@built_files.size} file(s) to #{@out_path}"
        lines << "Files: #{@built_files.join(", ")}" unless @built_files.empty?
        lines.concat(@placeholder_warnings.map { |w| "Placeholder: #{w}" }) unless @placeholder_warnings.empty?
        lines.concat(@warnings) unless @warnings.empty?
        lines.join("\n")
      end

      private

      # The scope's memories to build: every *.md but index.md and hidden
      # ones; with an allowlist the named ones (each must exist) with their
      # model overlays, else all but those another installed bundle owns.
      # @return [Array<String>] paths
      def select_memories(target_dir, name)
        candidates = Dir.glob(File.join(target_dir, "*.md")).sort
                        .reject { |p| File.basename(p) == "index.md" || File.basename(p).start_with?(".") }
        if candidates.empty?
          raise BuildError, "No memories to build in #{@scope} scope (#{target_dir}): no .md files found"
        end
        return leave_out_owned(candidates, name) unless @filter_files && !@filter_files.empty?

        allow = @filter_files.map { |f| normalize_filter_entry(f) }
        candidates_by_basename = candidates.to_h { |p| [File.basename(p), p] }
        missing = allow.reject { |k| candidates_by_basename.key?(k) }
        raise BuildError, "Requested file(s) not found in #{@scope} scope: #{missing.join(", ")}" unless missing.empty?

        with_overlays(allow, candidates_by_basename).map { |k| candidates_by_basename[k] }
      end

      # file key => "sha256:<hex>" for the manifest; fills @built_files and
      # a placeholder warning per memory with {{placeholders}}.
      def checksum_memories(paths)
        paths.to_h do |path|
          key = File.basename(path)
          content = File.read(path)
          @built_files << key
          names = Placeholder.new(content: content).placeholders
          @placeholder_warnings << "#{key}: {{#{names.map(&:strip).uniq.sort.join("}}, {{")}}}" unless names.empty?
          [key, "sha256:#{Digest::SHA256.hexdigest(content)}"]
        end
      end

      # The installed bundle's hooks (a recorded one missing on disk left
      # out; one with no recorded sha gets its file's), guardrail rules,
      # plugin, scripts and context providers. Without hooks or rules in a
      # record, the scope dir's hooks/*.rb and guardrails/*.yml (building
      # from a raw bundle dir that is also the memories dir).
      # @return [InstalledParts]
      def installed_parts(name, target_dir)
        prov = nil
        record = nil
        begin
          require_relative "provenance"
          prov = Provenance.new(name: name)
          record = prov.record
        rescue StandardError
          record = nil
        end

        hooks = {}
        hook_files = {}
        if record&.hooks&.any?
          record.hooks.each do |basename, hook|
            src = File.join(prov.hooks_dir, basename)
            next unless File.exist?(src)

            hooks[basename] = hook.sha256.empty? ? hook.with(sha256: BundleHook.of_file(src).sha256) : hook
            hook_files[basename] = src
          end
        else
          Dir.glob(File.join(target_dir, "hooks", "*.rb")).sort.each do |src|
            hooks[File.basename(src)] = BundleHook.of_file(src)
            hook_files[File.basename(src)] = src
          end
        end

        rules_dir = record&.guardrails&.any? ? prov.guardrails_dir : File.join(target_dir, "guardrails")
        plugin = record ? prov.plugin_path(record) : nil
        InstalledParts.new(
          record: record, hooks: hooks, hook_files: hook_files,
          rules: Dir.exist?(rules_dir) ? Dir.glob(File.join(rules_dir, "*.yml")).sort : [],
          plugin: plugin && File.file?(plugin) ? plugin : nil,
          scripts: installed_scripts(prov, record),
          context_providers: record ? ContextProviders.parse_list(record.context_providers) : []
        )
      end

      # The memories, hooks/, guardrails/, the plugin and scripts/ into the
      # staging dir, laid out as Installer reads a bundle.
      def stage_files(staging, candidates, parts)
        candidates.each { |src| FileUtils.cp(src, File.join(staging, File.basename(src))) }
        unless parts.hook_files.empty?
          FileUtils.mkdir_p(File.join(staging, "hooks"))
          parts.hook_files.each { |basename, src| FileUtils.cp(src, File.join(staging, "hooks", basename)) }
        end
        unless parts.rules.empty?
          FileUtils.mkdir_p(File.join(staging, "guardrails"))
          parts.rules.each { |src| FileUtils.cp(src, File.join(staging, "guardrails", File.basename(src))) }
        end
        FileUtils.cp(parts.plugin, File.join(staging, File.basename(parts.plugin))) if parts.plugin
        return if parts.scripts.empty?

        FileUtils.mkdir_p(File.join(staging, "scripts"))
        parts.scripts.each_value { |src| FileUtils.cp(src, File.join(staging, "scripts", File.basename(src))) }
      end

      # manifest.yml for the staged bundle: requires_chi, needs and the
      # file descriptions come from the installed bundle's record, the
      # trust_level from the CLI else the record.
      def write_manifest(staging, name, version, files_map, parts)
        record = parts.record
        trust_level = @trust_level
        trust_level = record.trust_level if (trust_level.nil? || trust_level.empty?) && record&.trust_level
        Manifest.write(
          dir: staging,
          name: name,
          version: version,
          scope: @scope,
          description: @description,
          files: files_map,
          hooks: parts.hooks.empty? ? nil : parts.hooks,
          trust_level: trust_level,
          plugin: parts.plugin && { file: File.basename(parts.plugin), sha256: Digest::SHA256.hexdigest(File.binread(parts.plugin)) },
          requires_chi: record&.requires_chi,
          needs: record&.needs,
          scripts: parts.scripts.transform_values { |src| "sha256:#{Digest::SHA256.hexdigest(File.binread(src))}" },
          context_providers: parts.context_providers,
          file_descriptions: file_descriptions(record, files_map)
        )
      end

      # The staged bundle to +out+: a zip or tar archive, or a directory,
      # which must be new or empty (one holding a bundle says so).
      def write_out(staging, out, format)
        case format
        when :zip then zip_staging(staging, out)
        when :tar_gz, :tar, :tgz then tar_staging(staging, out, format)
        when :dir
          FileUtils.mkdir_p(out)
          unless Dir.entries(out).reject { |e| e.start_with?(".") }.empty?
            if File.exist?(File.join(out, "manifest.yml"))
              raise BuildError, "Output directory already contains a bundle (#{out}/manifest.yml) — choose different --out or remove it"
            end

            raise BuildError, "Output directory already exists and is not empty: #{out}"
          end
          FileUtils.cp_r("#{staging}/.", out)
        else
          raise BuildError, "unknown format: #{format}"
        end
      end

      # An installed profile (meta bundle) ships only its includes: a build
      # under its name would make a plain bundle of the scope's memories,
      # without the includes, carrying the profile's trust_level.
      def refuse_profile!(name)
        require_relative "profile"
        record = Provenance.new(name: name).record
        return unless Profile.installed_meta?(name, record)

        shipped = File.join(SourceNormalizer::SHIPPED_DIR, name)
        members = Profile.recorded(record, File.file?(File.join(shipped, "manifest.yml")) ? Manifest.read(dir: shipped) : nil)
        raise BuildError, "#{name} is an installed profile (includes: #{members.join(", ")}): it ships only its includes, " \
                          "so a build can't remake it; pick another --name for these memories"
      rescue JSON::ParserError, SystemCallError, Manifest::ValidationError
        nil
      end

      # The installed bundle's scripts its record lists, file name => path
      # in its scripts/ (a missing one is left out); {} without a record.
      def installed_scripts(prov, record)
        return {} unless record

        record.scripts.keys.sort.to_h { |file| [file, File.join(prov.scripts_dir, file)] }
                     .select { |_, path| File.file?(path) }
      end

      # The descriptions the installed bundle's record keeps for the files
      # being built (its manifest's files: mappings), so a rebuild writes
      # them back; {} without a record.
      def file_descriptions(record, files_map)
        return {} unless record

        record.files.each_with_object({}) do |(key, entry), acc|
          text = entry[:description].to_s
          acc[key] = text if files_map.key?(key) && !text.empty?
        end
      end

      # Without an allowlist, a memory another installed bundle owns (its
      # record lists it) isn't the user's to share: left out, one line
      # each. The bundle being built (same name) keeps its own.
      def leave_out_owned(candidates, name)
        require_relative "provenance"
        owners = candidates.to_h do |path|
          [path, Provenance.claimants(File.basename(path), scope: @scope, except: name)]
        end
        left_out = owners.reject { |_, names| names.empty? }
        left_out.each do |path, names|
          @warnings << "Left out #{File.basename(path)}: installed by bundle #{names.join(", ")} (name it to include it)"
        end
        kept = candidates - left_out.keys
        if kept.empty?
          raise BuildError, "No memories to build in #{@scope} scope: every one belongs to an installed bundle " \
                            "(#{left_out.keys.map { |p| File.basename(p) }.join(", ")}); name the ones to include"
        end
        kept
      end

      def normalize_scope(val)
        return nil if val.nil? || val.to_s.strip.empty?

        v = val.to_s.strip.downcase
        %w[project system].include?(v) ? v : nil
      end

      def sanitize_name(name)
        name.to_s.strip
      end

      def validate_name!(name)
        raise BuildError, "bundle name is required" if name.nil? || name.strip.empty?
        raise BuildError, "bundle name must not contain path separators" if name.include?("/") || name.include?("\\")
      end

      def validate_version!(version)
        raise BuildError, "bundle version is required" if version.nil? || version.strip.empty?
      end

      def default_name(scope)
        if scope == "project"
          base = File.basename(MemoryPaths.project_root).gsub(/[^A-Za-z0-9_-]/, "-").downcase
          base = base.squeeze("-").gsub(/\A-+|-+\z/, "")
          base = "project" if base.empty?
          "chi_#{base}_memories"
        else
          DEFAULT_SYSTEM_NAME
        end
      end

      # The named files, each base followed by its model overlays
      # (<name>.<key>.md next to it, ModelOverlay.overlay_file?; a plain
      # tips.v2.md with no tips.md isn't one), with a note listing them. An
      # overlay named without its base is kept, with a warning.
      def with_overlays(allow, candidates_by_basename)
        dir = File.dirname(candidates_by_basename.values.first.to_s)
        overlays = candidates_by_basename.keys.select { |k| ModelOverlay.overlay_file?(File.join(dir, k)) }
        allow.flat_map do |key|
          if overlays.include?(key)
            base = ModelOverlay.base_file_for(key)
            unless allow.include?(base)
              @warnings << "#{key} is a model overlay of #{base}, which the bundle leaves out; it loads only where #{base} exists"
            end
            next [key]
          end

          own = overlays.select { |k| ModelOverlay.base_file_for(k) == key && !allow.include?(k) }.sort
          @warnings << "Included the model overlays of #{key}: #{own.join(", ")}" unless own.empty?
          [key, *own]
        end.uniq
      end

      def normalize_filter_entry(entry)
        s = entry.to_s.strip
        # Allow with or without .md extension, but normalize to basename with .md
        base = File.basename(s)
        base = "#{base}.md" unless base.downcase.end_with?(".md")
        base
      end

      def resolve_out_path(out_arg, default_name)
        if out_arg.nil? || out_arg.empty?
          # Default: <name>.zip in Dir.pwd
          path = File.join(Dir.pwd, "#{default_name}.zip")
          return [File.expand_path(path), :zip]
        end

        expanded = File.expand_path(out_arg)
        lower = expanded.downcase

        if lower.end_with?(".zip")
          [expanded, :zip]
        elsif lower.end_with?(".tar.gz")
          [expanded, :tar_gz]
        elsif lower.end_with?(".tgz")
          [expanded, :tgz]
        elsif lower.end_with?(".tar")
          [expanded, :tar]
        else
          # Treat as directory — if path exists and is a file, error
          if File.exist?(expanded) && !File.directory?(expanded)
            raise BuildError, "Output path exists and is not a directory: #{expanded}"
          end

          [expanded, :dir]
        end
      end

      def zip_staging(staging, out_path)
        FileUtils.mkdir_p(File.dirname(out_path))
        if File.exist?(out_path)
          raise BuildError, "Output file already exists: #{out_path} — remove it or choose different --out"
        end

        # Use zip CLI like source.rb does with unzip
        Dir.chdir(staging) do
          result = system("zip", "-r", out_path, ".")
          raise BuildError, "zip failed for #{out_path} (is zip installed?)" unless result && File.exist?(out_path)
        end
      end

      def tar_staging(staging, out_path, format)
        FileUtils.mkdir_p(File.dirname(out_path))
        if File.exist?(out_path)
          raise BuildError, "Output file already exists: #{out_path} — remove it or choose different --out"
        end

        # Use tar CLI
        Dir.chdir(staging) do
          cmd = case format
                when :tar_gz, :tgz then ["tar", "-czf", out_path, "."]
                when :tar then ["tar", "-cf", out_path, "."]
                end
          result = system(*cmd)
          raise BuildError, "tar failed for #{out_path}" unless result && File.exist?(out_path)
        end
      end
    end
  end
end
