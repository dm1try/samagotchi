# frozen_string_literal: true

require_relative "config"
require_relative "session_config"
require_relative "memory_bundle/provenance"

module Samagotchi
  # config.yml `bundles:` against what's installed, for a typo that would
  # otherwise do nothing in silence: a name no bundle has, and a key or a
  # value's type a manifest's settings: rules out. A config file only warns:
  # the rest of it still runs, and `chi --set` is what refuses
  # (SessionConfig.check!, in the same words). A manifest with no settings:
  # (a record from before them too) has its keys left alone.
  module BundleSettingsCheck
    module_function

    # @param section [Hash{String => Hash}] ConfigFile.bundle_settings
    # @return [Array<String>] one line per finding
    def warnings(section, dir: MemoryBundle::Provenance.bundles_dir)
      return [] if section.empty?

      installed = MemoryBundle::Provenance.each_installed(dir: dir).to_h
      section.flat_map do |name, values|
        bundle = installed[name]
        next ["config.yml bundles: #{name}: #{SessionConfig.no_installed_bundle(name)}#{near(name, installed.keys)}"] unless bundle
        next [] if bundle.error?

        record_warnings(bundle, values)
      end
    end

    # One bundle's +values+ against its record (or a manifest as one); none
    # while it declares no settings:.
    # @param bundle [MemoryBundle::InstalledBundle]
    # @return [Array<String>]
    def record_warnings(bundle, values)
      return [] if bundle.settings.nil?

      values.flat_map { |key, value| value_warnings(bundle, key.to_s, value) }
    end

    def value_warnings(bundle, key, value)
      where = "config.yml bundles: #{bundle.name}.#{key}"
      known = bundle.settings | bundle.session_settings
      return ["#{where}: #{SessionConfig.takes_keys(bundle.name, known)}#{near(key, known)}"] unless known.include?(key)

      takes, what = SessionConfig::TYPES[bundle.setting_types[key]]
      takes && !takes.call(value) ? ["#{where}: #{SessionConfig.wrong_type(bundle.name, key, what, value)}"] : []
    end
    private_class_method :value_warnings

    def near(name, names)
      close = Config.near_names(name, names).first
      close ? " (did you mean #{close}?)" : ""
    end
    private_class_method :near
  end
end
