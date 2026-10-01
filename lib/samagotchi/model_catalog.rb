# frozen_string_literal: true

require_relative "host_registry"

module Samagotchi
  # The hosts' model listings (HostRegistry#list_all_models) as rows a user
  # picks from: GET /api/models and `chi models`. Every name question goes
  # to ModelRef / HostRegistry#resolve; nothing here parses a ref.
  module ModelCatalog
    # host: the host that listed the id; ref: the name `--model` takes for
    # it (see .spell).
    Row = Data.define(:host, :id, :ref)
    # rows: the default host's first, then the others by name; warnings:
    # "host: error" per host that failed.
    Listing = Data.define(:rows, :warnings)

    module_function

    # @param results [Hash] list_all_models' answer
    # @param registry [#default_entry]
    # @return [Listing]
    def listing(results, registry:)
      default_host = registry.default_entry&.name
      rows = []
      warnings = []
      results.keys.sort_by { |name| [name == default_host ? 0 : 1, name] }.each do |host|
        data = results[host]
        if data[:error]
          warnings << "#{host}: #{data[:error]}"
          next
        end
        Array(data[:models]).each do |info|
          id = info.id.to_s
          next if id.strip.empty? || id.end_with?(":batch")

          rows << Row.new(host: host, id: id, ref: spell(host, id, default_host))
        end
      end
      Listing.new(rows: rows, warnings: warnings)
    end

    # A listed id as a ref that routes back to its host: bare on the
    # default host (a bare id goes there first), "host:id" elsewhere and for
    # a default-host id with a ':' (bare, "qwen3:8b" would name a host qwen3).
    # '/' doesn't name a host, so "openai/gpt-4o" stays bare.
    def spell(host, id, default_host)
      host == default_host && !id.include?(":") ? id : "#{host}:#{id}"
    end

    # `chi models --format json`'s object. default_host: where bare names
    # go first (its rows are the "default host" group). default: the default's listed
    # row name when it resolves to one, else its resolved ref; default_typed:
    # the alias it was typed as. A row whose name resolves elsewhere (an
    # alias named like the id shadows it) carries shadowed_by.
    # @param default_name [String, nil] default.model as configured
    # @return [Hash]
    def payload(results, registry:, default_name:)
      listing = listing(results, registry: registry)
      models = listing.rows.map do |row|
        hash = { name: row.ref, host: row.host, id: row.id }
        shadow = shadowed_by(row, registry)
        shadow ? hash.merge(shadowed_by: shadow) : hash
      end
      default, typed = default_for(default_name, listing.rows, registry)
      { default: default, default_typed: typed, default_host: registry.default_entry&.name, models: models,
        aliases: aliases(registry), warnings: listing.warnings }
    end

    # The alias (or the ref) that takes +row+'s name elsewhere, or nil.
    def shadowed_by(row, registry)
      target = registry.resolve(row.ref)
      return nil if target.entry.name == row.host && target.bare_model == row.id

      registry.model_ref(row.ref).alias_name || "#{target.entry.name}:#{target.bare_model}"
    end

    def default_for(name, rows, registry)
      return [nil, nil] if name.to_s.strip.empty?

      ref = registry.model_ref(name)
      target = registry.resolve(name)
      row = rows.find { |r| r.host == target.entry.name && r.id.casecmp?(target.bare_model) }
      [row ? row.ref : ref.ref, ref.alias_name ? name.to_s.strip : nil]
    end

    # config.yml's aliases, each under the host its target goes to: the
    # default host's first, then by host and name.
    def aliases(registry)
      default_host = registry.default_entry&.name
      names = begin
        ConfigFile.model_aliases
      rescue StandardError
        {}
      end
      rows = names.keys.map do |name|
        { name: name, ref: registry.model_ref(name).ref, host: registry.resolve(name).entry.name }
      end
      rows.sort_by { |row| [row[:host] == default_host ? 0 : 1, row[:host], row[:name]] }
    end
  end
end
