# frozen_string_literal: true

require "rubygems/version"
require "date"
require_relative "version"

module Samagotchi
  # The compatibility decision for state and bridge data from a chi version.
  module Compat
    # Code kept only for another chi version's data or protocol, and the
    # release after which it goes. +remove_after+ nil: the owner hasn't
    # decided (kept until then). spec/compat_spec.rb fails once VERSION
    # passes a shim's +remove_after+, naming it. Each Ruby file names its
    # shim's id in a comment ("compat shim <id>").
    # A shim stays at least 14 days after the release that added it.
    # @!attribute files [Array<String>] where the shim lives (from the repository root)
    Shim = Data.define(:id, :added_in, :added_on, :remove_after, :files, :what)
    MIN_AGE_DAYS = 14

    SHIMS = [
      Shim.new(id: :cards_v1_seed, added_in: "0.151.0", added_on: "2026-11-05", remove_after: "0.170.0",
               files: ["lib/samagotchi/bridge/card_store.rb"],
               what: "CardStore#seed_v1 reads a cards.json from before the turn log; its comment says a retention " \
                     "period after the release that wrote version 2 (0.151.0, 2026-11-05)"),
      Shim.new(id: :approvals_bare_list, added_in: "0.169.0", added_on: "2026-11-12", remove_after: "0.172.0",
               files: ["lib/samagotchi/guardrails/approvals.rb"],
               what: "Approvals reads the bare list written by chi 0.166 and before, converting it on write"),
      Shim.new(id: :review_client_id, added_in: "0.172.0", added_on: "2026-11-14", remove_after: "0.173.0",
               files: ["lib/samagotchi/client_id.rb", "lib/samagotchi/session_manager/delivery.rb",
                       "lib/samagotchi/web/public/turn_events.js", "lib/samagotchi/web/public/viewer_self.js"],
               what: "A participant's client id from before participant:<id> (review:<id>: drawings, input files, an " \
                     "older chi web) reads as a participant's, and a worker without participant_client_id is sent it")
    ].freeze

    module_function

    # The shims +version+ has passed the remove_after of.
    # @return [Array<Shim>]
    def overdue_shims(version: VERSION, shims: SHIMS, today: Date.today)
      current = Gem::Version.new(version)
      shims.select do |shim|
        shim.remove_after && current > Gem::Version.new(shim.remove_after) &&
          Date.iso8601(shim.added_on) + MIN_AGE_DAYS <= today
      end
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
