# frozen_string_literal: true

module Samagotchi
  autoload :MutedMemories, File.expand_path("muted_memories", __dir__)
  autoload :Log, File.expand_path("log", __dir__)
  module MemoryBundle
    autoload :Provenance, File.expand_path("memory_bundle/provenance", __dir__)
    autoload :Manifest, File.expand_path("memory_bundle/manifest", __dir__)
  end

  # The outside commands a bundle declares in its manifest's `needs:`
  # (docs/memory.md). Advisory only: a PATH lookup in Ruby, no subprocess,
  # nothing installed. Install/upgrade warn, `chi bundle status` lists, and
  # the prompt's index marks a bundle memory whose need is missing.
  module BundleNeeds
    # Whether some PATH folder holds an executable file (not a directory)
    # named +command+. An empty or missing PATH finds nothing.
    def self.found?(command, path: ENV["PATH"])
      return false if path.nil? || path.empty?

      path.split(File::PATH_SEPARATOR).any? do |dir|
        next false if dir.empty?

        file = File.join(dir, command.to_s)
        File.file?(file) && File.executable?(file)
      end
    end

    # The needs (hashes with :command) whose command isn't found.
    def self.missing(needs, path: ENV["PATH"])
      Array(needs).reject { |need| found?(need[:command], path: path) }
    end

    # "[needs gh, jq: not found on PATH]", or nil when nothing is missing.
    # No em dash: IndexUpdater.extract_description splits on " — ".
    def self.marker(missing)
      commands = Array(missing).map { |need| need[:command] }
      return nil if commands.empty?

      "[needs #{commands.join(", ")}: not found on PATH]"
    end

    # The prompt's index text for +scope+ with a marker on each line naming
    # a memory of an installed bundle (of that scope) whose needs aren't all
    # on +path+. Every other byte stays; with nothing missing the text comes
    # back as is. Never raises: on any error the text comes back unchanged.
    def self.annotate_index(text, scope, path: ENV["PATH"], bundles_dir: nil)
      return text if text.nil? || text.empty?

      markers = entry_markers(scope, path: path, bundles_dir: bundles_dir || MemoryBundle::Provenance.bundles_dir)
      return text if markers.empty?

      text.each_line.map do |line|
        marker = markers[MutedMemories.index_line_name(line)]
        next line unless marker

        body = line.chomp
        "#{body} #{marker}#{line[body.length..]}"
      end.join
    rescue StandardError => e
      Log.debug(:memory, "bundle_needs_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      text
    end

    # entry name → marker, for the installed bundles of +scope+ with a
    # missing need. A manifest.json or needs: that doesn't parse is skipped.
    def self.entry_markers(scope, path:, bundles_dir:)
      MemoryBundle::Provenance.each_installed(dir: bundles_dir).each_with_object({}) do |(_name, bundle), acc|
        next if bundle.error? || bundle.scope.to_s != scope.to_s || !bundle.needs?

        needs = begin
          MemoryBundle::Manifest.parse_needs(bundle.needs)
        rescue MemoryBundle::Manifest::ValidationError
          next
        end
        marker = marker(missing(needs, path: path))
        next unless marker

        bundle.files.each_key do |key|
          name = MutedMemories.normalize(key)
          acc[name] ||= marker if name
        end
      end
    end
    private_class_method :entry_markers
  end
end
