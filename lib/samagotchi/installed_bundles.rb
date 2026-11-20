# frozen_string_literal: true

require "json"
require_relative "memory_paths"
require_relative "installed_bundles/file_digest"
require_relative "installed_bundles/sha"
require_relative "installed_bundles/record"
require_relative "installed_bundles/dir"
require_relative "installed_bundles/standing"

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

    # Each installed bundle's Standing (.each's walk and holding:, by name):
    # whether chi may use it, before any of its files is looked at.
    # @yieldparam standing [Standing]
    # @return [Enumerator<Standing>] without a block
    def self.standings(holding: nil, dir: InstalledBundles.dir)
      return enum_for(:standings, holding: holding, dir: dir) unless block_given?

      each(holding: holding, dir: dir) { |name, record| yield Standing.of(name, record) }
    end

    # One installed bundle's Standing, by name (one record read, no walk).
    # @return [Standing, nil] nil when it isn't installed
    # @raise [JSON::ParserError] manifest.json doesn't parse (as Dir#record:
    #   ContextProviders.command_for lets it out today, the plan's D7)
    def self.standing(name, dir: InstalledBundles.dir)
      record = Dir.new(name: name, dir: dir).record
      record && Standing.of(name, record)
    end

    # The other installed bundles of +scope+ whose record lists the memory
    # file +file_key+, by name (a manifest that doesn't read is left out).
    # A project-scoped record doesn't say which project: one from another
    # repo counts too, which errs on keeping the file.
    # A record that doesn't read is skipped off the record itself (warned of
    # once, as Standing.of does): a claimant check reads no manifest
    # (Standing's requires_chi is no question here).
    def self.claimants(file_key, scope:, except: nil, dir: InstalledBundles.dir)
      each(dir: dir).filter_map do |name, record|
        next if name == except

        if record.error?
          Standing.warn_unreadable(name, record.error)
          next
        end
        next unless record.effective_scope == scope.to_s && record.owns?(file_key)

        name
      end
    end
  end
end
