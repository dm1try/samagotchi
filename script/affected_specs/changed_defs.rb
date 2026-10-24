# frozen_string_literal: true

module AffectedSpecs
  # The methods a change touches: the innermost `def` around each changed
  # line, read with Prism (a default gem; 1.0 or later, else nothing).
  module ChangedDefs
    MIN_PRISM = "1.0"

    # Whether Prism 1.0 or later loads; below it the callers tier is skipped.
    def self.available?
      return @available unless @available.nil?

      @available = begin
        require "prism"
        Gem::Version.new(Prism::VERSION) >= Gem::Version.new(MIN_PRISM)
      rescue LoadError
        false
      end
    end

    # The names of the innermost defs in +source+ whose lines cover one of
    # +lines+, in source order, each once. A source with syntax errors still
    # gives the defs Prism recovers.
    def self.names(source, lines)
      return [] if lines.empty? || !available?

      defs = Collector.collect(source)
      picked = lines.uniq.filter_map do |line|
        defs.select { |range, _| range.cover?(line) }.min_by { |range, _| range.size }
      end
      picked.uniq.sort_by { |range, _| range.begin }.map(&:last).uniq
    end

    # [[start_line..end_line, name], …] for every def in a source.
    module Collector
      def self.collect(source)
        visitor = Class.new(Prism::Visitor) do
          attr_reader :defs

          def initialize
            super
            @defs = []
          end

          def visit_def_node(node)
            @defs << [node.location.start_line..node.location.end_line, node.name.to_s]
            super
          end
        end.new
        Prism.parse(source).value.accept(visitor)
        visitor.defs
      end
    end
  end
end
