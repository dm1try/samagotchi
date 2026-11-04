# frozen_string_literal: true

require "yaml"
require_relative "../chi_home"

module Samagotchi
  module MemoryBundle
    # Whether a file's bytes are what some installed samagotchi gem shipped for
    # that file of that bundle. A mark from an older chi may have the user's own
    # text as its base (Merger.merge_outcome); bytes a chi shipped can't be that.
    #
    # Asked only when the guard would otherwise fire, so an ordinary start pays
    # nothing. Reads the gem dirs by hand: the running process's (Gem.path, which
    # a chi home's boot string sets) and the chi home's (a checkout or a stray
    # GEM_PATH runs on other gems than the home's), never loading a gem or asking
    # Gem::Specification. Anything it can't read is no match, and no match keeps
    # the guard: the fallback is the safe side.
    module ShippedHistory
      GEM_DIR = /\Asamagotchi-#{Gem::Version::VERSION_PATTERN}(?:-[a-z0-9_-]+)?\z/
      BUNDLES = File.join("lib", "samagotchi", "bundles")

      module_function

      # @param bundle_name [String] the name in the manifest: a shipped dir may
      #   have another name in another version
      # @param file_key [String] the file's name in the bundle
      # @param path [String] the file holding the bytes asked about
      # @return [Boolean]
      def shipped?(bundle_name, file_key, path)
        return false if file_key.include?("/")

        bytes = File.binread(path)
        gem_roots.any? { |root| holds?(root, bundle_name, file_key, bytes) }
      rescue SystemCallError
        false
      end

      # Each installed samagotchi gem's folder, wherever it is.
      def gem_roots
        gem_dirs.flat_map do |dir|
          gems = File.join(dir, "gems")
          Dir.children(gems).select { |name| name.match?(GEM_DIR) }.map { |name| File.join(gems, name) }
        rescue SystemCallError
          []
        end
      end

      def gem_dirs = (Gem.path + home_gem_dirs).uniq

      def home_gem_dirs
        ChiHome.read&.gem_dirs || []
      rescue StandardError
        []
      end

      # The size first, the bytes next and the manifest last: 55 gems of 22
      # bundles would be a thousand YAML files, and few candidates get that far.
      def holds?(root, bundle_name, file_key, bytes)
        bundles = File.join(root, BUNDLES)
        Dir.glob("*", base: bundles).any? do |dir|
          file = File.join(bundles, dir, file_key)
          File.file?(file) && File.size(file) == bytes.bytesize && File.binread(file) == bytes &&
            manifest_name(File.dirname(file)) == bundle_name
        rescue SystemCallError
          false
        end
      end

      # The name a bundle's manifest gives, nil when it doesn't read. Not
      # Manifest.read: an older manifest needn't pass this chi's checks.
      def manifest_name(dir)
        data = YAML.safe_load_file(File.join(dir, "manifest.yml"))
        data.is_a?(Hash) ? data["name"] : nil
      rescue StandardError
        nil
      end
    end
  end
end
