# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require_relative "manifest"
require_relative "placeholder"
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

        # Collect *.md files, excluding index.md and hidden files
        all_md = Dir.glob(File.join(target_dir, "*.md")).sort
        candidates = all_md.reject { |p| File.basename(p) == "index.md" }
        candidates.reject! { |p| File.basename(p).start_with?(".") }

        if candidates.empty?
          raise BuildError, "No memories to build in #{@scope} scope (#{target_dir}): no .md files found"
        end

        # Apply allowlist filter if provided
        if @filter_files && !@filter_files.empty?
          allow = @filter_files.map { |f| normalize_filter_entry(f) }
          # Validate each requested file exists in candidates
          candidates_by_basename = candidates.map { |p| [File.basename(p), p] }.to_h
          missing = allow.reject { |k| candidates_by_basename.key?(k) }
          unless missing.empty?
            raise BuildError, "Requested file(s) not found in #{@scope} scope: #{missing.join(', ')}"
          end
          candidates = with_overlays(allow, candidates_by_basename).map { |k| candidates_by_basename[k] }
        else
          candidates = leave_out_owned(candidates, resolved_name)
        end

        # Compute checksums and detect placeholders
        files_map = {}
        candidates.each do |path|
          key = File.basename(path)
          content = File.read(path)
          hex = Digest::SHA256.hexdigest(content)
          files_map[key] = "sha256:#{hex}"
          @built_files << key

          names = Placeholder.new(content: content).placeholders
          unless names.empty?
            uniq = names.map(&:strip).uniq.sort
            @placeholder_warnings << "#{key}: {{#{uniq.join("}}, {{")}}}"
          end
        end

        # ── Hooks: collect hooks for the bundle ──────────────────────
        hooks_map = {}
        hooks_to_copy = [] # Array of [src_path, basename]
        # Try provenance first (if bundle with this name is installed)
        prov = nil
        prov_data = nil
        begin
          require_relative "provenance"
          prov = Provenance.new(name: resolved_name)
          prov_data = prov.read
        rescue StandardError
          prov_data = nil
        end
        if prov_data && prov_data[:hooks].is_a?(Hash) && !prov_data[:hooks].empty?
          prov_data[:hooks].each do |k, meta|
            basename = k.to_s
            src = File.join(prov.hooks_dir, basename)
            # Skip if hook file missing on disk
            next unless File.exist?(src)
            # meta may be symbol-keyed
            m = meta.is_a?(Hash) ? meta.transform_keys(&:to_s) : {}
            sha = (m["sha256"] || m["checksum"] || "").to_s
            if sha.empty?
              sha = "sha256:#{Digest::SHA256.hexdigest(File.read(src))}"
            elsif !sha.start_with?("sha256:")
              sha = "sha256:#{sha}"
            end
            hooks_map[basename] = {
              "sha256" => sha,
              "event" => (m["event"] || "").to_s,
              "on_error" => (m["on_error"] || "skip").to_s,
              "priority" => (m["priority"] || 100).to_i
            }
            hooks_to_copy << [src, basename]
          end
        else
          # Fallback: scan target_dir/hooks if present (e.g. building from a raw bundle dir that is also the mem dir)
          local_hooks_dir = File.join(target_dir, "hooks")
          if Dir.exist?(local_hooks_dir)
            Dir.glob(File.join(local_hooks_dir, "*.rb")).sort.each do |src|
              basename = File.basename(src)
              sha = Digest::SHA256.hexdigest(File.read(src))
              hooks_map[basename] = {
                "sha256" => "sha256:#{sha}",
                "event" => "",
                "on_error" => "skip",
                "priority" => 100
              }
              hooks_to_copy << [src, basename]
            end
          end
        end
        # ── Guardrail rules: the installed bundle's, else target_dir's ──
        rules_dir = prov && prov_data && prov_data[:guardrails].is_a?(Hash) ? prov.guardrails_dir : File.join(target_dir, "guardrails")
        rules_to_copy = Dir.exist?(rules_dir) ? Dir.glob(File.join(rules_dir, "*.yml")).sort : []

        # ── Plugin: the installed bundle's, with its requires_chi ──
        plugin_src = prov && prov_data ? prov.plugin_path(prov_data) : nil
        plugin_src = nil unless plugin_src && File.file?(plugin_src)
        requires_chi = prov_data && prov_data[:requires_chi]
        needs = prov_data && prov_data[:needs]

        # Determine trust_level for the built bundle
        build_trust_level = @trust_level
        if (build_trust_level.nil? || build_trust_level.empty?) && prov_data && prov_data[:trust_level]
          build_trust_level = prov_data[:trust_level].to_s
        end

        # Resolve output path and format
        resolved_out, format = resolve_out_path(@out, resolved_name)

        # Prepare staging dir (temp)
        staging = Dir.mktmpdir("samagotchi-build-")
        @staging_dir = staging
        begin
          candidates.each do |src|
            FileUtils.cp(src, File.join(staging, File.basename(src)))
          end
          # Copy hooks into staging/hooks/
          unless hooks_to_copy.empty?
            hooks_staging = File.join(staging, "hooks")
            FileUtils.mkdir_p(hooks_staging)
            hooks_to_copy.each do |src, basename|
              FileUtils.cp(src, File.join(hooks_staging, basename))
            end
          end

          unless rules_to_copy.empty?
            rules_staging = File.join(staging, "guardrails")
            FileUtils.mkdir_p(rules_staging)
            rules_to_copy.each { |src| FileUtils.cp(src, File.join(rules_staging, File.basename(src))) }
          end

          FileUtils.cp(plugin_src, File.join(staging, File.basename(plugin_src))) if plugin_src

          Manifest.write(
            dir: staging,
            name: resolved_name,
            version: resolved_version,
            scope: @scope,
            description: @description,
            files: files_map,
            hooks: hooks_map.empty? ? nil : hooks_map,
            trust_level: build_trust_level,
            plugin: plugin_src && { file: File.basename(plugin_src), sha256: Digest::SHA256.hexdigest(File.binread(plugin_src)) },
            requires_chi: requires_chi,
            needs: needs
          )

          case format
          when :zip
            zip_staging(staging, resolved_out)
            @out_path = resolved_out
          when :tar_gz, :tar, :tgz
            tar_staging(staging, resolved_out, format)
            @out_path = resolved_out
          when :dir
            # Copy staging contents to out dir
            FileUtils.mkdir_p(resolved_out)
            # Guard: refuse to overwrite non-empty dir without force (error)
            existing = Dir.entries(resolved_out).reject { |e| e.start_with?(".") }
            unless existing.empty?
              # Allow if out is the staging itself? no, staging is temp
              # Check if out dir already has manifest.yml — treat as existing bundle
              if File.exist?(File.join(resolved_out, "manifest.yml"))
                raise BuildError, "Output directory already contains a bundle (#{resolved_out}/manifest.yml) — choose different --out or remove it"
              end
              # If dir has any files, still require explicit handling — error
              unless existing.empty?
                raise BuildError, "Output directory already exists and is not empty: #{resolved_out}"
              end
            end
            FileUtils.cp_r("#{staging}/.", resolved_out)
            @out_path = resolved_out
          else
            raise BuildError, "unknown format: #{format}"
          end
        ensure
          # Clean up staging temp dir unless out_path == staging (not possible for dir)
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
        lines << "Files: #{@built_files.join(', ')}" unless @built_files.empty?
        lines.concat(@placeholder_warnings.map { |w| "Placeholder: #{w}" }) unless @placeholder_warnings.empty?
        lines.concat(@warnings) unless @warnings.empty?
        lines.join("\n")
      end

      private

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
          base = base.gsub(/-+/, "-").gsub(/\A-+|-+\z/, "")
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
