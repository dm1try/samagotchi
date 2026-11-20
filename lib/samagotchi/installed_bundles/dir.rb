# frozen_string_literal: true

require_relative "../memory_paths"
require_relative "record"
require_relative "sha"
require_relative "standing"

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

      # Why chi won't load or run this installed file, nil when it is as
      # installed: the one "is this file as installed" check of what chi loads
      # (the plugin), runs (a provider's scripts), serves (a renderer's
      # scripts) or reads (the rules). A --dev install's links pass. Hashes
      # only the file asked about. Each kind keeps its own order of checks and
      # its words (the plan's D6 makes them one):
      #   :plugin      missing, then no sha recorded, then changed
      #   :scripts     no sha recorded, then missing, then changed
      #   :guardrails  missing, then changed (no sha recorded reads as changed)
      # @param kind [Symbol] :plugin, :scripts or :guardrails
      # @param file [String, nil] its name in that folder (nil: a plugin the
      #   record names no file of, which is missing)
      # @param recorded [String, nil] the record's sha256 for it
      # @return [Refusal, nil]
      def file_refusal(kind, file, recorded)
        case kind
        when :plugin then plugin_refusal(file, recorded)
        when :scripts then script_refusal(file, recorded)
        when :guardrails then rules_refusal(file, recorded)
        else raise ArgumentError, "no installed files of kind #{kind.inspect}"
        end
      end

      # The installed bundle's record, nil when it isn't installed.
      # @return [Record, nil]
      # @raise [JSON::ParserError] manifest.json doesn't parse
      def record
        Record.read(@name, File.join(@bundle_dir, "manifest.json"))
      end

      private

      def plugin_refusal(file, recorded)
        path = file && File.join(plugin_dir, file)
        return Refusal.new(kind: :file_missing, text: "the file is missing") unless path && File.file?(path)
        return nil if Sha.unchecked?(recorded)

        expected = Sha.recorded(recorded)
        return Refusal.new(kind: :file_unrecorded, text: "no sha256 recorded for it (reinstall the bundle)") if expected.empty?

        actual = Sha.of_file(path)
        return nil if actual == expected

        Refusal.new(kind: :file_changed, actual: actual, expected: expected,
                    text: "its sha256 #{actual[0, 12]}… differs from the installed #{expected[0, 12]}… " \
                          "(edited after install? reinstall the bundle)")
      end

      def script_refusal(file, recorded)
        path = File.join(scripts_dir, file)
        expected = Sha.recorded(recorded)
        if expected.empty?
          return Refusal.new(kind: :file_unrecorded,
                             text: "bundle #{@name}'s scripts/#{file} isn't among its installed scripts (reinstall the bundle)")
        end
        return Refusal.new(kind: :file_missing, text: "bundle #{@name}'s scripts/#{file} is missing (reinstall the bundle)") unless File.file?(path)
        return nil if Sha.unchecked?(recorded)

        actual = Sha.of_file(path)
        return nil if actual == expected

        Refusal.new(kind: :file_changed, actual: actual, expected: expected,
                    text: "bundle #{@name}'s scripts/#{file} differs from the installed one (reinstall the bundle)")
      end

      def rules_refusal(file, recorded)
        path = File.join(guardrails_dir, file)
        return Refusal.new(kind: :file_missing, text: "the file is missing") unless File.file?(path)
        return nil if Sha.unchecked?(recorded)

        actual = Sha.of_file(path)
        return nil if actual == Sha.recorded(recorded)

        Refusal.new(kind: :file_changed, actual: actual, expected: Sha.recorded(recorded),
                    text: "its sha256 differs from the installed one (edited after install? reinstall the bundle)")
      end
    end
  end
end
