# frozen_string_literal: true

module Samagotchi
  module MemoryBundle
    # Detects {{placeholder}} patterns in file content.
    # Placeholders are hints, not gates — install succeeds with unfilled ones.
    class Placeholder
      PLACEHOLDER_RE = /\{\{([^}]+)\}\}/

      attr_reader :placeholders

      def initialize(content:)
        @placeholders = extract_placeholders(content)
      end

      def self.detect_in_file(path)
        content = File.read(path)
        new(content: content).placeholders
      end

      # Returns a sorted list of unique placeholder names found.
      def unique_names
        @placeholders.map(&:strip).uniq.sort
      end

      def any?
        !@placeholders.empty?
      end

      private

      def extract_placeholders(content)
        content.scan(PLACEHOLDER_RE).flatten
      end
    end
  end
end
