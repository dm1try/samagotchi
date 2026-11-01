# frozen_string_literal: true

require "rubygems/version"
require "time"

module Samagotchi
  module Web
    # AutoUpdate's record of the run it started, as UpdateCheck keeps it in
    # update_check.json (`auto`) so a chi web restart finds it. The file's
    # shape is this class's: #to_store writes it, .from_h reads it, and
    # nobody else sees its keys.
    #
    # +phase+: installed, workers, web (AutoUpdate::OPEN_PHASES), retrying,
    # done or failed. +restarted+ and +left+ count the stale workers (`workers` in
    # the file); +at+ is when the install ended, an ISO 8601 string.
    AutoUpdateRecord = Data.define(:version, :from, :at, :kept, :phase, :restarted, :left, :detail, :pushed) do
      def initialize(version:, phase:, from: nil, at: nil, kept: [], restarted: 0, left: 0, detail: nil, pushed: false)
        super
      end

      # @param hash [Object] the file's `auto`, as JSON.parse answered it
      # @return [AutoUpdateRecord, nil] nil when it isn't a run's record (no
      #   version or phase to go on: nothing a run could carry on from)
      def self.from_h(hash)
        return unless hash.is_a?(Hash)

        version = hash["version"]
        phase = hash["phase"]
        return unless version.is_a?(String) && Gem::Version.correct?(version) && phase.is_a?(String)

        workers = hash["workers"].is_a?(Hash) ? hash["workers"] : {}
        new(version: version, phase: phase, from: hash["from"], at: hash["at"],
            kept: Array(hash["kept"]).grep(String), restarted: workers["restarted"].to_i, left: workers["left"].to_i,
            detail: hash["detail"], pushed: hash["pushed"] == true)
      end

      # What goes in the file, for .from_h to read back.
      # @return [Hash{String => Object}]
      def to_store
        { "version" => version, "from" => from, "at" => at, "kept" => kept, "phase" => phase,
          "workers" => { "restarted" => restarted, "left" => left }, "detail" => detail,
          "pushed" => pushed ? true : nil }.compact
      end

      # Whether workers are left and the run, +window+ seconds from +at+, may
      # still try them. A stamp that can't be read ends the trying, so a run
      # can't go on for ever.
      # @param now [Time]
      def left_to_try?(now, window)
        return false unless left.positive?

        started = Time.iso8601(at.to_s)
        now - started < window
      rescue ArgumentError
        false
      end
    end
  end
end
