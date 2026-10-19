# frozen_string_literal: true

require "yaml"
require_relative "version"

module Samagotchi
  # A session's own bundle settings (chi --set BUNDLE.KEY=VALUE, chi send
  # --new --set, POST /api/sessions bundle_settings): {bundle => {key =>
  # value}}, string keys, scalar values (.typed). A bundle offers the keys a
  # session may set in its manifest's session_settings: (recorded at install,
  # InstalledBundle#session_settings); any other bundle or key is refused, so
  # a typo isn't saved, and so is a value of another type than the manifest
  # gives the key (session_settings: {cap: number}). The session keeps them
  # (Session#bundle_settings, SessionSetup) and Plugin::Context#settings
  # lays them over config.yml's bundles: <name>:.
  module BundleSessionSettings
    # A refused --set (or request field): the message says why.
    class Error < ArgumentError; end

    # A bundle name (MemoryBundle::Manifest::BUNDLE_NAME) and a setting key.
    BUNDLE = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
    KEY = /\A[A-Za-z0-9_][A-Za-z0-9_-]*\z/
    # The values a setting may take.
    SCALARS = [String, Integer, Float, TrueClass, FalseClass].freeze
    REQUEST_SHAPE = "bundle_settings is an object of bundle => {key => scalar}"
    # What .typed reads as a number: no leading zero, no _; a decimal may
    # leave out either side of its point (.5, 5.) and take an exponent
    # (1e1, 2.5e-3), which YAML 1.1 leaves as text.
    INTEGER = /\A-?(?:0|[1-9]\d*)\z/
    DECIMAL = /\A-?(?:(?:0|[1-9]\d*)(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?\z/
    # YAML 1.1's booleans (config.yml's), any case.
    TRUE_WORDS = %w[true yes on].freeze
    FALSE_WORDS = %w[false no off].freeze
    # The shipped bundles' sources (a stale record's hint reads them).
    SHIPPED_DIR = File.expand_path("bundles", __dir__)

    # The installed bundles a session may set settings of: +offered+ the
    # keys of each bundle whose plugin loads ({name => keys}), +notes+ what
    # a refusal adds for a bundle ({name => text}): why its plugin doesn't
    # load, or how to refresh a record from before session_settings;
    # +types+ the types its manifest gives keys ({name => {key => type}}).
    Availability = Data.define(:offered, :notes, :types) do
      def initialize(offered:, notes:, types: {}) = super
    end

    # What each type (MemoryBundle::Manifest::SESSION_SETTING_TYPES) takes,
    # as a value .typed gives it, and how a refusal names it. A number may
    # be off (false), as a bundle's own settings are turned off.
    TYPES = {
      "number" => [->(value) { (value.is_a?(Numeric) && value.finite?) || value == false }, "a number (or off)"],
      "boolean" => [->(value) { [true, false].include?(value) }, "true or false"],
      "string" => [->(value) { value.is_a?(String) }, "text"]
    }.freeze

    module_function

    # --set's values as typed, in order: a later one of the same key wins.
    # A key +types+ gives as string keeps its text as given (.value_for).
    # @param args [Array<String>] "BUNDLE.KEY=VALUE" each
    # @param types [Hash{String => Hash{String => String}}] Availability#types
    # @return [Hash{String => Hash{String => Object}}] frozen
    # @raise [Error] a value of another shape
    def parse(args, types: {})
      settings = {}
      Array(args).each do |arg|
        target, sep, raw = arg.to_s.partition("=")
        bundle, *keys = target.split(".", -1)
        if sep.empty? || keys.empty? || !BUNDLE.match?(bundle.to_s) || keys.any? { |key| !KEY.match?(key) }
          raise Error, "--set takes BUNDLE.KEY=VALUE, not #{arg}"
        end
        raise Error, "--set #{arg}: one key under the bundle (BUNDLE.KEY), no nested path" if keys.size > 1
        raise Error, "--set #{arg}: give a value" if raw.strip.empty?

        (settings[bundle] ||= {})[keys.first] = value_for(raw, types.dig(bundle, keys.first))
      end
      deep_freeze(settings)
    end

    # +settings+ when every bundle is installed and offers each key.
    # @param bundles [Hash{String => Array<String>}] the installed bundles'
    #   offered keys (.offered)
    # @param notes [Hash{String => String}] Availability#notes
    # @param types [Hash{String => Hash{String => String}}] Availability#types:
    #   a typed key's value must be of its type (TYPES)
    # @param flag [String] what a refusal names ("--set", a request field)
    # @return [Hash] +settings+
    # @raise [Error]
    def check!(settings, bundles: offered, notes: {}, types: {}, flag: "--set")
      settings.each do |bundle, values|
        keys = bundles[bundle]
        note = notes[bundle]
        values.each do |key, value|
          where = "#{flag} #{bundle}.#{key}"
          raise Error, "#{where}: #{note || "no installed bundle #{bundle} (#{takers(bundles)})"}" if keys.nil?
          raise Error, "#{where}: #{bundle} takes no session settings#{" #{note}" if note}" if keys.empty?
          raise Error, "#{where}: #{bundle} takes #{keys.join(", ")}" unless keys.include?(key)

          takes, what = TYPES[types.dig(bundle, key)]
          raise Error, "#{where}: #{bundle} takes #{what} for #{key}, not #{value.inspect}" if takes && !takes.call(value)
        end
      end
      settings
    end

    # --set's values parsed and checked (.parse, .check!) against the
    # installed bundles (.availability).
    def from_flags(args, available: availability)
      check!(parse(args, types: available.types), bundles: available.offered, notes: available.notes, types: available.types)
    end

    # A value as --set (and a request's string) gives it: an integer
    # ("3", "-1"), a decimal ("2.5", ".5", "1e1"), a boolean as config.yml's
    # YAML reads one (true/yes/on, false/no/off, any case); any other string
    # stays as given ("010", "0x10", "3:30", "y", "null"). A value that
    # isn't a String (a JSON number or boolean) is kept.
    def typed(value)
      return value unless value.is_a?(String)
      return Integer(value, 10) if INTEGER.match?(value)

      if DECIMAL.match?(value)
        number = Float(float_text(value))
        # 1e400 is Infinity: no cap reaches it and JSON can't save it.
        return number.finite? ? number : value
      end

      word = value.downcase
      return true if TRUE_WORDS.include?(word)
      return false if FALSE_WORDS.include?(word)

      value
    end

    # A value for a key of +type+: a string key's text as given (--set
    # b.name=yes stays "yes"), any other's .typed.
    def value_for(value, type) = type == "string" ? value : typed(value)

    # A decimal DECIMAL matches as Float reads it on every Ruby: a point
    # with no digit after it ("5.", "5.e1") gets a 0, which Ruby 3.3's
    # Float wants.
    def float_text(value) = value.sub(/\.(?=e|\z)/i, ".0")

    # POST /api/sessions bundle_settings: nil for none, else an object of
    # objects of scalars (a string typed as --set types it), checked like
    # --set; an empty bundle entry is dropped.
    # @param bundles [Hash, nil] the offered keys (.availability's by default)
    # @param types [Hash] their types, with +bundles+ (Availability#types)
    # @return [Hash] frozen
    # @raise [Error]
    def from_request(raw, bundles: nil, types: {})
      return {} if raw.nil?
      raise Error, REQUEST_SHAPE unless raw.is_a?(Hash) && raw.all? { |_, values| scalar_map?(values) }

      given = normalize(raw)
      return given if given.empty?

      available = bundles ? Availability.new(offered: bundles, notes: {}, types: types) : availability
      settings = normalize(given.to_h do |bundle, values|
        [bundle, values.to_h { |key, value| [key, value_for(value, available.types.dig(bundle, key))] }]
      end)
      check!(settings, bundles: available.offered, notes: available.notes, types: available.types, flag: "bundle_settings")
    end

    # Each installed bundle's offered keys, by name (Availability#offered).
    # @return [Hash{String => Array<String>}]
    def offered(dir: nil) = availability(dir: dir).offered

    # The installed bundles a session may set settings of: a record that
    # doesn't read is left out, and so is one whose plugin doesn't load as
    # chi's loader decides (Plugin::Loader#unloadable_reason: requires_chi,
    # the file, its sha256), with a note saying why. A record with no
    # session_settings whose shipped bundle lists some (installed before
    # them) gets a note on refreshing it.
    # @return [Availability]
    def availability(dir: nil, shipped_dir: SHIPPED_DIR)
      require_relative "memory_bundle/provenance"
      require_relative "memory_bundle/manifest"
      dir ||= MemoryBundle::Provenance.bundles_dir
      offered = {}
      notes = {}
      types = {}
      MemoryBundle::Provenance.each_installed(dir: dir) do |name, bundle|
        next if bundle.error?

        if (reason = unloadable(dir, name, bundle))
          notes[name] = "#{name} is installed but its plugin doesn't load: #{reason}"
          next
        end
        offered[name] = bundle.session_settings
        types[name] = bundle.session_setting_types unless bundle.session_setting_types.empty?
        if bundle.session_settings.empty? && shipped_settings?(shipped_dir, name)
          notes[name] = "(run `chi update` or `chi bundle upgrade #{name}` to refresh it)"
        end
      end
      Availability.new(offered: offered, notes: notes, types: types)
    end

    # A session file's value, read tolerantly: the bundles that map to
    # settings, the scalar ones of those, string keys, frozen; {} for
    # anything else.
    # @return [Hash{String => Hash{String => Object}}]
    def normalize(raw)
      return {}.freeze unless raw.is_a?(Hash)

      deep_freeze(raw.each_with_object({}) do |(bundle, values), acc|
        next unless values.is_a?(Hash)

        kept = values.each_with_object({}) do |(key, value), scalars|
          scalars[key.to_s] = value if SCALARS.any? { |kind| value.is_a?(kind) }
        end
        acc[bundle.to_s] = kept unless kept.empty?
      end)
    end

    # Why +bundle+'s plugin doesn't load, as chi's loader decides it
    # (Plugin::Loader.unloadable_reason), nil when it does or has none.
    def unloadable(dir, name, bundle)
      return nil unless bundle.plugin

      require_relative "plugin/loader"
      # +dir+, not Provenance#plugin_path's bundles_dir: a spec's records live elsewhere.
      Plugin::Loader.unloadable_reason(File.join(dir, name, "plugin", bundle.plugin.file.to_s), bundle)
    end

    # Whether chi ships a bundle +name+ whose manifest lists session_settings.
    def shipped_settings?(shipped_dir, name)
      path = File.join(shipped_dir, name, "manifest.yml")
      return false unless File.file?(path)

      raw = YAML.safe_load_file(path)
      listed = raw.is_a?(Hash) ? raw["session_settings"] : nil
      (listed.is_a?(Array) || listed.is_a?(Hash)) && !listed.empty?
    rescue Psych::Exception, SystemCallError
      false
    end

    def scalar_map?(values)
      values.is_a?(Hash) && values.values.all? { |value| SCALARS.any? { |kind| value.is_a?(kind) } }
    end

    def takers(bundles)
      names = bundles.reject { |_, keys| keys.empty? }.keys.sort
      names.empty? ? "no installed bundle takes --set" : "bundles that take --set: #{names.join(", ")}"
    end

    def deep_freeze(settings)
      settings.to_h { |bundle, values| [bundle.dup.freeze, values.to_h { |k, v| [k.dup.freeze, v.frozen? ? v : v.dup.freeze] }.freeze] }.freeze
    end

    private_class_method :unloadable, :shipped_settings?, :scalar_map?, :takers, :deep_freeze
  end
end
