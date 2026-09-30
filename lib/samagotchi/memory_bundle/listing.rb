# frozen_string_literal: true

require_relative "manifest"
require_relative "source"
require_relative "provenance"
require_relative "system_bundle"

module Samagotchi
  module MemoryBundle
    # What `chi bundle list` shows: the installed bundles (from provenance),
    # each with the shipped version when chi ships a newer one, and the
    # bundles shipped with chi that aren't installed yet. The system bundle
    # is left out of the shipped ones: chi installs and upgrades it itself.
    module Listing
      # error is set (and the rest nil) when the provenance manifest.json can't be read.
      Installed = Struct.new(:name, :version, :scope, :files, :installed_at, :upgrade, :error, keyword_init: true)
      # source is the name `chi bundle install` takes (the shipped dir's name).
      Shipped = Struct.new(:name, :source, :version, :description, keyword_init: true)

      module_function

      # @return [Array<Shipped>] by name, without the system bundle; a dir
      #   whose manifest doesn't read is skipped
      def shipped(dir: SourceNormalizer::SHIPPED_DIR)
        return [] unless File.directory?(dir)

        Dir.children(dir).sort.filter_map do |source|
          next unless File.file?(File.join(dir, source, "manifest.yml"))
          m = Manifest.read(dir: File.join(dir, source))
          next if m.name == SystemBundle::BUNDLE_NAME
          Shipped.new(name: m.name, source: source, version: m.version, description: m.description)
        rescue Manifest::ValidationError, Psych::Exception
          nil
        end.sort_by(&:name)
      end

      # @return [Array<Installed>] by name; upgrade is the Shipped when it is newer
      def installed(shipped: self.shipped)
        by_name = shipped.to_h { |s| [s.name, s] }
        Provenance.each_installed.map do |name, data|
          next Installed.new(name: name, error: "manifest.json unreadable") if data[:error]

          ship = by_name[name]
          Installed.new(name: name, version: data[:version], scope: data[:scope],
                        files: (data[:files] || {}).size, installed_at: data[:installed_at],
                        upgrade: ship && newer?(ship.version, data[:version]) ? ship : nil)
        end
      end

      # The shipped bundles not installed under their manifest name.
      def available(shipped: self.shipped, installed: self.installed(shipped: shipped))
        names = installed.map(&:name)
        shipped.reject { |s| names.include?(s.name) }
      end

      def newer?(candidate, current)
        candidate, current = candidate.to_s, current.to_s
        return false unless Gem::Version.correct?(candidate) && Gem::Version.correct?(current)
        Gem::Version.new(candidate) > Gem::Version.new(current)
      end
    end
  end
end
