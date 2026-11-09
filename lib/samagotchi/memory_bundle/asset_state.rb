# frozen_string_literal: true

require "fileutils"
require_relative "trash"

module Samagotchi
  module MemoryBundle
    # One file of a bundle's own folder (a guardrail rule, the plugin, a
    # script) as a command finds it: derived from the file on disk, the sha
    # the record holds and the source file that would take its place, never
    # stored. FileActions' ASSET_* tables say what each command does in each
    # state; AssetInstaller, ShippedUpdate's plan, Uninstaller and Status read
    # it. Whether it is edited is Trash.edit?'s answer (what the trash keeps a
    # copy of), asked once in .of.
    #
    #   name          its path in its folder (r.yml, plugin.rb, s.sh)
    #   path          where it is installed
    #   kind_of_file  :rule, :plugin or :script
    #   state         :new        not there (or a broken link), the source has it
    #                 :unchanged  the source's bytes already (a dev link to them too)
    #                 :pristine   the recorded sha, the source has other bytes
    #                 :edited     neither the recorded sha (none recorded: unknown,
    #                             so edited) nor the source's bytes
    #                 :linked     a link (a dev install's) to other bytes than the
    #                             source's: it points at a source nothing here touches
    #                 :dropped_pristine, :dropped_edited  there, the source hasn't
    #                             it (with no source read, as uninstall and status
    #                             do, every file there is one of these)
    #                 :missing    recorded, not there, the source hasn't it
    #   recorded      the record's sha256 for it (nil: not in the record)
    #   incoming      the source file that replaces it (nil: none)
    AssetState = Data.define(:name, :path, :kind_of_file, :state, :recorded, :incoming) do
      # @param path [String] the installed file
      # @param recorded [String, nil] its recorded sha256
      # @param incoming [String, nil] the source file put in its place
      def self.of(path, kind_of_file:, recorded: nil, incoming: nil, name: File.basename(path))
        new(name: name, path: path, kind_of_file: kind_of_file, state: state_of(path, recorded, incoming),
            recorded: recorded, incoming: incoming)
      end

      # Every file of the folder +dir+ a command meets: each file in it (at
      # any depth, as Trash#copy_edits reads it; a linked dir isn't followed),
      # each incoming one and each recorded one, by name.
      # @param recorded [Hash, nil] name => recorded sha256
      # @param incoming [Hash] name => the source file
      # @return [Array<AssetState>]
      def self.in(dir, kind_of_file:, recorded: nil, incoming: {})
        recorded ||= {}
        on_disk = if File.symlink?(dir) || !File.directory?(dir) then []
                  else Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject { |file| File.directory?(File.join(dir, file)) }
                  end
        (on_disk | incoming.keys | recorded.keys).sort.map do |name|
          of(File.join(dir, name), kind_of_file: kind_of_file, recorded: recorded[name], incoming: incoming[name], name: name)
        end
      end

      def self.state_of(path, recorded, incoming)
        if incoming && File.file?(path) && FileUtils.identical?(incoming, path) then :unchanged
        elsif File.symlink?(path) && File.exist?(path) then :linked
        elsif !File.file?(path) then incoming ? :new : :missing
        elsif Trash.edit?(path, recorded: recorded, incoming: incoming) then incoming ? :edited : :dropped_edited
        else incoming ? :pristine : :dropped_pristine
        end
      end
      private_class_method :state_of

      # Trash.edit?'s rule (asked in .of): an edit a replace or a removal
      # would lose, so the trash keeps a copy first.
      def edited? = %i[edited dropped_edited].include?(state)

      # Where the trash keeps its copy, and the plan names it: guardrails/r.yml,
      # plugin/plugin.rb, scripts/s.sh.
      def label = "#{FOLDERS.fetch(kind_of_file)}/#{name}"

      # Each kind's folder in the bundle's own dir (and in the trash).
      FOLDERS = { rule: "guardrails", plugin: "plugin", script: "scripts" }.freeze
    end
  end
end
