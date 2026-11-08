# frozen_string_literal: true

require "json"
require "digest"
require "date"
require "fileutils"
require "tmpdir"
require_relative "../atomic_file"
require_relative "../memory_paths"
require_relative "../version"
require_relative "bundle_hook"
require_relative "file_digest"
require_relative "installed_bundle"
require_relative "manifest"

module Samagotchi
  module MemoryBundle
    # Manages provenance storage at <memories>/.bundles/<name>/ (see MemoryPaths)
    # Each installed bundle gets a directory with:
    #   manifest.json — metadata about the install (merged on reinstall)
    #   bases/        — snapshots of every file as installed (for 3-way merge later)
    #   manifest.yml  — the bundle's own manifest as installed (#write's
    #                   manifest_from:), its sha in the record; read live
    #                   through InstalledManifest
    class Provenance
      def self.bundles_dir
        MemoryPaths.bundles_dir
      end

      attr_reader :name, :bundle_dir

      # What a conflict mark adds to a file's entry.
      MARK_FIELDS = %w[conflict incoming_sha legacy_base why missed missed_places].freeze
      # What a merge no report has shown adds to a file's entry (#note_merged).
      MERGE_NOTE_FIELDS = %w[merged_version merged_at merged_trash].freeze

      def initialize(name:)
        @name = name
        @bundle_dir = File.join(self.class.bundles_dir, name)
      end

      # The bundle's text a marked file missed: incoming/<file>, there until the
      # file settles, so it outlives a git or zip source's extract. Nothing globs
      # the bundle's folder for memories, and an uninstall's rm_rf sweeps it.
      def incoming_path(file_key)
        File.join(@bundle_dir, "incoming", file_key.to_s)
      end

      def hooks_dir
        File.join(@bundle_dir, "hooks")
      end

      # Installed guardrail rule files (guardrails/*.yml).
      def guardrails_dir
        File.join(@bundle_dir, "guardrails")
      end

      # The installed plugin file's dir (plugin/<file>).
      def plugin_dir
        File.join(@bundle_dir, "plugin")
      end

      # The installed scripts' dir (scripts/<file>): what a context
      # provider's command finds as {bundle_dir}/scripts.
      def scripts_dir
        File.join(@bundle_dir, "scripts")
      end

      # The bundle's manifest.yml as installed (InstalledBundle#kept_manifest_path).
      def kept_manifest_path
        File.join(@bundle_dir, "manifest.yml")
      end

      # The plugin file as installed, or nil when the bundle has none.
      # @param bundle [InstalledBundle, nil] its record (read when not given)
      def plugin_path(bundle = record)
        file = bundle&.plugin&.file
        file ? File.join(plugin_dir, file) : nil
      end

      # The plugin's base snapshot (bases/plugin/<file>), for bundle diff.
      def plugin_base_path(file)
        File.join(@bundle_dir, "bases", "plugin", file.to_s)
      end

      # Yields [name, bundle] for each installed bundle (a dir under
      # bundles_dir holding a manifest.json, dot dirs aside), by name. bundle
      # is its InstalledBundle, one with error set when manifest.json doesn't
      # parse or isn't an object; the rest still come.
      #
      # With holding: (:hooks, :guardrails or :plugin) only the bundles
      # whose manifest has a non-empty mapping under that key come, and a
      # manifest that doesn't parse comes (with error) only when its bundle
      # has that dir (hooks/, guardrails/, plugin/): what it would load
      # can't be checked. One that isn't an object is skipped there.
      # @param dir [String] the bundles dir (bundles_dir by default)
      def self.each_installed(holding: nil, dir: bundles_dir)
        return enum_for(:each_installed, holding: holding, dir: dir) unless block_given?
        return unless Dir.exist?(dir)

        Dir.children(dir).reject { |e| e.start_with?(".") }.sort.each do |name|
          mjson = File.join(dir, name, "manifest.json")
          next unless File.exist?(mjson)

          begin
            data = JSON.parse(File.read(mjson), symbolize_names: true)
          rescue JSON::ParserError, EncodingError, SystemCallError => e # a key that isn't UTF-8 can't be a symbol
            if holding.nil? || Dir.exist?(File.join(dir, name, holding.to_s))
              yield name, InstalledBundle.unreadable(name, "manifest.json is unreadable: #{e.message}")
            end
            next
          end
          next if holding && !(data.is_a?(Hash) && data[holding].is_a?(Hash) && !data[holding].empty?)

          yield name, InstalledBundle.parse(name, data, File.join(dir, name))
        end
      end

      # The other installed bundles of +scope+ whose record lists the memory
      # file +file_key+, by name (a manifest that doesn't read is left out).
      # A project-scoped record doesn't say which project: one from another
      # repo counts too, which errs on keeping the file.
      def self.claimants(file_key, scope:, except: nil, dir: bundles_dir)
        each_installed(dir: dir).filter_map do |name, bundle|
          next if name == except || bundle.error?
          next unless bundle.effective_scope == scope.to_s && bundle.owns?(file_key)

          name
        end
      end

      # The hex digest a manifest records, in either of its formats:
      # "sha256:<hex>" (hooks, rules, the plugin) or bare <hex> (a memory
      # file's checksum:). "" when none is recorded.
      def self.recorded_sha(value)
        value.to_s.delete_prefix("sha256:")
      end

      # The digest of a file, nil when it isn't there (FileDigest). Every
      # caller checks existence first; #sha_matches? reads a missing file as
      # not the recorded one.
      def self.file_sha(path)
        FileDigest.hex(path)
      end

      # What a dev install (`chi bundle install --dev`) records instead of
      # a sha256: its files are links to the source, which change under it.
      # Not a hex digest, so no file can be mistaken for it.
      DEV_SHA = "sha256:dev"

      # Whether +recorded+ is DEV_SHA: the file isn't checked.
      def self.unchecked?(recorded)
        recorded_sha(recorded) == recorded_sha(DEV_SHA)
      end

      # Whether the file's content is the one recorded (either format); a
      # dev install's (DEV_SHA) always is.
      def self.sha_matches?(path, recorded)
        unchecked?(recorded) || file_sha(path) == recorded_sha(recorded)
      end

      # Whether a memory on disk is what the install wrote: the entry's
      # recorded checksum, else its base copy. Unknown counts as edited. The
      # one rule a prune, an uninstall's refusal and chi bundle status read.
      def self.unchanged?(path, entry, base_path)
        recorded = entry[:checksum]
        return sha_matches?(path, recorded) unless recorded_sha(recorded).empty?

        File.exist?(base_path) && file_sha(path) == file_sha(base_path)
      end

      # The record's mirror of the manifest keys (InstalledBundle::MIRROR_KEYS)
      # as #write records them from its kwargs: what an older chi reads, and
      # what #adopt_manifest holds a source's manifest against.
      def self.mirror_fields(trust_level:, requires_chi:, needs:, context_providers:, block_renderers:, session_settings:,
                             session_setting_types:, settings:, setting_types:)
        fields = {}
        fields["trust_level"] = trust_level.to_s if trust_level && !trust_level.to_s.empty?
        fields["requires_chi"] = requires_chi.to_s if requires_chi && !requires_chi.to_s.empty?
        fields["needs"] = needs.map { |n| n.transform_keys(&:to_s).compact } if needs.is_a?(Array) && !needs.empty?
        fields["context_providers"] = context_providers.map(&:to_h) unless context_providers.empty?
        fields["block_renderers"] = block_renderers.map(&:to_h) unless block_renderers.empty?
        fields["session_settings"] = Array(session_settings).map(&:to_s) unless Array(session_settings).empty?
        fields["session_setting_types"] = session_setting_types.to_h { |k, v| [k.to_s, v.to_s] } unless session_setting_types.to_h.empty?
        fields["settings"] = settings.map(&:to_s) unless settings.nil?
        fields["setting_types"] = setting_types.to_h { |k, v| [k.to_s, v.to_s] } unless setting_types.to_h.empty?
        fields
      end

      # Writes provenance for an installation: merges into existing manifest.json
      # and saves base snapshots. Stale base snapshots (files removed from bundle)
      # are pruned.
      # @param files [Hash{String => String, nil}] every file the record keeps
      #   => the file whose content is its base; a key left out is dropped from
      #   the record. nil keeps an entry with no base (a kept edit that has
      #   none: the user's file must never become it), with its recorded
      #   checksum.
      # @param hooks_files [Hash] basename => path for hook file snapshots (optional)
      # @param guardrails_files [Hash] basename => installed rule file; the
      #   sha256 of each is recorded (the Engine checks it at load)
      # @param plugin_file [String, nil] the installed plugin file; its name
      #   and sha256 are recorded (the Engine checks it at load) with a base
      #   snapshot
      # @param plugin_required [Boolean] the manifest's plugin: required: true
      #   (a guardrail plugin), recorded with it as "required": true, so the
      #   Engine knows it whatever becomes of the kept manifest.yml
      # @param requires_chi [String, nil] the manifest's requirement
      # @param needs [Array<Hash>] the manifest's needs ({command:, why:, hint:})
      # @param marks [Array<FileStanding::Behind>] files an upgrade left behind;
      #   their entries get conflict: true, and what the Behind says
      # @param incoming_dir [String, nil] the bundle's source: each marked file's
      #   digest goes with the mark (incoming_sha: what Remerge retries) and its
      #   text is saved (#incoming_path), a settled file's going. A mark from an
      #   older chi that stays a mark gets legacy_base: true
      #   (InstalledBundle.legacy_mark?)
      # @param includes [Array<String>, nil] a profile's recorded members
      #   (MemoryBundle::Profile); nil for a plain bundle
      # @param scripts_files [Hash] file name => installed script; the
      #   sha256 of each is recorded (ContextFetch checks it before a run)
      # @param context_providers [Array<ContextProviders::Provider>]
      # @param block_renderers [Array<BlockRenderers::Renderer>]
      # @param dev [Boolean] a dev install: its files are links to the
      #   source, recorded as DEV_SHA (no sha256 check) with "dev": true
      # @param manifest_from [String, nil] the source dir: its manifest.yml is
      #   kept at #kept_manifest_path (a copy, a link for a dev install),
      #   recorded as manifest_sha (DEV_SHA for dev), with installed_by: this
      #   chi's VERSION. nil leaves the kept file, and the record's
      #   manifest_sha and installed_by, as they are. The keys a record mirrors
      #   (requires_chi … setting_types) are still written from the kwargs:
      #   an older chi sharing this memories dir reads only them
      #   (docs/internals/bundles.md); a key a later manifest gains is never added
      def write(files:, scope:, version:, source_path:, hooks: {}, trust_level: nil, source_commit: nil, hooks_files: {},
                guardrails_files: {}, plugin_file: nil, plugin_required: false, requires_chi: nil, needs: nil, marks: [], incoming_dir: nil, includes: nil,
                scripts_files: {}, context_providers: [], block_renderers: [], file_descriptions: {}, session_settings: [], session_setting_types: {}, settings: nil, setting_types: {},
                dev: false, manifest_from: nil)
        FileUtils.mkdir_p(@bundle_dir)
        bases_dir = File.join(@bundle_dir, "bases")
        FileUtils.mkdir_p(bases_dir)

        # The existing record: its file entries merge with these, and its
        # files and hooks not in this install are stale.
        existing = record
        merged_entries = existing ? existing.files.dup : {}
        marked = marks.to_h { |mark| [mark.file, mark] }

        files.each do |file_key, file_path|
          legacy = InstalledBundle.legacy_mark?(merged_entries[file_key])
          note = merged_entries.fetch(file_key, {}).slice(*MERGE_NOTE_FIELDS.map(&:to_sym))
          if file_path
            content = File.read(file_path)
            # Save base snapshot — use file_key as-is (it already includes .md).
            File.write(File.join(bases_dir, file_key), content)
            merged_entries[file_key] = { checksum: Digest::SHA256.hexdigest(content) }
          else
            merged_entries[file_key] = merged_entries.fetch(file_key, {}).slice(:checksum)
          end
          merged_entries[file_key].merge!(note)
          if (mark = marked[file_key.to_s])
            merged_entries[file_key].merge!(mark_fields(mark))
            merged_entries[file_key][:legacy_base] = true if legacy
            sha = incoming_dir && incoming_sha(File.join(incoming_dir, file_key.to_s))
            merged_entries[file_key][:incoming_sha] = sha if sha
          end
          merged_entries[file_key][:description] = file_descriptions[file_key.to_s] if file_descriptions[file_key.to_s]
        end

        # Prune stale base snapshots for files no longer in the bundle.
        if existing
          existing.files.each_key do |old_key_str|
            next if files.key?(old_key_str) || files.key?(old_key_str.to_sym)

            old_base = File.join(bases_dir, old_key_str)
            FileUtils.rm_f(old_base)
            merged_entries.delete(old_key_str)
          end
        end

        # Hooks provenance: persist metadata and base snapshots for hooks
        hooks_map = {}
        # Incoming hooks: basename => BundleHook (or its metadata hash)
        normalized_hooks = {}
        if hooks.is_a?(Hash)
          hooks.each do |k, v|
            next unless k.is_a?(String) && !k.empty?
            next unless v.is_a?(Hash) || v.is_a?(BundleHook)

            normalized_hooks[k] = BundleHook.parse(v)
          end
        end
        # Prune stale hook bases
        existing&.hooks&.each_key do |old_key_str|
          FileUtils.rm_f(File.join(bases_dir, old_key_str)) unless normalized_hooks.key?(old_key_str)
        end
        # Save base snapshots for hooks where a file path was provided, and
        # record the sha256 of the installed file itself: the load-time check
        # compares against it, and a declared sha can be wrong (installing
        # only warns about that).
        hooks_files = {} unless hooks_files.is_a?(Hash)
        normalized_hooks.each do |k, hook|
          src = hooks_files[k] || hooks_files[k.to_sym]
          hook = hook.with(sha256: BundleHook.of_file(src.to_s).sha256) if src && File.exist?(src.to_s)
          hook = hook.with(sha256: DEV_SHA) if dev
          hooks_map[k] = hook.to_record
          next unless src && File.exist?(src.to_s)

          begin
            File.write(File.join(bases_dir, k), File.read(src.to_s))
          rescue StandardError
            nil
          end
        end

        manifest_data = {
          "name" => @name,
          "version" => version.to_s,
          "scope" => scope.to_s,
          "source" => source_path.to_s,
          "installed_at" => DateTime.now.iso8601,
          "files" => merged_entries,
          "hooks" => hooks_map
        }
        manifest_data["dev"] = true if dev
        if guardrails_files.is_a?(Hash) && !guardrails_files.empty?
          manifest_data["guardrails"] = guardrails_files.sort.to_h do |basename, path|
            [basename.to_s, { "sha256" => dev ? DEV_SHA : FileDigest.sha256(path.to_s) }]
          end
        end
        manifest_data["source_commit"] = source_commit.to_s if source_commit && !source_commit.to_s.empty?
        FileUtils.rm_rf(File.join(bases_dir, "plugin"))
        if plugin_file
          content = File.binread(plugin_file.to_s) # the base snapshot's bytes
          manifest_data["plugin"] = { "file" => File.basename(plugin_file.to_s),
                                      "sha256" => dev ? DEV_SHA : FileDigest.sha256(plugin_file.to_s) }
          manifest_data["plugin"]["required"] = true if plugin_required
          FileUtils.mkdir_p(File.join(bases_dir, "plugin"))
          File.binwrite(plugin_base_path(File.basename(plugin_file.to_s)), content)
        end
        manifest_data.merge!(self.class.mirror_fields(trust_level: trust_level, requires_chi: requires_chi, needs: needs,
                                                      context_providers: context_providers, block_renderers: block_renderers,
                                                      session_settings: session_settings, session_setting_types: session_setting_types,
                                                      settings: settings, setting_types: setting_types))
        manifest_data["includes"] = includes.map(&:to_s) if includes.is_a?(Array)
        unless scripts_files.empty?
          manifest_data["scripts"] = scripts_files.sort.to_h do |file, path|
            [file.to_s, { "sha256" => dev ? DEV_SHA : FileDigest.sha256(path.to_s) }]
          end
        end
        manifest_data.merge!(kept_manifest_fields(existing, manifest_from, dev))

        write_manifest(manifest_data)
        marked.each_key { |key| save_incoming(key, incoming_dir) }
        prune_incoming(marked.keys)
      end

      # After a conflict was settled: each file's base becomes the incoming
      # file and its conflict mark goes. The rest of the manifest (its
      # description too) stays as is. A file whose incoming copy is gone keeps
      # its mark and base: taking the file on disk would make the user's text
      # the base, and the next upgrade would fast-forward over it.
      # @param conflicts [Hash{String => Hash}] Installer#conflicts
      # @return [Array<String>] the files it settled
      def resolve_conflicts(conflicts)
        return [] unless installed?

        raw = JSON.parse(File.read(File.join(@bundle_dir, "manifest.json")))
        raw["files"] ||= {}
        settled = conflicts.filter_map do |file_key, info|
          key = file_key.to_s
          next unless raw["files"].key?(key) && info[:incoming] && File.exist?(info[:incoming])

          content = File.read(info[:incoming])
          File.write(base_path(key), content)
          raw["files"][key] = raw["files"][key].except(*MARK_FIELDS).merge("checksum" => Digest::SHA256.hexdigest(content))
          key
        end
        write_manifest(raw)
        prune_incoming(marked_in(raw))
        settled
      end

      # A missing file was put back with the bundle's bytes: +path+ is its base,
      # its entry is made or rebuilt (no mark), and the rest of the manifest stays.
      def record_restored(file_key, path, description: nil)
        raw = JSON.parse(File.read(File.join(@bundle_dir, "manifest.json")))
        content = File.binread(path)
        File.binwrite(base_path(file_key), content)
        entry = { "checksum" => Digest::SHA256.hexdigest(content) }
        kept = description || raw.dig("files", file_key, "description")
        entry["description"] = kept if kept
        (raw["files"] ||= {})[file_key] = entry
        write_manifest(raw)
        prune_incoming(marked_in(raw))
      end

      # What a retry found of files still marked: the mark says it, its digest
      # recorded if it had none (a mark made before chi kept it; legacy_base keeps
      # that known, InstalledBundle.legacy_mark?), the bundle's text saved. The
      # rest of the manifest stays.
      # @param marks [Array<FileStanding::Behind>]
      # @param incoming_dir [String] the bundle's source
      def refresh_marks(marks, incoming_dir)
        return unless installed?

        raw = JSON.parse(File.read(File.join(@bundle_dir, "manifest.json")))
        marks.each do |mark|
          entry = raw.dig("files", mark.file)
          next unless entry&.fetch("conflict", nil)

          save_incoming(mark.file, incoming_dir)
          entry.reject! { |field, _| %w[why missed missed_places].include?(field) }
          entry.merge!(mark_fields(mark).transform_keys(&:to_s))
          sha = incoming_sha(File.join(incoming_dir, mark.file))
          entry.merge!("incoming_sha" => sha, "legacy_base" => true) if sha && !entry["incoming_sha"]
        end
        write_manifest(raw)
      end

      # Every merge leaves a note on the file's entry, one no one may have seen (a
      # worker's start logs it and nothing else, an automatic update's rows are
      # read by no one). It stays through later upgrades, until #clear_merge_notes,
      # which a report someone reads does once it has shown the merge.
      # @param files [Array<String>]
      # @param version [String] what merged
      # @param trash [String, nil] the dir holding the old copy
      def note_merged(files, version:, trash:, at: Time.now)
        return unless installed?

        raw = JSON.parse(File.read(File.join(@bundle_dir, "manifest.json")))
        files.each do |key|
          raw.dig("files", key)&.merge!({ "merged_version" => version.to_s, "merged_at" => at.iso8601, "merged_trash" => trash }.compact)
        end
        write_manifest(raw)
      end

      # These notes go, and a later merge's on the same file stays. A note that
      # can't be cleared shows once more: nothing about it fails a report.
      # @param notes [Array<FileStanding::MergeNote>] as #record gave them, read
      #   before a run
      # @param files [Array<String>] files whose note goes whatever it says: the run
      #   just merged or replaced them. Another file's, a worker's meanwhile, stays.
      def clear_merge_notes(notes, files: [])
        return if notes.empty? && files.empty?

        raw = JSON.parse(File.read(File.join(@bundle_dir, "manifest.json")))
        stale = notes.select do |note|
          entry = raw.dig("files", note.file)
          entry && entry["merged_version"] == note.version && entry["merged_at"] == note.at
        end
        (stale.map(&:file) + files).each do |file|
          entry = raw.dig("files", file)
          MERGE_NOTE_FIELDS.each { |field| entry.delete(field) } if entry
        end
        write_manifest(raw)
      rescue JSON::ParserError, SystemCallError
        nil
      end

      # Keeps +dir+/manifest.yml for an installed bundle whose record has no
      # usable kept manifest (InstalledBundle#manifest_unkept?: an older chi
      # wrote it, or the file is gone), when +dir+ is the source of what's
      # installed: its manifest names this bundle at the recorded version and
      # says what the record keeps (#manifest_difference), and every sha the
      # record has for a memory, plugin, hook, script or rule is the source
      # file's. Then the file is copied to #kept_manifest_path and the
      # record gains its manifest_sha, and nothing else changes (installed_at,
      # the mirror, installed_by). A dev record is never adopted: its next
      # install --dev links the file. Read-only with dry_run.
      # @return [String, nil] why it wasn't (wouldn't be) kept, nil when it was
      def adopt_manifest(dir, dry_run: false)
        bundle = record
        return "#{@name} isn't installed" unless bundle
        return "#{@name} is a dev install" if bundle.dev
        return "#{@name} keeps its manifest already" unless bundle.manifest_unkept?

        source = File.join(dir.to_s, "manifest.yml")
        return "#{dir} has no manifest.yml" unless File.file?(source)

        # One read: the bytes checked are the bytes kept.
        bytes = File.binread(source)
        why = adoption_mismatch(bundle, dir.to_s, bytes)
        return why if why || dry_run

        AtomicFile.write(kept_manifest_path, bytes)
        raw = JSON.parse(File.read(File.join(@bundle_dir, "manifest.json")))
        write_manifest(raw.merge("manifest_sha" => "sha256:#{Digest::SHA256.hexdigest(bytes)}"))
        nil
      rescue JSON::ParserError, SystemCallError => e
        "#{@name}'s record can't take it: #{e.message}"
      end

      # The installed bundle's record, nil when it isn't installed.
      # @return [InstalledBundle, nil]
      # @raise [JSON::ParserError] manifest.json doesn't parse
      def record
        InstalledBundle.read(@name, File.join(@bundle_dir, "manifest.json"))
      end

      # manifest.json as it is on disk, symbol keys (nil if not installed).
      # Readers take #record.
      def read
        manifest_path = File.join(@bundle_dir, "manifest.json")
        return nil unless File.exist?(manifest_path)

        JSON.parse(File.read(manifest_path), symbolize_names: true)
      end

      # Write aside and rename, so a reader in another process (a parallel
      # chi start) never parses a truncated manifest.json.
      def write_manifest(manifest_data)
        manifest_path = File.join(@bundle_dir, "manifest.json")
        AtomicFile.write(manifest_path, JSON.pretty_generate(manifest_data))
      end
      private :write_manifest

      # The record's manifest_sha and installed_by: a fresh kept copy's, or
      # (no manifest_from) the existing record's, the kept file left alone.
      def kept_manifest_fields(existing, manifest_from, dev)
        if manifest_from.nil?
          return { "manifest_sha" => existing&.manifest_sha, "installed_by" => existing&.installed_by }.compact
        end

        sha = keep_manifest(File.join(manifest_from.to_s, "manifest.yml"), dev)
        sha ? { "manifest_sha" => sha, "installed_by" => Samagotchi::VERSION } : {}
      end
      private :kept_manifest_fields

      # +source+ to #kept_manifest_path: a link to its realpath for a dev
      # install (DEV_SHA), else a copy written aside and renamed (a link left
      # by a dev install is replaced, never written through), its sha.
      # A source with no manifest.yml leaves none kept: nil.
      def keep_manifest(source, dev)
        dest = kept_manifest_path
        unless File.file?(source)
          FileUtils.rm_f(dest)
          return nil
        end

        if dev
          FileUtils.rm_f(dest)
          File.symlink(File.realpath(source), dest)
          return DEV_SHA
        end
        AtomicFile.write(dest, File.binread(source))
        FileDigest.sha256(dest)
      end
      private :keep_manifest

      # Why +dir+ isn't the source of what +bundle+ installed (#adopt_manifest), nil when it is.
      def adoption_mismatch(bundle, dir, bytes)
        manifest = begin
          parsed(bytes)
        rescue Manifest::ValidationError, Psych::Exception, EncodingError => e
          return "#{dir}'s manifest.yml doesn't read: #{e.message}"
        end
        found = "#{manifest.name} #{manifest.version}"
        return "#{dir} has #{found}, not #{@name} #{bundle.version}" unless manifest.name == @name
        return "#{dir} has #{found}, not #{bundle.version}" unless manifest.version == bundle.version.to_s

        key = manifest_difference(bundle, manifest)
        return "#{dir}'s manifest.yml isn't the installed one (#{key})" if key

        installed_shas(bundle, manifest).each do |rel, sha|
          next if self.class.recorded_sha(sha).empty?
          return "#{dir}'s #{rel} isn't the installed one" unless self.class.file_sha(File.join(dir, rel)) == self.class.recorded_sha(sha)
        end
        nil
      end
      private :adoption_mismatch

      # +bytes+ as a manifest.yml, read where nothing else can change it.
      def parsed(bytes)
        Dir.mktmpdir("chi-adopt-") do |tmp|
          path = File.join(tmp, "manifest.yml")
          File.binwrite(path, bytes)
          Manifest.new(path: path)
        rescue Manifest::ValidationError => e
          raise Manifest::ValidationError, e.message.gsub(tmp, "the source")
        end
      end
      private :parsed

      # The SINCE entry of a mirrored key whose shape a newer chi reads.
      MIRROR_SINCE = { "session_setting_types" => "session_settings.types", "setting_types" => "settings.types" }.freeze

      # The first manifest key in which +manifest+ says other than what the
      # record keeps, nil when none: each mirrored key as #write records it (one
      # the record lacks is fine only when an older chi couldn't have known it:
      # Manifest::SINCE has it), then each recorded hook's events, on_error and
      # priority.
      def manifest_difference(bundle, manifest)
        recorded = plain(bundle.mirror)
        source = plain(self.class.mirror_fields(
          trust_level: manifest.trust_level, requires_chi: manifest.requires_chi, needs: manifest.needs,
          context_providers: manifest.context_providers, block_renderers: manifest.block_renderers,
          session_settings: manifest.session_settings, session_setting_types: manifest.session_setting_types,
          settings: manifest.settings, setting_types: manifest.setting_types
        ))
        differing = InstalledBundle::MIRROR_KEYS.find do |key|
          next false if recorded[key] == source[key]

          !(recorded[key].nil? && Manifest::SINCE.key?(MIRROR_SINCE.fetch(key, key)))
        end
        return differing if differing

        same_hooks = bundle.hooks.all? do |file, hook|
          theirs = manifest.hooks.fetch(file, BundleHook.new)
          [hook.events, hook.on_error, hook.priority] == [theirs.events, theirs.on_error, theirs.priority]
        end
        same_hooks ? nil : "hooks"
      end
      private :manifest_difference

      def plain(value) = JSON.parse(JSON.generate(value))
      private :plain

      # Each file the record has a sha for, by its path in the bundle's source
      # => that sha: the plugin, hooks, scripts, rules, and each memory whose
      # entry has a checksum and no conflict mark (its base is the bundle's text).
      def installed_shas(bundle, manifest)
        shas = bundle.files.each_with_object({}) do |(key, entry), acc|
          acc[key] = entry[:checksum].to_s unless entry[:conflict] || entry[:checksum].to_s.empty?
        end
        if bundle.plugin
          file = manifest.plugin && manifest.plugin[:file].to_s
          shas[file && File.basename(file) == bundle.plugin.file ? file : bundle.plugin.file] = bundle.plugin.sha256
        end
        bundle.hooks.each { |file, hook| shas["hooks/#{file}"] = hook.sha256 }
        bundle.scripts.each { |file, sha| shas["scripts/#{file}"] = sha }
        bundle.guardrails.each { |file, sha| shas["guardrails/#{file}"] = sha }
        shas
      end
      private :installed_shas

      def mark_fields(mark)
        { conflict: true, why: mark.why, missed: mark.missed.empty? ? nil : mark.missed,
          missed_places: mark.places.zero? ? nil : mark.places }.compact
      end
      private :mark_fields

      def incoming_sha(path)
        FileDigest.hex(path)
      rescue SystemCallError
        nil
      end
      private :incoming_sha

      # The saved text is a convenience, and an install's assets are already in
      # place when this runs: failing here would leave them under the old record's
      # shas, and a plugin that doesn't load. So nothing about it fails a write.
      def save_incoming(file_key, incoming_dir)
        source = incoming_dir && File.join(incoming_dir, file_key.to_s)
        return unless source && File.exist?(source)

        FileUtils.mkdir_p(File.dirname(incoming_path(file_key)))
        FileUtils.cp(source, incoming_path(file_key))
      rescue SystemCallError
        nil
      end
      private :save_incoming

      def marked_in(raw) = (raw["files"] || {}).select { |_, entry| entry["conflict"] }.keys
      private :marked_in

      # Each file that settled loses its saved text; the folder goes with the last.
      # A file key can nest (a manifest's `files:` may name a path), so every file
      # under incoming/ at any depth is looked at, and a dir the prune empties goes
      # with it, deepest first.
      def prune_incoming(keep)
        dir = File.join(@bundle_dir, "incoming")
        return unless Dir.exist?(dir)

        keep = keep.map(&:to_s)
        entries = Dir.glob("**/*", base: dir)
        entries.each do |rel|
          FileUtils.rm_f(File.join(dir, rel)) if File.file?(File.join(dir, rel)) && !keep.include?(rel)
        end
        entries.select { |rel| File.directory?(File.join(dir, rel)) }
               .sort_by { |rel| -rel.count("/") } # deepest first, so a parent is checked after its children
               .each { |rel| Dir.rmdir(File.join(dir, rel)) if Dir.empty?(File.join(dir, rel)) }
        Dir.rmdir(dir) if Dir.empty?(dir)
      rescue SystemCallError
        nil
      end
      private :prune_incoming

      # Returns the path to a base snapshot for a given file key.
      def base_path(file_key)
        File.join(@bundle_dir, "bases", file_key)
      end

      # Checks whether the bundle is installed.
      def installed?
        !record.nil?
      end
    end
  end
end
