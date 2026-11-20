# frozen_string_literal: true

require_relative "../memory_paths"
require_relative "record"
require_relative "sha"

module Samagotchi
  module InstalledBundles
    # One installed bundle's folder, <bundles dir>/<name>/, as the runtime
    # reads it: its record and where its plugin, scripts, rules and kept
    # manifest.yml are. Its only state is the name and the folder; writing
    # the record is MemoryBundle::Provenance's (a Dir too).
    class Dir
      attr_reader :name, :bundle_dir

      # @param dir [String] the bundles dir (InstalledBundles.dir by default)
      def initialize(name:, dir: MemoryPaths.bundles_dir)
        @name = name
        @bundle_dir = File.join(dir, name)
      end

      # Installed guardrail rule files (guardrails/*.yml).
      def guardrails_dir
        File.join(@bundle_dir, "guardrails")
      end

      # The installed plugin file's dir (plugin/<file>).
      def plugin_dir
        File.join(@bundle_dir, "plugin")
      end

      # The installed scripts' dir (scripts/<file>): what a context
      # provider's command finds as {bundle_dir}/scripts.
      def scripts_dir
        File.join(@bundle_dir, "scripts")
      end

      # The bundle's manifest.yml as installed (Record#kept_manifest_path).
      def kept_manifest_path
        File.join(@bundle_dir, "manifest.yml")
      end

      # The plugin file as installed, or nil when the bundle has none.
      # @param bundle [Record, nil] its record (read when not given)
      def plugin_path(bundle = record)
        file = bundle&.plugin&.file
        file ? File.join(plugin_dir, file) : nil
      end

      # Why the installed scripts/+file+ isn't as installed, nil when it is:
      # the record has no sha for it (+recorded+), it is gone, or it changed.
      # The one check a provider's command and a block renderer's load make
      # before chi runs or serves the file; a --dev install's links pass.
      def script_failure(file, recorded)
        path = File.join(scripts_dir, file)
        return "bundle #{@name}'s scripts/#{file} isn't among its installed scripts (reinstall the bundle)" if Sha.recorded(recorded).empty?
        return "bundle #{@name}'s scripts/#{file} is missing (reinstall the bundle)" unless File.file?(path)
        return nil if Sha.matches?(path, recorded)

        "bundle #{@name}'s scripts/#{file} differs from the installed one (reinstall the bundle)"
      end

      # The installed bundle's record, nil when it isn't installed.
      # @return [Record, nil]
      # @raise [JSON::ParserError] manifest.json doesn't parse
      def record
        Record.read(@name, File.join(@bundle_dir, "manifest.json"))
      end
    end
  end
end
