# frozen_string_literal: true

require_relative "installed_bundle"
require_relative "installer"
require_relative "manifest"
require_relative "provenance"
require_relative "source"

module Samagotchi
  module MemoryBundle
    # The one owner of the words for an installed bundle's manifest.yml, as
    # InstalledManifest read it (chi bundle status's Manifest: line, chi
    # update's row), and of keeping it for a record an older chi wrote
    # (.keep: Provenance#adopt_manifest from where it came from). The cases:
    #   :kept     read from the kept file; a line only when chi +installed_by+
    #             predates a key it uses (Manifest::SINCE): newer than its installer
    #   :legacy   no kept file, no manifest_sha: a chi before the kept manifest installed it
    #   :stale    a kept file, no manifest_sha: such a chi rewrote the record since
    #   :missing  a manifest_sha, no kept file
    #   :edited   the kept file isn't the recorded one (or isn't a YAML mapping)
    # The first three and :missing are "unkept": chi update keeps the manifest
    # where it has the bundle's own at the recorded version, else the line
    # names the command that does.
    module ManifestStanding
      UNKEPT = %i[legacy stale missing].freeze

      # What .keep did: bundle is the record after it (re-read when kept),
      # line what to say (nil: nothing), kept whether it kept (or, in a dry
      # run, would keep) the manifest.
      Outcome = Data.define(:bundle, :line, :kept)

      module_function

      # @param bundle [InstalledBundle]
      # @return [Symbol, nil] the case, nil for a record with no dir or that doesn't read
      def state(bundle)
        return nil if bundle.error? || bundle.dir.nil?

        manifest = bundle.manifest
        return :kept if manifest.origin == :kept

        manifest.standing || :legacy
      end

      # "[kept]" when chi reads the kept manifest.yml, else "[from the install record]".
      def label(bundle) = state(bundle) == :kept ? "[kept]" : "[from the install record]"

      # The case in words with what to run, nil for a clean kept one.
      # @param refused [String, Symbol, nil] why .keep didn't keep it: :git (not
      #   cloned), :gone (no source left), or Provenance#adopt_manifest's why.
      #   nil: not tried, so a source chi update can read says that it will.
      # @return [String, nil]
      def line(bundle, refused: nil)
        case (state = state(bundle))
        when :kept then newer_line(bundle)
        when :edited then "manifest.yml changed since it was installed, so chi reads the install record (#{reinstall(bundle)})"
        when *UNKEPT then "#{unkept_words(state)}: #{unkept_fix(bundle, refused)}"
        end
      end

      # #line as chi bundle status says it: for a record chi update would keep
      # from its folder, a dry Provenance#adopt_manifest first, so the line says
      # whether it will or why not (an archive isn't extracted here: chi update
      # tries it).
      # @return [String, nil]
      # A bundle chi ships is checked against this chi's shipped copy, which chi
      # update reads (at another version, chi update upgrades it instead).
      def status_line(bundle)
        return line(bundle) unless bundle.manifest_unkept? && !bundle.dev && !bundle.profile?

        dir = try_dir(bundle)
        dir ? line(bundle, refused: Provenance.new(name: bundle.name).adopt_manifest(dir, dry_run: true)) : line(bundle)
      end

      # The folder chi update keeps it from, nil when it wouldn't try one here.
      def try_dir(bundle)
        source = bundle.source.to_s.strip
        unless SourceIdentity.of(source)&.shipped?
          return source.start_with?("/") && File.directory?(source) ? source : nil
        end

        dir = File.join(SourceNormalizer::SHIPPED_DIR, File.basename(source.chomp("/")))
        File.file?(File.join(dir, "manifest.yml")) && Manifest.read(dir: dir).version == bundle.version.to_s ? dir : nil
      rescue Manifest::ValidationError, Psych::Exception
        nil
      end

      # Keeps the manifest of a record without a usable kept one (UNKEPT, not
      # dev) from +source_dir+, else from the record's source: a dir as it is,
      # a zip or tar extracted and removed after; a git URL is never cloned.
      # A bundle with nothing to keep gets its #line.
      # @return [Outcome]
      def keep(bundle, source_dir: nil, dry_run: false)
        return Outcome.new(bundle: bundle, line: line(bundle), kept: false) unless bundle.manifest_unkept? && !bundle.dev

        refused = adopt(bundle, source_dir, dry_run)
        return Outcome.new(bundle: bundle, line: line(bundle, refused: refused), kept: false) if refused

        kept = dry_run ? bundle : Provenance.new(name: bundle.name).record
        Outcome.new(bundle: kept, line: dry_run ? "would keep its manifest" : "kept its manifest", kept: true)
      end

      # @return [String, Symbol, nil] why not (as #line's refused:), nil when kept
      def adopt(bundle, source_dir, dry_run)
        provenance = Provenance.new(name: bundle.name)
        return provenance.adopt_manifest(source_dir, dry_run: dry_run) if source_dir

        source = bundle.source.to_s.strip
        return :git if SourceNormalizer.git_url?(source)
        return :gone unless local?(source)
        return provenance.adopt_manifest(source, dry_run: dry_run) if File.directory?(source)

        prepared = PreparedSource.prepare(source)
        begin
          provenance.adopt_manifest(prepared.dir, dry_run: dry_run)
        ensure
          prepared.cleanup
        end
      rescue SourceNormalizer::UnknownSourceError => e
        e.message
      end

      def unkept_words(state)
        case state
        when :legacy then "installed by an older chi, which didn't keep its manifest"
        when :stale then "an older chi rewrote its record after the install, so its manifest.yml may be an earlier version's"
        else "its kept manifest.yml is gone, so chi reads the install record"
        end
      end

      def unkept_fix(bundle, refused)
        source = bundle.source.to_s.strip
        return reinstall(bundle) if bundle.dev
        return "chi bundle upgrade #{bundle.name} reads it again from #{source}" if refused == :git || SourceNormalizer.git_url?(source)
        return Installer.source_gone_line(bundle.name, source) if gone?(source, refused)

        shipped = SourceIdentity.of(source)&.shipped?
        # chi update keeps a profile's only when chi ships it (ShippedUpdate).
        return "chi bundle upgrade #{bundle.name} reads it again from #{source}" if bundle.profile? && !shipped

        if refused
          upgrade = shipped ? "chi bundle upgrade #{bundle.name}" : "chi bundle upgrade #{bundle.name} reads it again from #{source}"
          return "#{upgrade} (#{refused})"
        end
        return "chi update keeps it" if shipped

        File.file?(source) ? "chi update tries to keep it from #{source}" : "chi update keeps it from #{source}"
      end

      def gone?(source, refused) = refused == :gone || (refused.nil? && !SourceIdentity.of(source)&.shipped? && !local?(source))

      # A source chi can read again here: an absolute path that is there.
      def local?(source) = source.start_with?("/") && File.exist?(source)

      def reinstall(bundle) = bundle.dev ? "chi bundle install --dev #{bundle.source}" : "chi bundle upgrade #{bundle.name}"

      # The kept keys whose floor is above the chi that installed it.
      def newer_line(bundle)
        by = bundle.installed_by.to_s
        return nil if by.empty? || !Gem::Version.correct?(by)

        newer = bundle.manifest.floor_keys.select { |_, floor| Gem::Version.new(floor) > Gem::Version.new(by) }
        return nil if newer.empty?

        keys = newer.map { |key, floor| "#{key}: (#{floor})" }.join(", ")
        "installed by chi #{by}, which didn't act on #{keys}: #{reinstall(bundle)}"
      end
      private_class_method :try_dir, :adopt, :unkept_words, :unkept_fix, :gone?, :local?, :reinstall, :newer_line
    end
  end
end
