# frozen_string_literal: true

require_relative "../context_providers"
require_relative "../version"
require_relative "manifest"

module Samagotchi
  autoload :BlockRenderers, File.expand_path("../block_renderers", __dir__)

  module MemoryBundle
    # The one answer to "this installed bundle's manifest": what its
    # manifest.yml says, as the readers of an installed bundle take it
    # (InstalledBundle#manifest). Identity and state stay on the record
    # (InstalledBundle: name, version, source, the plugin's file, every
    # sha, files, marks, a profile's members); manifest data is read here.
    #
    # Built from the record's frozen mirror of the manifest keys today
    # (origin :record), so a record that lacks a key reads it as empty.
    # Each key is parsed on its own: one that doesn't parse reads as empty
    # and its message is in +problems+ (key => message), so one bad key
    # never costs the rest. A reader that logged such a key logs
    # problems[key].
    #
    #   requires_chi, trust_level   the strings as recorded, nil when none
    #   description                 nil: the record keeps none
    #   hooks                       basename => BundleHook (the record's)
    #   needs                       Manifest.parse_needs'
    #   script_names                the scripts/ files it lists
    #   context_providers           Array<ContextProviders::Provider>
    #   block_renderers             Array<BlockRenderers::Renderer>
    #   session_settings, session_setting_types, settings, setting_types
    #                               as InstalledBundle recorded them (settings
    #                               nil when the manifest said nothing of them)
    #   file_descriptions           file key => the memory's description
    #   includes                    a profile's members, nil for a plain bundle
    #   unknown_keys                the keys this chi doesn't know ([] today)
    #   origin                      :record
    InstalledManifest = Data.define(:name, :version, :requires_chi, :trust_level, :description, :hooks, :needs,
                                    :script_names, :context_providers, :block_renderers, :session_settings,
                                    :session_setting_types, :settings, :setting_types, :file_descriptions,
                                    :includes, :unknown_keys, :problems, :origin) do
      # @param bundle [InstalledBundle]
      # @return [InstalledManifest]
      def self.of(bundle)
        raw = recorded(bundle)
        problems = {}
        new(name: bundle.name, version: bundle.version,
            requires_chi: raw["requires_chi"]&.to_s, trust_level: raw["trust_level"]&.to_s, description: nil,
            hooks: bundle.hooks,
            needs: parsed(problems, "needs", [], Manifest::ValidationError) { Manifest.parse_needs(raw["needs"]) },
            script_names: bundle.scripts.keys,
            context_providers: parsed(problems, "context_providers", []) { ContextProviders.parse_list(raw["context_providers"]) },
            block_renderers: parsed(problems, "block_renderers", []) { BlockRenderers.parse_list(raw["block_renderers"]) },
            session_settings: list(raw["session_settings"]) || [],
            session_setting_types: types(raw["session_setting_types"]),
            settings: list(raw["settings"]),
            setting_types: types(raw["setting_types"]),
            file_descriptions: file_descriptions(bundle.files),
            includes: bundle.includes, unknown_keys: [], problems: problems.freeze, origin: :record)
      end

      # The record's values of the manifest keys, string keys.
      def self.recorded(bundle)
        { "requires_chi" => bundle.requires_chi, "trust_level" => bundle.trust_level, "needs" => bundle.needs,
          "context_providers" => bundle.context_providers, "block_renderers" => bundle.block_renderers,
          "session_settings" => bundle.session_settings, "session_setting_types" => bundle.session_setting_types,
          "settings" => bundle.settings, "setting_types" => bundle.setting_types }
      end

      # The block's value, else +empty+ with the key's problem noted.
      # ArgumentError: ContextProviders::Invalid and BlockRenderers::Invalid
      # are ones; EncodingError: a record's string whose bytes aren't UTF-8
      # (JSON keeps them) raises Encoding::CompatibilityError when parsed.
      def self.parsed(problems, key, empty, *errors)
        yield
      rescue ArgumentError, EncodingError, *errors => e
        problems[key] = e.message
        empty
      end

      def self.list(value) = value.is_a?(Array) ? value.map(&:to_s) : nil

      def self.types(value) = value.is_a?(Hash) ? value.to_h { |key, type| [key.to_s, type.to_s] } : {}

      def self.file_descriptions(files)
        files.each_with_object({}) do |(key, entry), acc|
          text = entry[:description].to_s
          acc[key] = text unless text.empty?
        end
      end
      private_class_method :recorded, :parsed, :list, :types, :file_descriptions

      # Why chi +version+ can't load this bundle, nil when it can (or it
      # names no requirement): the one requires_chi gate.
      def requires_chi_failure(version = Samagotchi::VERSION) = Manifest.requires_chi_failure(requires_chi, version)

      # A bundle with no trust_level counts as experimental.
      def experimental? = (trust_level || "experimental") == "experimental"

      def needs? = !needs.empty?

      def context_providers? = !context_providers.empty?

      def block_renderers? = !block_renderers.empty?
    end
  end
end
