# frozen_string_literal: true

require_relative "units"

module PartialUse
  # "Wide class, partial use": a namespace with many public methods where each
  # client file calls a small share of them. The matching is by name, so a
  # client that calls `run` on something else still counts in the any column:
  # every share here is an upper bound.
  class Wide
    Client = Data.define(:path, :qualified, :any, :share)
    Row = Data.define(:name, :count, :max_share, :any_share, :clients)

    MIN_PUBLIC = 15
    MIN_CLIENTS = 2
    # The engine's own top-level module: its public defs are the whole engine,
    # so a share against it says nothing about a class to split.
    ROOT = "Samagotchi"

    def initialize(units, min_public: MIN_PUBLIC, min_clients: MIN_CLIENTS)
      @units = units
      @min_public = min_public
      @min_clients = min_clients
      @usage = {}
    end

    def report
      publics = Hash.new { |hash, name| hash[name] = Set.new }
      @units.units.each_value do |unit|
        unit.methods.each do |method|
          next unless method.visibility == :public

          namespace = method.scope.join("::")
          publics[namespace] << method.name if @units.known?(namespace)
        end
      end

      publics.filter_map do |name, methods|
        next if methods.size < @min_public || name == ROOT

        clients = clients_of(name, methods)
        next if clients.size < @min_clients

        # An instance-style class is called through an object, so the direct
        # share is 0 by construction: the any share is what ranks a row.
        Row.new(name, methods.size, clients.map(&:share).max,
                clients.map { _1.any / methods.size.to_f }.max, clients)
      end.sort_by { [_1.any_share, -_1.count, _1.name] }
    end

    def self.line(row)
      lines = [format("%s  %d public  max %d%%  any %d%%  %d clients",
                      row.name, row.count, (row.max_share * 100).round, (row.any_share * 100).round, row.clients.size)]
      row.clients.each do |client|
        lines << format("  %s  %d/%d (%d%%)  any %d/%d (%d%%)",
                        client.path, client.qualified, row.count, (client.share * 100).round,
                        client.any, row.count, (client.any / row.count.to_f * 100).round)
      end
      lines
    end

    private

    # Every file that names the namespace, the files defining it apart.
    def clients_of(name, methods)
      definers = @units.definers(name).to_set
      @units.units.filter_map do |path, unit|
        next if definers.include?(path)

        qualified, any = usage(unit)
        next unless qualified.key?(name) || names?(unit, name)

        called = qualified[name].count { methods.include?(_1) }
        any_count = methods.count { any.include?(_1) }
        Client.new(path, called, any_count, called / methods.size.to_f)
      end.sort_by { [_1.share, _1.path] }.reverse
    end

    def names?(unit, name)
      unit.refs.any? { |ref| @units.resolve(ref.parts, ref.scope) == name }
    end

    # Per file: the method names called on each constant, and every method name
    # called at all (the any-receiver upper bound).
    def usage(unit)
      @usage[unit] ||= begin
        qualified = Hash.new { |hash, key| hash[key] = Set.new }
        any = Set.new
        unit.calls.each do |call|
          any << call.name
          receiver = @units.resolve(call.receiver, call.scope)
          qualified[receiver] << call.name if receiver
        end
        [qualified, any]
      end
    end
  end
end
