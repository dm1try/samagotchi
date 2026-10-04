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
    # A profile (a meta bundle) that isn't installed lists its members on
    # its own line, and they aren't listed again.
    module Listing
      # error is set (and the rest nil) when the provenance manifest.json
      # can't be read; includes is a profile's recorded members, else nil.
      Installed = Struct.new(:name, :version, :scope, :files, :installed_at, :upgrade, :error, :includes, keyword_init: true)
      # source is the name `chi bundle install` takes (the shipped dir's
      # name); includes is a profile's members ([] for a plain bundle).
      Shipped = Struct.new(:name, :source, :version, :description, :includes, keyword_init: true)

      module_function

      # @return [Array<Shipped>] by name, without the system bundle; a dir
      #   whose manifest doesn't read is skipped
      def shipped(dir: SourceNormalizer::SHIPPED_DIR)
        return [] unless File.directory?(dir)

        Dir.children(dir).sort.filter_map do |source|
          next unless File.file?(File.join(dir, source, "manifest.yml"))

          m = Manifest.read(dir: File.join(dir, source))
          next if m.name == SystemBundle::BUNDLE_NAME

          Shipped.new(name: m.name, source: source, version: m.version, description: m.description, includes: m.includes)
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
                        upgrade: ship && newer?(ship.version, data[:version]) ? ship : nil,
                        includes: data[:includes].is_a?(Array) ? data[:includes].map(&:to_s) : nil)
        end
      end

      # The shipped bundles not installed under their manifest name, a
      # profile's members folded into it (grouped).
      def available(shipped: self.shipped, installed: self.installed(shipped: shipped))
        grouped(shipped, installed.map(&:name))
      end

      # The shipped bundles not in +installed_names+; a profile among them
      # keeps only its members not installed, and those aren't listed
      # again on their own.
      def grouped(shipped, installed_names)
        left = shipped.reject { |s| installed_names.include?(s.name) }
        folded = left.flat_map(&:includes)
        left.reject { |s| folded.include?(s.name) }.map do |s|
          s.includes.empty? ? s : s.dup.tap { |d| d.includes = s.includes - installed_names }
        end
      end

      def newer?(candidate, current)
        candidate = candidate.to_s
        current = current.to_s
        return false unless Gem::Version.correct?(candidate) && Gem::Version.correct?(current)

        Gem::Version.new(candidate) > Gem::Version.new(current)
      end
    end
  end
end
