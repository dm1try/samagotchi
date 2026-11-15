# frozen_string_literal: true

require_relative "units"

module PartialUse
  # "Narrow door, heavy load": A requires B, B drags in files A would not reach
  # otherwise, and A names only a handful of them. Names are matched, never
  # executed, so every count here is an upper bound.
  class Doors
    Row = Data.define(:from, :to, :added, :names)

    MIN_FILES = 1
    NAMES_SHOWN = 10
    # The spec helper's own doors are not product paths: they are left out
    # unless --include-testing asks for them.
    TESTING = "lib/samagotchi/testing/"

    def initialize(units, entry: nil, min_files: MIN_FILES, include_testing: false)
      @units = units
      @entry = entry
      @min_files = min_files
      @include_testing = include_testing
    end

    def report
      scope = scoped
      return [] if scope.nil?

      # A file under lib/samagotchi/testing/ is a spec helper, not a product
      # path: its doors are only interesting with --include-testing.
      readers = @include_testing ? scope : scope.reject { _1.start_with?(TESTING) }

      readers.flat_map do |from|
        unit = @units.units[from]
        full = @units.reach(from)
        unit.requires.filter_map do |require|
          to = @units.internal(require)
          next if to.nil? || to == from

          added = full - @units.reach(from, skip: to)
          next if added.size < @min_files

          Row.new(from, to, added.size, used(unit, @units.closure(to)).sort)
        end
      end.sort_by { [_1.added * -1, _1.names.size, _1.from, _1.to] }
    end

    def self.line(row)
      names = row.names.first(NAMES_SHOWN)
      more = row.names.size - names.size
      suffix = more.positive? ? " (+#{more} more)" : ""
      format("%5d %5d  %s -> %s  (names: %s%s)", row.added, row.names.size, row.from, row.to, names.join(", "), suffix)
    end

    private

    # nil when --entry names a file the reports do not read: the script prints
    # nothing then.
    def scoped
      return @units.units.keys if @entry.nil?

      entry = @units.units.key?(@entry) ? @entry : nil
      return nil if entry.nil?

      Set.new([entry]) | @units.reach(entry)
    end

    # The names this file takes from what the door pulls in: the constants it
    # names that are defined there, and the methods it calls on them.
    def used(unit, closure)
      closure = closure.to_set
      names = Set.new
      unit.refs.each do |ref|
        name = @units.resolve(ref.parts, ref.scope)
        names << name if name && @units.definers(name).any? { closure.include?(_1) }
      end
      unit.calls.each do |call|
        receiver = @units.resolve(call.receiver, call.scope)
        next if receiver.nil? || !@units.definers(receiver).any? { closure.include?(_1) }

        names << "#{receiver}.#{call.name}"
      end
      names
    end
  end
end
