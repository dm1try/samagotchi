# frozen_string_literal: true

require_relative "installer"
require_relative "manifest"
require_relative "provenance"
require_relative "source"
require_relative "uninstaller"
require_relative "../version"

module Samagotchi
  module MemoryBundle
    # Profiles: a shipped meta bundle (a dir holding only manifest.yml, with
    # includes:) installs a set of shipped bundles. Every entry point (chi
    # bundle install/upgrade/uninstall, chi update, chi bootstrap) goes
    # through here, and all of them follow one rule:
    #
    #   to_install = shipped includes - recorded includes - installed bundles
    #
    # The meta's provenance records the members it installed or found
    # installed, so a member the user uninstalls stays out, re-running is a
    # no-op, and a bundle new to the profile is the only one installed. A
    # member this chi is too old for, or one that fails, isn't recorded and
    # is tried again next time. Members come from the shipped dir, never
    # from a name lookup, so they stay updatable by chi update. Only a
    # shipped meta expands: includes: in any other bundle is ignored.
    module Profile
      # installed: members installed now; already: members found installed
      # (recorded, not reinstalled); skipped and failed: name => why.
      InstallResult = Struct.new(:name, :version, :installed, :already, :skipped, :failed, keyword_init: true) do
        def failed? = !failed.empty?
      end
      # removed: members uninstalled; blocked: name => why; gone: the meta
      # itself was removed (only once every member is); trash: member =>
      # [memory files, the trash dir they were moved to]; warnings: the
      # members' ("member: line").
      UninstallResult = Struct.new(:name, :removed, :blocked, :gone, :trash, :warnings, keyword_init: true)

      module_function

      # Whether +dir+ is a meta bundle in the shipped dir.
      def shipped_meta?(dir, shipped_dir: SourceNormalizer::SHIPPED_DIR)
        return false unless File.expand_path(File.dirname(dir.to_s)) == File.expand_path(shipped_dir)

        Manifest.read(dir: dir).meta?
      rescue Manifest::ValidationError, Psych::Exception, SystemCallError
        false
      end

      # Whether the installed bundle +name+ (its provenance +data+) is a
      # meta: it records includes, or it came from chi and chi ships it as
      # a meta.
      def installed_meta?(name, data, shipped_dir: SourceNormalizer::SHIPPED_DIR)
        return false unless data.is_a?(Hash)
        return true if data[:includes].is_a?(Array)

        data[:source].to_s.match?(SourceNormalizer::SHIPPED_SOURCE) && shipped_meta?(File.join(shipped_dir, name), shipped_dir: shipped_dir)
      end

      # The members the meta has recorded: none when it isn't installed,
      # all of +manifest+'s (the shipped meta, nil when chi ships none) when
      # its provenance has no includes: an unknown record is taken as
      # everything.
      def recorded(data, manifest)
        return [] unless data
        return manifest&.includes || [] unless data[:includes].is_a?(Array)

        data[:includes].map(&:to_s)
      end

      def installed_names = Provenance.each_installed.map { |name, _| name }

      # The one rule.
      def to_install(manifest, data = Provenance.new(name: manifest.name).read, installed: installed_names)
        manifest.includes - recorded(data, manifest) - installed
      end

      # Installs the shipped meta at +dir+: its to_install members from the
      # shipped dir, then its provenance (the recorded members plus the
      # ones installed now or found installed). Never raises for a member.
      # @return [InstallResult]
      def install(dir, shipped_dir: SourceNormalizer::SHIPPED_DIR, chi_version: Samagotchi::VERSION, dry_run: false, force: false)
        manifest = Manifest.read(dir: dir)
        data = Provenance.new(name: manifest.name).read
        was = recorded(data, manifest)
        installed = installed_names
        result = InstallResult.new(name: manifest.name, version: manifest.version, installed: [],
                                   already: (manifest.includes - was) & installed, skipped: {}, failed: {})

        to_install(manifest, data, installed: installed).each do |member|
          install_member(member, shipped_dir, chi_version, dry_run, force, result)
        end
        return result if dry_run

        now = was | result.installed | result.already
        includes = (manifest.includes & now) + (now - manifest.includes)
        # Nothing new: the record stays as it is (installed_at too).
        return result if data && data[:version] == manifest.version && data[:source] == dir && data[:includes] == includes

        Provenance.new(name: manifest.name).write(
          files: {}, scope: "system", version: manifest.version, source_path: dir,
          trust_level: manifest.trust_level, requires_chi: manifest.requires_chi, includes: includes
        )
        result
      end

      def install_member(member, shipped_dir, chi_version, dry_run, force, result)
        member_dir = File.join(shipped_dir, member)
        failure = Manifest.requires_chi_failure(Manifest.read(dir: member_dir).requires_chi, chi_version)
        return result.skipped[member] = failure if failure
        return result.installed << member if dry_run

        Installer.new(source: member_dir, name: member, scope: "system", force: force, strict: true).run
        result.installed << member
      rescue StandardError => e
        result.failed[member] = e.message.lines.first.to_s.strip
      end
      private_class_method :install_member

      # Uninstalls each recorded member still installed, then the meta. A
      # member that won't go (an edited .md file, without +force+) is
      # reported and the rest carry on; the meta then stays, still
      # recording it.
      # @return [UninstallResult]
      # @raise [Uninstaller::UninstallError] when +name+ isn't installed
      def uninstall(name, shipped_dir: SourceNormalizer::SHIPPED_DIR, force: false)
        data = Provenance.new(name: name).read
        raise Uninstaller::UninstallError, "Bundle '#{name}' is not installed" unless data

        shipped = File.join(shipped_dir, name)
        manifest = File.file?(File.join(shipped, "manifest.yml")) ? Manifest.read(dir: shipped) : nil
        members = recorded(data, manifest)
        result = UninstallResult.new(name: name, removed: [], blocked: {}, gone: false, trash: {}, warnings: [])
        (members & installed_names).each do |member|
          uninstaller = Uninstaller.new(name: member, force: force)
          uninstaller.run
          result.removed << member
          result.trash[member] = [uninstaller.trashed_files, uninstaller.trash_dir] if uninstaller.trash_dir
          result.warnings.concat(uninstaller.warnings.map { |w| "#{member}: #{w}" })
        rescue Uninstaller::UninstallError => e
          result.blocked[member] = e.message
        end
        return result unless result.blocked.empty?

        Uninstaller.new(name: name, force: force).run
        result.gone = true
        result
      end
    end
  end
end
