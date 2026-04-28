# frozen_string_literal: true

module Samagotchi
  module Tools
    # Reads a file from disk and returns its contents as a string.
    class Read
      NAME        = "read"
      DESCRIPTION = "Read a file from disk and return its full contents."

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(path)
        File.read(path.strip)
      rescue Errno::ENOENT
        "Error: file not found: #{path.strip}"
      rescue => e
        "Error: #{e.message}"
      end
    end
  end
end
