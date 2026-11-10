# frozen_string_literal: true

require "rbconfig"
require "shellwords"

module Samagotchi
  autoload :ContextSources, File.expand_path("context_sources", __dir__)
  autoload :Log, File.expand_path("log", __dir__)
  module MemoryBundle
    autoload :Provenance, File.expand_path("memory_bundle/provenance", __dir__)
  end

  # Declarative context providers (attached context, §3.9): a bundle's
  # manifest maps a URL pattern to a source, so any process (the CLI, the
  # web server, a worker) can attach a URL without loading plugins:
  #
  #   context_providers:
  #     - match: '\Ahttps://github\.com/([^/]+)/([^/]+)/pull/(\d+)'
  #       name: 'pr-\3'
  #       cmd: '{ruby} {bundle_dir}/scripts/pr_context.rb {url}'
  #       why: 'GitHub PR'
  #       every_seconds: 300
  #
  # The installer records them in the bundle's provenance; .resolve reads
  # them from there. +name+ takes the match's groups (\1…); +cmd+ takes
  # {url}, the matched URL (shell-quoted), when the source is attached, and
  # keeps {bundle_dir}, the installed bundle's folder, and {ruby}, the Ruby
  # chi runs on, for ContextFetch to fill in when it runs: a bundle upgrade
  # moves nothing, and a `ruby` on the PATH may be another one (macOS's 2.6,
  # a launchd PATH).
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
    RUBY = "{ruby}"
    URL = "{url}"
    MIN_EVERY_SECONDS = 30
    # A bundle whose requires_chi this chi doesn't meet, already logged: said
    # once per process per bundle and version, the way GuardrailWiring says a
    # bundle's kept rules are.
    TOO_NEW_LOGGED = Set.new
    TOO_NEW_LOG_LOCK = Mutex.new

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

    # The source the installed bundles' providers make of +url+: the first
    # bundle (by name) whose provider matches. A bundle whose providers
    # don't parse, or whose requires_chi this chi doesn't meet, is skipped
    # (logged).
    # @return [Resolved, nil] nil when none matches
    # @raise [Invalid] the provider makes a name that isn't a source name
    def resolve(url)
      url = url.to_s.strip
      MemoryBundle::Provenance.each_installed do |bundle, record|
        next if record.error? || too_new?(bundle, record.manifest)

        providers(bundle, record.manifest).each do |provider|
          match = provider.regexp.match(url) or next
          return resolved(bundle, provider, match)
        end
      end
      nil
    end

    # Whether an installed bundle declares a provider (the web's "+ URL").
    def any?
      MemoryBundle::Provenance.each_installed.any? do |bundle, record|
        !record.error? && !too_new?(bundle, record.manifest) && record.manifest.context_providers?
      end
    end

    # A bundle this chi is too old for has no usable providers: skip it, and
    # say so once per process per bundle and version.
    # @return [Boolean]
    def too_new?(bundle, manifest)
      return false unless manifest.context_providers?

      failure = manifest.requires_chi_failure
      return false if failure.nil?

      if TOO_NEW_LOG_LOCK.synchronize { TOO_NEW_LOGGED.add?([bundle, manifest.version.to_s]) }
        Log.warn(:context, "providers_too_new", bundle: bundle, version: manifest.version.to_s,
                                            requires_chi: manifest.requires_chi.to_s, msg: failure)
      end
      true
    end

    # Its parsed providers; a list that doesn't parse is none (logged).
    def providers(bundle, manifest)
      if (problem = manifest.problems["context_providers"])
        Log.warn(:context, "providers_unreadable", bundle: bundle, msg: problem)
      end
      manifest.context_providers
    end

    def resolved(bundle, provider, match)
      url = match[0]
      name = provider.name.gsub(/\\(\d)/) { match[Regexp.last_match(1).to_i].to_s }
      begin
        ContextSources.check_name!(name)
      rescue ContextSources::Invalid
        raise Invalid, "bundle #{bundle} makes #{name.inspect} of it, which isn't a source name"
      end
      Resolved.new(bundle: bundle, name: name, cmd: provider.cmd.gsub(URL) { Shellwords.escape(url) },
                   why: provider.why, hint: url, every_seconds: provider.every_seconds)
    end

    # +source+'s command as it runs: {bundle_dir} is its provider's
    # installed folder, once that bundle is there and its scripts are as
    # installed (they run outside the guardrails gate, as a plugin loads:
    # checked the same way).
    # @return [String]
    # @raise [Invalid] the bundle is gone, a script is gone, unrecorded or
    #   changed (Provenance#script_failure), or this chi doesn't meet the
    #   bundle's requires_chi
    def command_for(source)
      return source.cmd unless source.provider

      provenance = MemoryBundle::Provenance.new(name: source.provider)
      record = provenance.record
      raise Invalid, "bundle #{source.provider} isn't installed" unless record

      # Its bundle is too new for this chi (installed with --force, or chi
      # was downgraded): its script won't run, as its plugin wouldn't load.
      if (failure = record.manifest.requires_chi_failure)
        raise Invalid, "bundle #{source.provider}: #{failure}"
      end

      record.scripts.each do |file, sha|
        failure = provenance.script_failure(file, sha)
        raise Invalid, failure if failure
      end
      source.cmd.gsub(BUNDLE_DIR) { Shellwords.escape(provenance.bundle_dir) }.gsub(RUBY) { Shellwords.escape(RbConfig.ruby) }
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
