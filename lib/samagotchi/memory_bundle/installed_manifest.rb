# frozen_string_literal: true

require_relative "../context_providers"
require_relative "../version"
require_relative "manifest"
require_relative "provenance"

module Samagotchi
  autoload :BlockRenderers, File.expand_path("../block_renderers", __dir__)

  module MemoryBundle
    # The one answer to "this installed bundle's manifest": what its
    # manifest.yml says, as the readers of an installed bundle take it
    # (InstalledBundle#manifest). Identity and state stay on the record
    # (InstalledBundle: name, version, source, the plugin's file, every
    # sha, files, marks, a profile's members); manifest data is read here.
    #
    # Read from the bundle's kept manifest.yml (.bundles/<name>/manifest.yml,
    # Provenance#write's manifest_from:) when the record has its sha and the
    # file still has it (a dev install's link is never checked): origin
    # :kept, so a key the record never mirrored (one an older chi didn't
    # know) is read. Otherwise from the record's frozen mirror of the
    # manifest keys (origin :record), in four cases:
    #   no kept file, no manifest_sha a record from before chi kept it; no problem
    #   no kept file, a manifest_sha  problems["manifest.yml"] = :missing (it was
    #                                 removed, or something else is in its place)
    #   kept, no manifest_sha         problems["manifest.yml"] = :stale (a chi
    #                                 without the kept manifest rewrote the record;
    #                                 the file may be an earlier version's)
    #   kept, another sha, or not a   problems["manifest.yml"] = :edited
    #   YAML mapping
    #   kept, its sha                 origin :kept
    # Each key is parsed on its own (Manifest.tolerant for the kept file): one
    # that doesn't parse reads as the mirror's value if that parses, else as
    # empty, and its message is in +problems+ (key => message), so one bad key
    # never costs the rest. A reader that logged such a key logs problems[key].
    # Built once per record and kept file (a process-wide cache keyed by the
    # record and the file's stat): chi web asks per request.
    #
    #   requires_chi, trust_level   the strings as recorded, nil when none
    #   description                 the kept manifest's, nil from the record
    #   needs                       Manifest.parse_needs'
    #   script_names                the scripts/ files it lists
    #   context_providers           Array<ContextProviders::Provider>
    #   block_renderers             Array<BlockRenderers::Renderer>
    #   session_settings, session_setting_types, settings, setting_types
    #                               as Manifest reads them (settings nil when
    #                               the manifest said nothing of them)
    #   file_descriptions           file key => the memory's description
    #   plugin_required             plugin: required: true (a guardrail plugin:
    #                               one that fails to load denies every tool
    #                               call): the record's (PluginRef#required,
    #                               recorded at install) or the kept manifest's,
    #                               so a lost or edited kept file keeps it
    #   includes                    a profile's recorded members (the record's
    #                               identity, never the kept file's), nil for a plain bundle
    #   unknown_keys                the kept manifest's keys this chi doesn't know
    #   floor_keys                  the kept manifest's Manifest#floor_keys (key =>
    #                               the first chi that read it), {} from the record
    #   origin                      :kept or :record
    class InstalledManifest < Data.define(:name, :version, :requires_chi, :trust_level, :description, :needs,
                                          :script_names, :context_providers, :block_renderers, :session_settings,
                                          :session_setting_types, :settings, :setting_types, :file_descriptions,
                                          :plugin_required, :includes, :unknown_keys, :floor_keys, :problems, :origin)
      # The key problems names the kept file's standing under.
      KEPT_FILE = "manifest.yml"
      # How many manifests the cache holds before it starts again.
      CACHE_LIMIT = 256
      @cache = {}
      @cache_lock = Mutex.new

      # @param bundle [InstalledBundle]
      # @return [InstalledManifest]
      def self.of(bundle)
        key = [bundle, kept_stat(bundle.kept_manifest_path)]
        cached = @cache_lock.synchronize { @cache[key] }
        return cached if cached

        built = deep_freeze(build(bundle))
        @cache_lock.synchronize do
          @cache.clear if @cache.size >= CACHE_LIMIT
          @cache[key] = built
        end
      end

      # Callers share the cached value, so nothing in it can change under another.
      def self.deep_freeze(value)
        case value
        when Hash then value.each { |key, item| deep_freeze(key) && deep_freeze(item) }
        when Array then value.each { |item| deep_freeze(item) }
        when Data then value.to_h.each_value { |item| deep_freeze(item) }
        end
        value.freeze
      end

      # What says the kept file changed: nil when there is none.
      def self.kept_stat(path)
        stat = path && File.stat(path)
        stat && [stat.mtime.to_r, stat.size, stat.ino, stat.dev]
      rescue SystemCallError
        nil
      end

      def self.build(bundle)
        mirrored = from_record(bundle)
        path = bundle.kept_manifest_path
        return mirrored unless path

        recorded = !bundle.manifest_sha.to_s.empty?
        return recorded ? standing(mirrored, :missing) : mirrored unless File.file?(path)
        return standing(mirrored, :stale) unless recorded
        return standing(mirrored, :edited) unless Provenance.sha_matches?(path, bundle.manifest_sha)

        kept, problems = Manifest.tolerant(path: path, fallback_scripts: bundle.scripts.keys)
        from_kept(bundle, kept, problems, mirrored)
      rescue Manifest::ValidationError, SystemCallError, EncodingError
        standing(mirrored, :edited)
      end

      def self.standing(mirrored, why) = mirrored.with(problems: mirrored.problems.merge(KEPT_FILE => why).freeze)

      # The kept manifest's values; a key that failed takes the mirror's.
      def self.from_kept(bundle, kept, problems, mirrored)
        pick = ->(key, ours, theirs) { problems.key?(key) ? theirs : ours }
        session = pick.call("session_settings", kept, mirrored)
        settings = pick.call("settings", kept, mirrored)
        new(name: bundle.name, version: bundle.version,
            requires_chi: pick.call("requires_chi", kept.requires_chi, mirrored.requires_chi),
            trust_level: kept.trust_level, description: kept.description.empty? ? nil : kept.description,
            needs: pick.call("needs", kept.needs, mirrored.needs),
            script_names: pick.call("scripts", kept.scripts.keys, mirrored.script_names),
            context_providers: pick.call("context_providers", kept.context_providers, mirrored.context_providers),
            block_renderers: pick.call("block_renderers", kept.block_renderers, mirrored.block_renderers),
            session_settings: session.session_settings, session_setting_types: session.session_setting_types,
            settings: settings.settings, setting_types: settings.setting_types,
            file_descriptions: pick.call("files", kept.file_descriptions, mirrored.file_descriptions),
            plugin_required: kept.plugin&.dig(:required) == true || mirrored.plugin_required,
            includes: bundle.includes,
            unknown_keys: kept.unknown_keys.map(&:to_s), floor_keys: floors(kept), problems: problems.freeze, origin: :kept)
      end

      # Manifest#floor_keys of the tolerant read; a shape it can't tell is no floor.
      def self.floors(kept)
        kept.floor_keys
      rescue StandardError
        {}
      end

      def self.from_record(bundle)
        raw = recorded(bundle)
        problems = {}
        new(name: bundle.name, version: bundle.version,
            requires_chi: raw["requires_chi"]&.to_s, trust_level: raw["trust_level"]&.to_s, description: nil,
            needs: parsed(problems, "needs", [], Manifest::ValidationError) { Manifest.parse_needs(raw["needs"]) },
            script_names: bundle.scripts.keys,
            context_providers: parsed(problems, "context_providers", []) { ContextProviders.parse_list(raw["context_providers"]) },
            block_renderers: parsed(problems, "block_renderers", []) { BlockRenderers.parse_list(raw["block_renderers"]) },
            session_settings: list(raw["session_settings"]) || [],
            session_setting_types: types(raw["session_setting_types"]),
            settings: list(raw["settings"]),
            setting_types: types(raw["setting_types"]),
            file_descriptions: file_descriptions(bundle.files),
            plugin_required: bundle.plugin&.required == true,
            includes: bundle.includes, unknown_keys: [], floor_keys: {}, problems: problems.freeze, origin: :record)
      end

      # The record's values of the manifest keys (its frozen mirror), string
      # keys: what a bundle with no usable kept manifest, or no dir (a record
      # parsed alone), reads.
      def self.recorded(bundle) = bundle.mirror

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
      private_class_method :deep_freeze, :kept_stat, :build, :standing, :from_kept, :floors, :from_record, :recorded, :parsed,
                           :list, :types, :file_descriptions

      # Why the kept manifest.yml wasn't read: :missing, :stale or :edited (the class
      # comment's cases), nil when it was or there is none.
      def standing = problems[KEPT_FILE]

      # The keys that didn't parse, key => message, without the kept file's standing.
      def key_problems = problems.except(KEPT_FILE)

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
