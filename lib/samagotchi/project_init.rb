# frozen_string_literal: true

require "fileutils"
require_relative "guardrails/path_resolve"
require_relative "memory_paths"
require_relative "paths"

module Samagotchi
  # The shared decisions for `chi project init` and chi web's project picker.
  module ProjectInit
    Outcome = Data.define(:kind, :reason, :root, :top, :nested_in, :message)

    MARKER_TEXT = "# chi project marker: this folder is a chi project (docs/memory.md)\n"

    module_function

    def call(dir, home:)
      dir = File.expand_path(dir.to_s)
      found = MemoryPaths.lookup(dir, home: home)
      if found.git?
        message = "#{Paths.tilde(dir)} is in the git repository #{Paths.tilde(found.top)}: the repository already is " \
                  "the project, nothing written"
        return Outcome.new(kind: :git, reason: nil, root: found.root, top: found.top, nested_in: nil, message: message)
      end
      if MemoryPaths.above_home?(dir, home: home)
        message = "#{Paths.tilde(dir)} is $HOME, a folder above it or /: it can't be a chi project " \
                  "(every folder under it would be one); mark a folder inside it"
        return Outcome.new(kind: :refused, reason: :above_home, root: found.root, top: found.top, nested_in: nil,
                           message: message)
      end

      root = found.marker? ? found.root : nil
      if root == Guardrails::PathResolve.real(dir)
        return Outcome.new(kind: :already_marked, reason: nil, root: root, top: found.top, nested_in: nil,
                           message: "#{Paths.tilde(root)} is already a chi project")
      end

      write_marker(dir)
      root = File.realpath(dir)
      nested = if root == found.root
                 nil
               else
                 found.marker? ? found.root : nil
               end
      nested_text = nested ? ", its own project nested in #{Paths.tilde(nested)}" : ""
      message = "#{Paths.tilde(root)} is now a chi project#{nested_text} " \
                "(#{Paths.tilde(File.join(root, MemoryPaths::MARKER))})"
      Outcome.new(kind: :created, reason: nil, root: root, top: root, nested_in: nested, message: message)
    rescue SystemCallError => e
      marker = File.join(dir, MemoryPaths::MARKER)
      Outcome.new(kind: :refused, reason: :write_failed, root: nil, top: nil, nested_in: nil,
                  message: "couldn't write #{Paths.tilde(marker)}: #{e.message}")
    end

    def write_marker(dir)
      marker = File.join(dir, MemoryPaths::MARKER)
      FileUtils.mkdir_p(File.dirname(marker))
      File.write(marker, MARKER_TEXT)
    end
    private_class_method :write_marker
  end
end
