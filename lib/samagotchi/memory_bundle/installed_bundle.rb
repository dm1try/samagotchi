# frozen_string_literal: true

require "json"
require_relative "file_digest"
require_relative "../memory_paths"
require_relative "bundle_hook"
require_relative "plugin_ref"

module Samagotchi
  module MemoryBundle
    # Only what reports on an edited file needs it.
    autoload :FileStanding, File.expand_path("file_standing", __dir__)
    autoload :InstalledManifest, File.expand_path("installed_manifest", __dir__)

    # An installed bundle's record, as Provenance#write keeps it in
    # <bundles>/<name>/manifest.json: identity, shas, files and marks.
    # Reading is tolerant: an older record lacks keys a newer chi writes,
    # and a key that is missing or of the wrong shape reads as empty (nil
    # for the optional strings and lists). Its manifest data (requires_chi,
    # trust_level, needs, providers, renderers, settings…) is read through
    # #manifest, never off the record.
    #
    #   files       file key ("x.md") => { checksum:, conflict:, incoming_sha:, legacy_base:, why:, missed:, missed_places:,
    #               description: } (symbol keys);
    #               incoming_sha: the bundle text a conflict mark speaks of, nil on an older mark;
    #               legacy_base: true on an older mark that has since got its incoming_sha (.legacy_mark?);
    #               why, missed, missed_places: FileStanding::Behind's, nil on an older mark;
    #               merged_version, merged_at, merged_trash: a merge no report has shown (Provenance#note_merged)
    #   hooks       basename => BundleHook
    #   guardrails  basename => recorded sha256 ("" when none)
    #   scripts     file name => recorded sha256 ("" when none)
    #   plugin      PluginRef, nil without one
    #   includes    a profile's recorded members, nil for a plain bundle
    #   mirror      the record's frozen copy of the manifest keys (MIRROR_KEYS,
    #               string keys, the values as recorded), which only
    #               InstalledManifest reads: requires_chi, trust_level, needs,
    #               context_providers, block_renderers, session_settings,
    #               session_setting_types, settings, setting_types. A key a
    #               later manifest gains is never mirrored
    #   dev         a dev install (`chi bundle install --dev`): its source is
    #               the folder it links to and its files carry Provenance::DEV_SHA
    #   manifest_sha  the kept manifest.yml's recorded sha256 (Provenance::DEV_SHA
    #               for a dev install's link), nil on a record written before
    #               chi kept it, or rewritten since by a chi that doesn't
    #   installed_by  the chi VERSION that wrote the record with its kept
    #               manifest, nil when manifest_sha is
    #   dir         its .bundles/<name> folder (.read, Provenance.each_installed),
    #               nil for a record parsed alone or one that doesn't read
    #   error       why manifest.json couldn't be read (the rest empty), else nil
    class InstalledBundle < Data.define(:name, :version, :scope, :source, :installed_at, :source_commit, :files, :hooks,
                                        :guardrails, :scripts, :plugin, :includes, :dev, :mirror, :manifest_sha,
                                        :installed_by, :dir, :error)
      OPTIONAL = { version: nil, scope: nil, source: nil, installed_at: nil, source_commit: nil, files: {}, hooks: {},
                   guardrails: {}, scripts: {}, plugin: nil, includes: nil, dev: false, mirror: {}, manifest_sha: nil,
                   installed_by: nil, dir: nil, error: nil }.freeze

      # The manifest keys a record mirrors, as Provenance#write records them.
      MIRROR_KEYS = %w[requires_chi trust_level needs context_providers block_renderers session_settings
                       session_setting_types settings setting_types].freeze

      def initialize(name:, **fields)
        fields[:mirror] = fields[:mirror].to_h.transform_keys(&:to_s).slice(*MIRROR_KEYS).freeze if fields.key?(:mirror)
        super(name: name, **OPTIONAL, **fields)
      end

      # Whether a file's entry is a conflict mark from an older chi: no
      # incoming_sha, or legacy_base. Such a mark's base may be the user's own
      # text (0.149 took it for a file with no base). Getting its digest later
      # must not make it look new, so legacy_base stays until the mark goes.
      def self.legacy_mark?(entry) = !!entry && entry[:conflict] == true && (entry[:legacy_base] == true || !entry[:incoming_sha])

      # The record at +path+, nil when there is none.
      # @raise [JSON::ParserError, SystemCallError] it doesn't read
      def self.read(name, path)
        return nil unless File.exist?(path)

        parse(name, JSON.parse(File.read(path)), File.dirname(path))
      end

      # One that couldn't be read: +message+ says why.
      def self.unreadable(name, message) = new(name: name, error: message)

      # @param raw [Hash] the parsed manifest.json (string or symbol keys);
      #   anything else reads as unreadable
      # @param dir [String, nil] its .bundles/<name> folder
      def self.parse(name, raw, dir = nil)
        return unreadable(name, "manifest.json is not an object") unless raw.is_a?(Hash)

        h = raw.transform_keys(&:to_s)
        new(name: name, version: string(h["version"]), scope: string(h["scope"]), source: string(h["source"]),
            installed_at: string(h["installed_at"]), source_commit: string(h["source_commit"]),
            files: mapping(h["files"]) { |entry| entry.is_a?(Hash) ? entry.transform_keys(&:to_sym) : {} },
            hooks: mapping(h["hooks"]) { |meta| BundleHook.parse(meta) },
            guardrails: mapping(h["guardrails"]) { |meta| sha(meta) },
            scripts: mapping(h["scripts"]) { |meta| sha(meta) },
            plugin: PluginRef.parse(h["plugin"]),
            includes: h["includes"].is_a?(Array) ? h["includes"].map(&:to_s) : nil,
            dev: h["dev"] == true, mirror: h.slice(*MIRROR_KEYS).compact,
            manifest_sha: string(h["manifest_sha"]), installed_by: string(h["installed_by"]), dir: dir)
      end

      def self.string(value) = value&.to_s

      def self.mapping(value, &)
        value.is_a?(Hash) ? value.to_h { |k, v| [k.to_s, yield(v)] } : {}
      end

      def self.sha(meta) = meta.is_a?(Hash) ? meta.transform_keys(&:to_s)["sha256"].to_s : ""
      private_class_method :string, :mapping, :sha

      def error? = !error.nil?

      # Its kept manifest.yml (Provenance#kept_manifest_path), nil with no dir.
      def kept_manifest_path = dir && File.join(dir, "manifest.yml")

      # Whether it lacks a kept manifest.yml chi can read (Provenance#adopt_manifest
      # keeps one): an older chi's record has no manifest_sha (with or without a
      # file there, InstalledManifest's legacy and :stale), or the file it
      # recorded is gone (:missing). false with no dir.
      def manifest_unkept? = !dir.nil? && (manifest_sha.to_s.empty? || !File.file?(kept_manifest_path))

      # What its manifest says (requires_chi, needs, providers,
      # renderers, settings…): the one way to read manifest data of an
      # installed bundle.
      # @return [InstalledManifest]
      def manifest = InstalledManifest.of(self)

      # The scope its files went to: "system" when none is recorded.
      def effective_scope = scope.to_s.strip.empty? ? "system" : scope

      # A profile (meta bundle): it records its members.
      def profile? = !includes.nil?

      def owns?(file_key) = files.key?(file_key.to_s)

      # The plugin's file => its recorded sha256, as guardrails and scripts read.
      def plugin_shas = plugin ? { plugin.file => plugin.sha256 } : {}

      # The marked files that stay behind: one that isn't there is a missing file,
      # and one with the bundle's bytes has nothing left to miss.
      # @param target_dir [String, nil] where its files are; a scope this chi can't
      #   resolve has none, and nothing is known of them
      # @return [Array<FileStanding::Behind>]
      def behind_files(target_dir = MemoryPaths.scope_dir(effective_scope))
        return [] unless target_dir

        files.filter_map { |key, entry| behind_entry(key, entry) if behind_file?(key, File.join(target_dir, key)) }
      end

      # FileStanding.behind? for this record's file. An older mark names no text,
      # but a source still on disk holds it: level with that, it has missed nothing.
      def behind_file?(key, path)
        entry = files.fetch(key)
        FileStanding.behind?(path, entry, incoming_sha: entry[:incoming_sha] || source_sha(key))
      end

      # The merges no chi update has shown yet.
      # @return [Array<FileStanding::MergeNote>]
      def merge_notes
        files.filter_map do |key, entry|
          next unless entry[:merged_version]

          FileStanding::MergeNote.new(file: key, version: entry[:merged_version], at: entry[:merged_at], trash: entry[:merged_trash])
        end
      end

      # The file's mark as a report reads it.
      def behind_entry(key, entry = files.fetch(key))
        FileStanding::Behind.new(file: key, version: version, why: entry[:why], missed: entry[:missed], places: entry[:missed_places],
                                 unsure: !entry[:incoming_sha] && !entry[:why])
      end

      def source_sha(key)
        FileDigest.hex(File.join(source.to_s, key))
      rescue SystemCallError
        nil
      end
      private :source_sha
    end
  end
end
