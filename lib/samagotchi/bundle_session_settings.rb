# frozen_string_literal: true

require "yaml"
require_relative "version"

module Samagotchi
  # A session's own bundle settings (chi --set BUNDLE.KEY=VALUE, chi send
  # --new --set, POST /api/sessions bundle_settings): {bundle => {key =>
  # value}}, string keys, scalar values (.typed). A bundle offers the keys a
  # session may set in its manifest's session_settings: (recorded at install,
  # InstalledBundle#session_settings); any other bundle or key is refused, so
  # a typo isn't saved. The session keeps them (Session#bundle_settings,
  # SessionSetup) and Plugin::Context#settings lays them over config.yml's
  # bundles: <name>:.
  module BundleSessionSettings
    # A refused --set (or request field): the message says why.
    class Error < ArgumentError; end

    # A bundle name (MemoryBundle::Manifest::BUNDLE_NAME) and a setting key.
    BUNDLE = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
    KEY = /\A[A-Za-z0-9_][A-Za-z0-9_-]*\z/
    # The values a setting may take.
    SCALARS = [String, Integer, Float, TrueClass, FalseClass].freeze
    REQUEST_SHAPE = "bundle_settings is an object of bundle => {key => scalar}"
    # What .typed reads as a number: no leading zero, no exponent, no _.
    INTEGER = /\A-?(?:0|[1-9]\d*)\z/
    DECIMAL = /\A-?(?:0|[1-9]\d*)\.\d+\z/
    # The shipped bundles' sources (a stale record's hint reads them).
    SHIPPED_DIR = File.expand_path("bundles", __dir__)

    # The installed bundles a session may set settings of: +offered+ the
    # keys of each bundle whose plugin loads ({name => keys}), +notes+ what
    # a refusal adds for a bundle ({name => text}): why its plugin doesn't
    # load, or how to refresh a record from before session_settings.
    Availability = Data.define(:offered, :notes)

    module_function

    # --set's values as typed, in order: a later one of the same key wins.
    # @param args [Array<String>] "BUNDLE.KEY=VALUE" each
    # @return [Hash{String => Hash{String => Object}}] frozen
    # @raise [Error] a value of another shape
    def parse(args)
      settings = {}
      Array(args).each do |arg|
        target, sep, raw = arg.to_s.partition("=")
        bundle, *keys = target.split(".", -1)
        if sep.empty? || keys.empty? || !BUNDLE.match?(bundle.to_s) || keys.any? { |key| !KEY.match?(key) }
          raise Error, "--set takes BUNDLE.KEY=VALUE, not #{arg}"
        end
        raise Error, "--set #{arg}: one key under the bundle (BUNDLE.KEY), no nested path" if keys.size > 1
        raise Error, "--set #{arg}: give a value" if raw.strip.empty?

        (settings[bundle] ||= {})[keys.first] = typed(raw)
      end
      deep_freeze(settings)
    end

    # +settings+ when every bundle is installed and offers each key.
    # @param bundles [Hash{String => Array<String>}] the installed bundles'
    #   offered keys (.offered)
    # @param notes [Hash{String => String}] Availability#notes
    # @param flag [String] what a refusal names ("--set", a request field)
    # @return [Hash] +settings+
    # @raise [Error]
    def check!(settings, bundles: offered, notes: {}, flag: "--set")
      settings.each do |bundle, values|
        keys = bundles[bundle]
        note = notes[bundle]
        values.each_key do |key|
          where = "#{flag} #{bundle}.#{key}"
          raise Error, "#{where}: #{note || "no installed bundle #{bundle} (#{takers(bundles)})"}" if keys.nil?
          raise Error, "#{where}: #{bundle} takes no session settings#{" #{note}" if note}" if keys.empty?
          raise Error, "#{where}: #{bundle} takes #{keys.join(", ")}" unless keys.include?(key)
        end
      end
      settings
    end

    # --set's values parsed and checked (.parse, .check!) against the
    # installed bundles (.availability).
    def from_flags(args, available: availability)
      check!(parse(args), bundles: available.offered, notes: available.notes)
    end

    # A value as --set (and a request's string) gives it: an integer
    # ("3", "-1"), a decimal ("2.5"), true, false or off (false); any other
    # string stays as given ("010", "0x10", "3:30", "No", "null"). A value
    # that isn't a String (a JSON number or boolean) is kept.
    def typed(value)
      return value unless value.is_a?(String)

      case value
      when INTEGER then Integer(value, 10)
      when DECIMAL then Float(value)
      when "true" then true
      when "false", "off" then false
      else value
      end
    end

    # POST /api/sessions bundle_settings: nil for none, else an object of
    # objects of scalars (a string typed as --set's, .typed), checked like
    # --set; an empty bundle entry is dropped.
    # @param bundles [Hash, nil] the offered keys (.availability's by default)
    # @return [Hash] frozen
    # @raise [Error]
    def from_request(raw, bundles: nil)
      return {} if raw.nil?
      raise Error, REQUEST_SHAPE unless raw.is_a?(Hash) && raw.all? { |_, values| scalar_map?(values) }

      settings = normalize(raw.transform_values { |values| values.transform_values { |value| typed(value) } })
      return settings if settings.empty?

      available = bundles ? Availability.new(offered: bundles, notes: {}) : availability
      check!(settings, bundles: available.offered, notes: available.notes, flag: "bundle_settings")
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
      MemoryBundle::Provenance.each_installed(dir: dir) do |name, bundle|
        next if bundle.error?

        if (reason = unloadable(dir, name, bundle))
          notes[name] = "#{name} is installed but its plugin doesn't load: #{reason}"
          next
        end
        offered[name] = bundle.session_settings
        if bundle.session_settings.empty? && shipped_settings?(shipped_dir, name)
          notes[name] = "(run `chi update` or `chi bundle upgrade #{name}` to refresh it)"
        end
      end
      Availability.new(offered: offered, notes: notes)
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

    # Why +bundle+'s plugin doesn't load (as Plugin::Loader checks it), nil
    # when it does or has none.
    def unloadable(dir, name, bundle)
      return nil unless bundle.plugin

      failure = MemoryBundle::Manifest.requires_chi_failure(bundle.requires_chi, Samagotchi::VERSION)
      return failure if failure

      file = File.join(dir, name, "plugin", bundle.plugin.file.to_s)
      return "the file is missing" unless File.file?(file)

      return nil if MemoryBundle::Provenance.unchecked?(bundle.plugin.sha256)

      expected = MemoryBundle::Provenance.recorded_sha(bundle.plugin.sha256)
      return "no sha256 recorded for it (reinstall the bundle)" if expected.empty?

      actual = MemoryBundle::Provenance.file_sha(file)
      "its sha256 differs from the installed one (edited after install? reinstall the bundle)" unless actual == expected
    end

    # Whether chi ships a bundle +name+ whose manifest lists session_settings.
    def shipped_settings?(shipped_dir, name)
      path = File.join(shipped_dir, name, "manifest.yml")
      return false unless File.file?(path)

      raw = YAML.safe_load_file(path)
      raw.is_a?(Hash) && raw["session_settings"].is_a?(Array) && !raw["session_settings"].empty?
    rescue StandardError
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
