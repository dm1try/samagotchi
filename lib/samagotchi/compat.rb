# frozen_string_literal: true

require "rubygems/version"
require_relative "version"

module Samagotchi
  # The compatibility decision for state and bridge data from a chi version.
  module Compat
    # Code kept only for another chi version's data or protocol, and the
    # release after which it goes. +remove_after+ nil: the owner hasn't
    # decided (kept until then). spec/compat_spec.rb fails once VERSION
    # passes a shim's +remove_after+, naming it. Each Ruby file names its
    # shim's id in a comment ("compat shim <id>").
    # @!attribute files [Array<String>] where the shim lives (from the repository root)
    Shim = Data.define(:id, :added_in, :remove_after, :files, :what)

    SHIMS = [
      Shim.new(id: :cards_v1_seed, added_in: "0.151.0", remove_after: nil,
               files: ["lib/samagotchi/bridge/card_store.rb"],
               what: "CardStore#seed_v1 reads a cards.json from before the turn log; its comment says a retention " \
                     "period after the release that wrote version 2 (0.151.0, 2026-11-05)"),
      Shim.new(id: :merge_inference, added_in: "0.157.0", remove_after: nil,
               files: ["lib/samagotchi/reply_wait/poll.rb", "lib/samagotchi/tools/delegate.rb"],
               what: "a wait infers a merged steer when the worker wrote no merge record (a 0.156 worker)"),
      Shim.new(id: :session_not_found_words, added_in: "0.156.0", remove_after: nil,
               files: ["lib/samagotchi/session_access/remote.rb"],
               what: "SESSION_NOT_FOUND also reads chi web 0.155.0's \"Session not found: X\" (its comment: compat N-1)"),
      Shim.new(id: :remote_refusal_details, added_in: "0.122.0", remove_after: nil,
               files: ["lib/samagotchi/session_access/remote.rb"],
               what: "context_missing? and no_provider? read an older chi web's 404 detail words, before their error codes"),
      Shim.new(id: :retired_class_file_hooks, added_in: "0.158.0", remove_after: nil,
               files: ["lib/samagotchi/extension_load.rb", "lib/samagotchi/memory_bundle/status.rb",
                       "lib/samagotchi/bundle_command/installed_check.rb"],
               what: "a 0.157 install record's class-file hooks: announced as not loading, shown and checked until " \
                     "an upgrade or uninstall clears them (installed state, not protocol)")
    ].freeze

    module_function

    # The shims +version+ has passed the remove_after of.
    # @return [Array<Shim>]
    def overdue_shims(version: VERSION, shims: SHIMS)
      current = Gem::Version.new(version)
      shims.select { |shim| shim.remove_after && current > Gem::Version.new(shim.remove_after) }
    end

    def verdict(worker_version:, version: VERSION, worker_protocol: nil, protocol: nil)
      return :refused if protocol && worker_protocol.to_i > protocol

      worker_version = worker_version.to_s
      version = version.to_s
      return :restart_suggested if worker_version.empty? || version.empty?
      return :restart_suggested unless Gem::Version.correct?(worker_version) && Gem::Version.correct?(version)

      worker = Gem::Version.new(worker_version)
      current = Gem::Version.new(version)
      return :restart_suggested if worker < previous_minor(current)

      :ok
    end

    def previous_minor(version)
      major, minor = version.segments.first(2)
      Gem::Version.new("#{major}.#{[(minor || 0) - 1, 0].max}.0")
    end
    private_class_method :previous_minor
  end
end
