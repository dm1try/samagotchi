# frozen_string_literal: true

require "yaml"

module Samagotchi
  # A session's own bundle settings (chi --set BUNDLE.KEY=VALUE, chi send
  # --new --set, POST /api/sessions bundle_settings): {bundle => {key =>
  # value}}, string keys, YAML scalar values. A bundle offers the keys a
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
    # The values a setting may take: what a YAML scalar reads as.
    SCALARS = [String, Integer, Float, TrueClass, FalseClass].freeze
    SCALAR_HINT = "the value is a YAML scalar (3, 2.5, true, text)"
    REQUEST_SHAPE = "bundle_settings is an object of bundle => {key => scalar}"

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

        (settings[bundle] ||= {})[keys.first] = scalar(raw, arg)
      end
      deep_freeze(settings)
    end

    # +settings+ when every bundle is installed and offers each key.
    # @param bundles [Hash{String => Array<String>}] the installed bundles'
    #   offered keys (.offered)
    # @param flag [String] what a refusal names ("--set", a request field)
    # @return [Hash] +settings+
    # @raise [Error]
    def check!(settings, bundles: offered, flag: "--set")
      settings.each do |bundle, values|
        keys = bundles[bundle]
        values.each_key do |key|
          where = "#{flag} #{bundle}.#{key}"
          raise Error, "#{where}: no installed bundle #{bundle} (#{takers(bundles)})" if keys.nil?
          raise Error, "#{where}: #{bundle} takes no session settings" if keys.empty?
          raise Error, "#{where}: #{bundle} takes #{keys.join(", ")}" unless keys.include?(key)
        end
      end
      settings
    end

    # --set's values parsed and checked (.parse, .check!).
    def from_flags(args, bundles: offered) = check!(parse(args), bundles: bundles)

    # POST /api/sessions bundle_settings: nil for none, else an object of
    # objects of scalars, checked like --set.
    # @return [Hash] frozen
    # @raise [Error]
    def from_request(raw, bundles: offered)
      return {} if raw.nil?
      raise Error, REQUEST_SHAPE unless raw.is_a?(Hash) && raw.all? { |_, values| scalar_map?(values) }

      check!(normalize(raw), bundles: bundles, flag: "bundle_settings")
    end

    # Each installed bundle's offered keys, by name; a record that doesn't
    # read is left out.
    # @return [Hash{String => Array<String>}]
    def offered(dir: nil)
      require_relative "memory_bundle/provenance"
      dir ||= MemoryBundle::Provenance.bundles_dir
      MemoryBundle::Provenance.each_installed(dir: dir).each_with_object({}) do |(name, bundle), acc|
        acc[name] = bundle.session_settings unless bundle.error?
      end
    end

    # A session file's value, read tolerantly: the bundles that map to
    # settings, the scalar ones of those, string keys, frozen; {} for
    # anything else.
    # @return [Hash{String => Hash{String => Object}}]
    def normalize(raw)
      return {}.freeze unless raw.is_a?(Hash)

      deep_freeze(raw.each_with_object({}) do |(bundle, values), acc|
        next unless values.is_a?(Hash)

        acc[bundle.to_s] = values.each_with_object({}) do |(key, value), kept|
          kept[key.to_s] = value if SCALARS.any? { |kind| value.is_a?(kind) }
        end
      end)
    end

    def scalar(raw, arg)
      value = YAML.safe_load(raw)
      raise Error, "--set #{arg}: #{SCALAR_HINT}" if value.is_a?(Hash) || value.is_a?(Array)

      SCALARS.any? { |kind| value.is_a?(kind) } ? value : raw
    rescue Psych::Exception
      raw
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

    private_class_method :scalar, :scalar_map?, :takers, :deep_freeze
  end
end
