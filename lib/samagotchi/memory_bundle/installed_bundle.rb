# frozen_string_literal: true

require "json"
require_relative "bundle_hook"
require_relative "plugin_ref"

module Samagotchi
  module MemoryBundle
    # An installed bundle's record, as Provenance#write keeps it in
    # <bundles>/<name>/manifest.json. Reading is tolerant: an older record
    # lacks keys a newer chi writes, and a key that is missing or of the
    # wrong shape reads as empty (nil for the optional strings and lists).
    #
    #   files       file key ("x.md") => { checksum:, conflict:, description: } (symbol keys)
    #   hooks       basename => BundleHook
    #   guardrails  basename => recorded sha256 ("" when none)
    #   scripts     file name => recorded sha256 ("" when none)
    #   plugin      PluginRef, nil without one
    #   needs, context_providers
    #               the lists as recorded (nil when absent): Manifest.parse_needs
    #               and ContextProviders.parse_list check them
    #   includes    a profile's recorded members, nil for a plain bundle
    #   error       why manifest.json couldn't be read (the rest empty), else nil
    class InstalledBundle < Data.define(:name, :version, :scope, :source, :installed_at, :trust_level, :source_commit,
                                        :requires_chi, :files, :hooks, :guardrails, :scripts, :plugin, :needs,
                                        :includes, :context_providers, :error)
      OPTIONAL = { version: nil, scope: nil, source: nil, installed_at: nil, trust_level: nil, source_commit: nil,
                   requires_chi: nil, files: {}, hooks: {}, guardrails: {}, scripts: {}, plugin: nil, needs: nil,
                   includes: nil, context_providers: nil, error: nil }.freeze

      def initialize(name:, **fields)
        super(name: name, **OPTIONAL, **fields)
      end

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
            includes: h["includes"].is_a?(Array) ? h["includes"].map(&:to_s) : nil)
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

      def needs? = needs.is_a?(Array) && !needs.empty?

      def context_providers? = context_providers.is_a?(Array) && !context_providers.empty?
    end
  end
end
