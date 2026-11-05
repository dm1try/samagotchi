# frozen_string_literal: true

require "json"
require_relative "../memory_paths"
require_relative "bundle_hook"
require_relative "file_standing"
require_relative "plugin_ref"

module Samagotchi
  module MemoryBundle
    # An installed bundle's record, as Provenance#write keeps it in
    # <bundles>/<name>/manifest.json. Reading is tolerant: an older record
    # lacks keys a newer chi writes, and a key that is missing or of the
    # wrong shape reads as empty (nil for the optional strings and lists).
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
    #   needs, context_providers
    #               the lists as recorded (nil when absent): Manifest.parse_needs
    #               and ContextProviders.parse_list check them
    #   includes    a profile's recorded members, nil for a plain bundle
    #   session_settings
    #               the keys a session may set (chi --set), [] when none
    #   session_setting_types
    #               {key => type} for the typed ones (Manifest::SESSION_SETTING_TYPES), {} when none
    #   settings    the keys config.yml bundles: <name>: may have, nil when the
    #               manifest says nothing of them (BundleSettingsCheck)
    #   setting_types
    #               {key => type} for the typed ones, {} when none
    #   dev         a dev install (`chi bundle install --dev`): its source is
    #               the folder it links to and its files carry Provenance::DEV_SHA
    #   error       why manifest.json couldn't be read (the rest empty), else nil
    class InstalledBundle < Data.define(:name, :version, :scope, :source, :installed_at, :trust_level, :source_commit,
                                        :requires_chi, :files, :hooks, :guardrails, :scripts, :plugin, :needs,
                                        :includes, :context_providers, :session_settings, :session_setting_types, :settings,
                                        :setting_types, :dev,
                                        :error)
      OPTIONAL = { version: nil, scope: nil, source: nil, installed_at: nil, trust_level: nil, source_commit: nil,
                   requires_chi: nil, files: {}, hooks: {}, guardrails: {}, scripts: {}, plugin: nil, needs: nil,
                   includes: nil, context_providers: nil, session_settings: [], session_setting_types: {}, settings: nil, setting_types: {}, dev: false,
                   error: nil }.freeze

      def initialize(name:, **fields)
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

        parse(name, JSON.parse(File.read(path)))
      end

      # One that couldn't be read: +message+ says why.
      def self.unreadable(name, message) = new(name: name, error: message)

      # @param raw [Hash] the parsed manifest.json (string or symbol keys);
      #   anything else reads as unreadable
      def self.parse(name, raw)
        return unreadable(name, "manifest.json is not an object") unless raw.is_a?(Hash)

        h = raw.transform_keys(&:to_s)
        new(name: name, version: string(h["version"]), scope: string(h["scope"]), source: string(h["source"]),
            installed_at: string(h["installed_at"]), trust_level: string(h["trust_level"]),
            source_commit: string(h["source_commit"]), requires_chi: string(h["requires_chi"]),
            files: mapping(h["files"]) { |entry| entry.is_a?(Hash) ? entry.transform_keys(&:to_sym) : {} },
            hooks: mapping(h["hooks"]) { |meta| BundleHook.parse(meta) },
            guardrails: mapping(h["guardrails"]) { |meta| sha(meta) },
            scripts: mapping(h["scripts"]) { |meta| sha(meta) },
            plugin: PluginRef.parse(h["plugin"]), needs: h["needs"], context_providers: h["context_providers"],
            includes: h["includes"].is_a?(Array) ? h["includes"].map(&:to_s) : nil,
            session_settings: h["session_settings"].is_a?(Array) ? h["session_settings"].map(&:to_s) : [],
            session_setting_types: mapping(h["session_setting_types"]) { |type| type.to_s },
            settings: h["settings"].is_a?(Array) ? h["settings"].map(&:to_s) : nil,
            setting_types: mapping(h["setting_types"]) { |type| type.to_s },
            dev: h["dev"] == true)
      end

      def self.string(value) = value&.to_s

      def self.mapping(value, &)
        value.is_a?(Hash) ? value.to_h { |k, v| [k.to_s, yield(v)] } : {}
      end

      def self.sha(meta) = meta.is_a?(Hash) ? meta.transform_keys(&:to_s)["sha256"].to_s : ""
      private_class_method :string, :mapping, :sha

      def error? = !error.nil?

      # The scope its files went to: "system" when none is recorded.
      def effective_scope = scope.to_s.strip.empty? ? "system" : scope

      # A bundle with no trust_level counts as experimental.
      def experimental? = (trust_level || "experimental") == "experimental"

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

        files.filter_map { |key, entry| behind_entry(key, entry) if FileStanding.behind?(File.join(target_dir, key), entry) }
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

      def needs? = needs.is_a?(Array) && !needs.empty?

      def context_providers? = context_providers.is_a?(Array) && !context_providers.empty?
    end
  end
end
