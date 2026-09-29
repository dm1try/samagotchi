# frozen_string_literal: true

require "fileutils"
require_relative "desktop"
require_relative "memory_bundle/shipped_update"
require_relative "session"
require_relative "version"

module Samagotchi
  # One line at the first interactive start of a new chi version (REPL,
  # attached, chi web) when something chi update would update is behind:
  # "chi 0.3.1: 2 bundles and the desktop helper can be updated: chi update".
  # Noted once per version in $XDG_STATE_HOME/samagotchi/update_noted,
  # whether or not anything was behind. No network; nothing is changed (the
  # system bundle syncs itself at every start).
  module UpdateHint
    NOTED_FILE = "update_noted"

    module_function

    # Only a person starting chi at a terminal: not -p or --non-interactive
    # (a script), not a checkout (git pull updates it), never a worker
    # (workers don't start through bin/chi's launch).
    def wanted?(prompt:, non_interactive:, tty:, installed:)
      !!(tty && installed && !prompt && !non_interactive)
    end

    # @param helper [#stale?, nil] the desktop helper (nil off macOS)
    # @return [String, nil] the line shown, if any
    def show(io: $stderr, env: ENV, version: VERSION, helper: default_helper(env),
             shipped_dir: MemoryBundle::SourceNormalizer::SHIPPED_DIR)
      path = File.join(File.dirname(Session.default_state_dir(env: env)), NOTED_FILE)
      noted = File.exist?(path) ? File.readlines(path, chomp: true) : []
      return nil if noted.include?(version)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{version}\n", mode: "a")
      line = message(version, shipped_dir: shipped_dir, helper: helper)
      io.puts(line) if line
      line
    rescue StandardError
      nil
    end

    def message(version, shipped_dir:, helper:)
      bundles = MemoryBundle::ShippedUpdate.plan(shipped_dir: shipped_dir).count { |r| r.status == :would_update }
      parts = []
      parts << (bundles == 1 ? "1 bundle" : "#{bundles} bundles") if bundles.positive?
      parts << "the desktop helper" if helper&.stale?
      return nil if parts.empty?

      "chi #{version}: #{parts.join(" and ")} can be updated: chi update"
    end

    def default_helper(env)
      Desktop.supported? ? Desktop::MacOS.new(env: env) : nil
    end
  end
end
