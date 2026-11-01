# frozen_string_literal: true

require "digest"
require "fileutils"
require_relative "atomic_file"
require_relative "config"
require_relative "paths"
require_relative "session_config"
require_relative "memory_bundle/provenance"

module Samagotchi
  # config.yml `bundles:` against what's installed, for a typo that would
  # otherwise do nothing in silence: a name no bundle has, and a key or a
  # value's type a manifest's settings: rules out. A config file only warns:
  # the rest of it still runs, and `chi --set` is what refuses
  # (SessionConfig.check!, in the same words). A manifest with no settings:
  # (a record from before them too) has its keys left alone. A digest of the
  # lines last shown is stamped in $XDG_STATE_HOME/samagotchi/bundles_warned.
  module BundleSettingsCheck
    STAMP_FILE = "bundles_warned"

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

    # @return [String] the stamp of the lines last shown
    def stamp_path(env: ENV) = File.join(Paths.state_dir(env: env), STAMP_FILE)

    # The lines to show now: each worker checks the config, and all of them
    # finding what the last one showed would repeat it in every session. None
    # while +lines+ are the stamped ones (in any order); no lines clear the
    # stamp, so the same typo made again is new. A stamp it can't read or
    # write costs a repeated warning, never a session start.
    # @param lines [Array<String>] #warnings
    # @return [Array<String>] +lines+, or none
    def unshown(lines)
      stamp = stamp_path
      if lines.empty?
        FileUtils.rm_f(stamp)
        return lines
      end
      digest = Digest::SHA256.hexdigest(lines.sort.join("\n"))
      return [] if File.exist?(stamp) && File.read(stamp).strip == digest

      FileUtils.mkdir_p(File.dirname(stamp))
      AtomicFile.write(stamp, "#{digest}\n")
      lines
    rescue StandardError
      lines
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
