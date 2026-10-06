# frozen_string_literal: true

module Samagotchi
  # Declarative context providers (attached context, §3.9): a bundle's
  # manifest maps a URL pattern to a source, so any process (the CLI, the
  # web server, a worker) can attach a URL without loading plugins:
  #
  #   context_providers:
  #     - match: '\Ahttps://github\.com/([^/]+)/([^/]+)/pull/(\d+)'
  #       name: 'pr-\3'
  #       cmd: 'ruby {bundle_dir}/scripts/pr_context.rb {url}'
  #       why: 'GitHub PR'
  #       every_seconds: 300
  #
  # The installer records them in the bundle's provenance; .resolve reads
  # them from there. +name+ takes the match's groups (\1…); +cmd+ takes
  # {url}, the matched URL (shell-quoted), when the source is attached, and
  # keeps {bundle_dir}, the installed bundle's folder, for ContextFetch to
  # fill in when it runs: a bundle upgrade moves nothing.
  module ContextProviders
    # A provider as the manifest declares it.
    Provider = Data.define(:match, :name, :cmd, :why, :every_seconds) do
      def to_h = { "match" => match, "name" => name, "cmd" => cmd, "why" => why, "every_seconds" => every_seconds }.compact

      def regexp = Regexp.new(match)
    end

    # What a URL resolved to: the provider's bundle, and the source's
    # fields (+cmd+ still holding {bundle_dir}).
    Resolved = Data.define(:bundle, :name, :cmd, :why, :hint, :every_seconds)

    class Invalid < ArgumentError; end

    BUNDLE_DIR = "{bundle_dir}"
    URL = "{url}"
    MIN_EVERY_SECONDS = 30

    module_function

    # The manifest's context_providers: list.
    # @return [Array<Provider>] [] when absent
    # @raise [Invalid]
    def parse_list(raw)
      return [] if raw.nil?
      raise Invalid, "context_providers: must be a list of mappings" unless raw.is_a?(Array)

      raw.map { |item| parse(item) }
    end

    # @raise [Invalid]
    def parse(item)
      raise Invalid, "context_providers: each item must be a mapping, not #{item.inspect}" unless item.is_a?(Hash)

      data = item.transform_keys(&:to_s)
      %w[match name cmd].each do |key|
        value = data[key]
        raise Invalid, "context_providers: an item has no #{key}:" unless value.is_a?(String) && !value.strip.empty?
      end
      begin
        Regexp.new(data["match"])
      rescue RegexpError => e
        raise Invalid, "context_providers: match #{data["match"].inspect} isn't a regular expression (#{e.message})"
      end
      Provider.new(match: data["match"], name: data["name"], cmd: data["cmd"], why: data["why"]&.to_s,
                   every_seconds: every(data["every_seconds"]))
    end

    def every(value)
      return nil if value.nil?

      seconds = Integer(value.to_s, 10, exception: false)
      unless seconds && seconds >= MIN_EVERY_SECONDS
        raise Invalid, "context_providers: every_seconds is #{value.inspect}; it takes seconds, at least #{MIN_EVERY_SECONDS}"
      end

      seconds
    end
  end
end
