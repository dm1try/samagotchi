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

      # The marked project this folder sits in, if any: the folder itself (already marked) or its parent project.
      enclosing = found.marker? ? found.root : nil
      if enclosing == Guardrails::PathResolve.real(dir)
        return Outcome.new(kind: :already_marked, reason: nil, root: enclosing, top: found.top, nested_in: nil,
                           message: "#{Paths.tilde(enclosing)} is already a chi project")
      end

      write_marker(dir)
      root = File.realpath(dir)
      # No message: each surface words its own success (the CLI's report, the web's navigation).
      Outcome.new(kind: :created, reason: nil, root: root, top: root, nested_in: enclosing, message: nil)
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
