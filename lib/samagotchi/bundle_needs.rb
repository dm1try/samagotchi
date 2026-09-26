# frozen_string_literal: true

module Samagotchi
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
  end
end
