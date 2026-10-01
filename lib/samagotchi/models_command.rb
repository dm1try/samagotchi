# frozen_string_literal: true

require "json"
require_relative "host_registry"
require_relative "model_catalog"
require_relative "model_profile"
require_relative "cli/command"
require_relative "cli/flags"

module Samagotchi
  # `chi models`: the names `--model` (and `chi send --new --model`) takes,
  # listed anew from every host in parallel, within a bounded wait; the
  # desktop helper's model picker reads --format json. No cache: each run
  # lists every host (the registry's TTLs live in one process only).
  class ModelsCommand
    include CLI::Command

    DEFAULT_TIMEOUT = 4.0
    FORMATS = %w[text json].freeze

    USAGE = <<~TEXT
      Usage: chi models [--format text|json] [--timeout S] [TEXT]
        Lists the models every configured host offers, as the names
        --model takes: the default first, a default-host id bare, another
        host's as host:id, then the aliases as "name -> ref". A host that
        fails or doesn't answer in time is noted on stderr.
        TEXT          only the names containing it (any case)
        --format json the default, the models (host, id, name), the aliases
                      and the warnings as one JSON object
        --timeout S   wait at most S seconds for the hosts; default 4
        Exit 0 when any host listed its models, 1 when none did (the
        default is still printed), 2 on a usage error.
    TEXT

    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS) do |f|
      f.value "--format"
      f.value "--timeout"
    end

    # @param registry [HostRegistry, nil] specs inject one
    # @param default_name [String, nil, :config] default.model; :config reads it
    def initialize(argv, stdout: $stdout, stderr: $stderr, registry: nil, default_name: :config)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @registry = registry
      @default_name = default_name
    end

    # @return [Integer] 0 any host listed, 1 none did, 2 usage
    def run
      parsed = parse_flags(FLAGS, @argv, format: "text", timeout: DEFAULT_TIMEOUT.to_s)
      return parsed if parsed.is_a?(Integer)

      options = parsed.options
      return usage_error("--format takes text or json") unless FORMATS.include?(options[:format])

      timeout = Float(options[:timeout], exception: false)
      return usage_error("--timeout takes a number of seconds above 0") unless timeout&.positive?

      payload, listed = catalog(timeout)
      payload = filtered(payload, parsed.args.join(" ").strip)
      options[:format] == "json" ? print_json(payload) : print_text(payload)
      listed ? 0 : 1
    end

    private

    def command_name = "chi models"

    # @return [Array(Hash, Boolean)] the payload and whether any host listed
    def catalog(timeout)
      registry = @registry || HostRegistry.new
      results = registry.list_all_models(force: true, wait: timeout)
      listed = results.values.any? { |data| data[:error].nil? }
      [ModelCatalog.payload(results, registry: registry, default_name: default_name), listed]
    rescue StandardError => e
      [{ default: default_name, default_typed: nil, default_host: nil, models: [], aliases: [], warnings: [e.message] }, false]
    end

    def default_name
      return @default_name unless @default_name == :config

      ModelProfile.required_model_name
    rescue ArgumentError
      nil
    end

    def filtered(payload, text)
      return payload if text.empty?

      needle = text.downcase
      payload.merge(models: payload[:models].select { |m| m[:name].downcase.include?(needle) },
                    aliases: payload[:aliases].select { |a| "#{a[:name]} #{a[:ref]}".downcase.include?(needle) },
                    filter: text)
    end

    def print_json(payload)
      @stdout.puts(JSON.generate(payload.except(:filter)))
    end

    def print_text(payload)
      default = payload[:default]
      names = payload[:models].reject { |m| m[:shadowed_by] }.map { |m| m[:name] }
      shown_default = default && (payload[:filter].nil? || default.downcase.include?(payload[:filter].downcase))
      @stdout.puts(default) if shown_default
      (names - [default]).each { |name| @stdout.puts(name) }
      payload[:aliases].each { |a| @stdout.puts("#{a[:name]} -> #{a[:ref]}") }
      payload[:warnings].each { |w| @stderr.puts("chi models: #{w}") }
    end
  end
end
