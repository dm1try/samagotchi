# frozen_string_literal: true

module Samagotchi
  autoload :Log, File.expand_path("log", __dir__)
  autoload :VERSION, File.expand_path("version", __dir__)
  module MemoryBundle
    autoload :Manifest, File.expand_path("memory_bundle/manifest", __dir__)
    autoload :Provenance, File.expand_path("memory_bundle/provenance", __dir__)
  end

  # Declarative block renderers (docs/plugins.md, docs/internals/block-renderers.md):
  # a bundle's manifest maps a fenced block's language to the scripts/ files the
  # owner's page loads to draw it:
  #
  #   block_renderers:
  #     - lang: mermaid
  #       load: [mermaid.tiny.js, mermaid_renderer.js]
  #
  # JS draws, in a sandboxed frame; Ruby only routes and serves, so chi web
  # (which runs no plugins) can answer, and a reloaded page draws after the
  # worker has gone. The installer records them in the bundle's provenance;
  # .for_installed reads them from there.
  module BlockRenderers
    # A renderer as the manifest declares it.
    Renderer = Data.define(:lang, :load) do
      def to_h = { "lang" => lang, "load" => load }
    end

    # One the page may use: the bundle that won the language, and its files.
    Installed = Data.define(:lang, :bundle, :files)

    class Invalid < ArgumentError; end

    # A language a block can carry: a fence's first word, downcased
    # (MarkdownRenderer sets it as data-lang under this same pattern).
    LANG = /\A[a-z0-9_+-]{1,32}\z/

    module_function

    # The manifest's block_renderers: list.
    # @return [Array<Renderer>] [] when absent
    # @raise [Invalid]
    def parse_list(raw)
      return [] if raw.nil?
      raise Invalid, "block_renderers: must be a list of mappings" unless raw.is_a?(Array)

      renderers = raw.map { |item| parse(item) }
      twice = renderers.map(&:lang).tally.select { |_lang, count| count > 1 }.keys
      raise Invalid, "block_renderers: #{twice.join(", ")} listed more than once" unless twice.empty?

      renderers
    end

    # @raise [Invalid]
    def parse(item)
      raise Invalid, "block_renderers: each item must be a mapping, not #{item.inspect}" unless item.is_a?(Hash)

      data = item.transform_keys(&:to_s)
      lang = data["lang"]
      unless lang.is_a?(String) && lang.match?(LANG)
        raise Invalid, "block_renderers: lang #{lang.inspect} isn't a fence's language (lowercase letters, digits, _ + -; at most 32)"
      end

      load = data["load"]
      unless load.is_a?(Array) && !load.empty? && load.all? { |file| file.is_a?(String) && file.match?(MemoryBundle::Manifest::SCRIPT_FILE) }
        raise Invalid, "block_renderers: #{lang}'s load must be a non-empty list of file names in scripts/, not #{load.inspect}"
      end

      Renderer.new(lang: lang, load: load)
    end

    # What the installed bundles draw: the first bundle by name wins a
    # language. A bundle whose requires_chi this chi doesn't meet, or whose list
    # doesn't parse (logged), is skipped; a record that doesn't read lists none.
    # @return [Array<Installed>]
    def for_installed
      taken = {}
      MemoryBundle::Provenance.each_installed do |bundle, record|
        next unless record.block_renderers?
        next if MemoryBundle::Manifest.requires_chi_failure(record.requires_chi, VERSION)

        renderers(bundle, record).each do |renderer|
          taken[renderer.lang] ||= Installed.new(lang: renderer.lang, bundle: bundle, files: renderer.load)
        end
      end
      taken.values
    end

    # The installed path of +file+, once a renderer .for_installed lists loads
    # it from +bundle+ (neither name is ever joined into a path before that:
    # they come from the URL) and it is as installed. This code runs in the
    # owner's browser, so it is checked as a plugin's load and a provider's
    # script are; a --dev install's links are not.
    # @return [String, nil] nil when no such renderer loads such a file
    # @raise [Invalid] the file is gone or changed
    def script_path(bundle, file)
      return nil unless for_installed.any? { |renderer| renderer.bundle == bundle && renderer.files.include?(file) }

      provenance = MemoryBundle::Provenance.new(name: bundle)
      path = File.join(provenance.scripts_dir, file)
      recorded = provenance.record&.scripts&.fetch(file, nil)
      return path if File.file?(path) && MemoryBundle::Provenance.sha_matches?(path, recorded)

      raise Invalid, "bundle #{bundle}'s scripts/#{file} differs from the installed one (reinstall the bundle)"
    end

    def renderers(bundle, record)
      parse_list(record.block_renderers)
    rescue ArgumentError => e # Invalid is one; so are a record's bytes that aren't UTF-8
      Log.warn(:web, "block_renderers_unreadable", bundle: bundle, msg: e.message)
      []
    end
    private_class_method :renderers
  end
end
