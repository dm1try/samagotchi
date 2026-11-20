# frozen_string_literal: true

require "json"
require_relative "memory_paths"
require_relative "installed_bundles/file_digest"
require_relative "installed_bundles/sha"
require_relative "installed_bundles/record"
require_relative "installed_bundles/dir"

module Samagotchi
  # What is installed (the records under <system memories>/.bundles/, see
  # MemoryPaths) and what the runtime reads of it: each record (Record), its
  # manifest (Manifest), one bundle's folder (Dir) and the shas its files are
  # checked against (Sha). The read side only: installing, upgrading and
  # removing a bundle is MemoryBundle's, which builds on this and never the
  # reverse (docs/internals/bundles.md).
  module InstalledBundles
    def self.dir
      MemoryPaths.bundles_dir
    end

    # Yields [name, bundle] for each installed bundle (a dir under
    # .dir holding a manifest.json, dot dirs aside), by name. bundle
    # is its Record, one with error set when manifest.json doesn't
    # parse or isn't an object; the rest still come.
    #
    # With holding: (:hooks, :guardrails or :plugin) only the bundles
    # whose manifest has a non-empty mapping under that key come, and a
    # manifest that doesn't parse comes (with error) only when its bundle
    # has that dir (hooks/, guardrails/, plugin/): what it would load
    # can't be checked. One that isn't an object is skipped there.
    # @param dir [String] the bundles dir (.dir by default)
    def self.each(holding: nil, dir: InstalledBundles.dir)
      return enum_for(:each, holding: holding, dir: dir) unless block_given?
      return unless ::Dir.exist?(dir)

      ::Dir.children(dir).reject { |e| e.start_with?(".") }.sort.each do |name|
        mjson = File.join(dir, name, "manifest.json")
        next unless File.exist?(mjson)

        begin
          data = JSON.parse(File.read(mjson), symbolize_names: true)
        rescue JSON::ParserError, EncodingError, SystemCallError => e # a key that isn't UTF-8 can't be a symbol
          if holding.nil? || ::Dir.exist?(File.join(dir, name, holding.to_s))
            yield name, Record.unreadable(name, "manifest.json is unreadable: #{e.message}")
          end
          next
        end
        next if holding && !(data.is_a?(Hash) && data[holding].is_a?(Hash) && !data[holding].empty?)

        yield name, Record.parse(name, data, File.join(dir, name))
      end
    end

    # The other installed bundles of +scope+ whose record lists the memory
    # file +file_key+, by name (a manifest that doesn't read is left out).
    # A project-scoped record doesn't say which project: one from another
    # repo counts too, which errs on keeping the file.
    def self.claimants(file_key, scope:, except: nil, dir: InstalledBundles.dir)
      each(dir: dir).filter_map do |name, bundle|
        next if name == except || bundle.error?
        next unless bundle.effective_scope == scope.to_s && bundle.owns?(file_key)

        name
      end
    end
  end
end
