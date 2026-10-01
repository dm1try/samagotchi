# frozen_string_literal: true

module Samagotchi
  # A model ref as written (--model, /model, default.model, an alias's
  # target): an optional host prefix and a model id or alias. Pure: it is
  # given the configured hosts and aliases and asks nothing else. Routing a
  # name without a host to one (the model index after /models) is
  # HostRegistry's.
  #
  # Aliases apply once (an alias naming another alias sends that name as
  # written), also after a host prefix ("box:small"). An alias whose target
  # names another host than the prefix is a conflict (#host_conflict),
  # refused where a model comes in (ModelProfile.check_host!).
  #
  # typed: the ref as given, stripped.
  # host_name: the host the ref names (downcased), its own or its alias's;
  #   nil when it names none.
  # id: the model id the host is asked for.
  # alias_name: the alias applied (as typed), else nil.
  # alias_host: the host the alias's target names, else nil.
  ModelRef = Data.define(:typed, :host_name, :id, :alias_name, :alias_host) do
    # Splits "host:model" when the prefix is a configured host and something
    # follows it. Only ':' names a host: "openai/gpt-4o" is an id (OpenRouter's).
    # @param hosts [Hash] configured hosts by name (any value)
    # @return [Array(String, String)] [host_name or nil, the rest]
    def self.split(raw, hosts:)
      value = raw.to_s.strip
      return [nil, value] if value.empty?

      prefix, rest = value.split(":", 2)
      return [nil, value] if rest.nil? || rest.strip.empty?
      return [nil, value] unless (hosts || {}).keys.map { |k| k.to_s.downcase }.include?(prefix.strip.downcase)

      [prefix.strip.downcase, rest.strip]
    end

    # @param aliases [Hash{String => String}] alias (downcased) => target
    # @return [ModelRef]
    def self.parse(raw, hosts:, aliases:)
      value = raw.to_s.strip
      host, rest = split(value, hosts: hosts)
      name = host ? rest : value
      target = aliases[name.downcase]
      return new(typed: value, host_name: host, id: name, alias_name: nil, alias_host: nil) unless target

      alias_host, alias_id = split(target, hosts: hosts)
      new(typed: value, host_name: host || alias_host, id: alias_host ? alias_id : target, alias_name: name,
          alias_host: alias_host)
    end

    # The resolved ref a session stores: "host:id", or the id when no host
    # is named (routed when it runs).
    def ref = host_name ? "#{host_name}:#{id}" : id

    # The host the alias names when the ref's own prefix names another, else nil.
    def host_conflict
      alias_host if alias_host && alias_host != host_name
    end
  end
end
