# frozen_string_literal: true

module Samagotchi
  # A model ref as written (--model, /model, default.model, an alias's
  # target): an optional host prefix and a model id or alias. Pure: it is
  # given the configured hosts and aliases and asks nothing else. Routing a
  # name without a host to one (the model index after /models) is
  # HostRegistry's.
  #
  # typed: the ref as given, stripped.
  # host_name: the host the ref names (downcased), its own or its alias's;
  #   nil when it names none.
  # alias_resolved: the model id the host is asked for after aliases.
  # sent_id_unresolved: the ref without its host prefix, aliases not applied.
  # alias_ref: the ref after aliases, host prefix kept as typed.
  ModelRef = Data.define(:typed, :host_name, :alias_resolved, :sent_id_unresolved, :alias_ref) do
    # Splits "host:model" or "host/model" when the prefix is a configured
    # host and something follows it.
    # @param hosts [Hash] configured hosts by name (any value)
    # @return [Array(String, String)] [host_name or nil, the rest]
    def self.split(raw, hosts:)
      value = raw.to_s.strip
      return [nil, value] if value.empty?

      lowered_keys = (hosts || {}).keys.map(&:downcase)
      [":", "/"].each do |separator|
        next unless value.include?(separator)

        prefix, rest = value.split(separator, 2)
        return [prefix.strip.downcase, rest.strip] if lowered_keys.include?(prefix.strip.downcase) && !rest.strip.empty?
      end
      [nil, value]
    end

    # @param aliases [Hash{String => String}] alias (downcased) => target
    # @return [ModelRef]
    def self.parse(raw, hosts:, aliases:)
      value = raw.to_s.strip
      host, rest = split(value, hosts: hosts)
      if host
        target = aliases.fetch(rest.downcase, rest)
        lowered = value.downcase
        separator = lowered.include?("#{host}:") || !lowered.include?("#{host}/") ? ":" : "/"
        return new(typed: value, host_name: host, alias_resolved: target, sent_id_unresolved: rest,
                   alias_ref: "#{host}#{separator}#{target}")
      end

      target = aliases.fetch(value.downcase, value)
      alias_host, alias_rest = target == value ? nil : split(target, hosts: hosts)
      new(typed: value, host_name: alias_host, alias_resolved: alias_host ? alias_rest : target,
          sent_id_unresolved: value, alias_ref: target)
    end
  end
end
