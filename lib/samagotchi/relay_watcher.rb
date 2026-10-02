# frozen_string_literal: true

require_relative "worker_sidecar"
require_relative "log"

module Samagotchi
  # A child's look at its parent while its question is relayed there: when
  # the parent's worker is gone, its relay card and RelayDesk went with it,
  # so the question's relay mark is cleared (reason parent_gone) and its
  # cards say "answer here" again. Outside the question desk: it clears a
  # mark, never cancels the question. Stops once the question is no longer
  # that relay's.
  module RelayWatcher
    INTERVAL = 2

    module_function

    # @param engine [Engine] the child's
    # @param parent_dir [String] the parent session's folder (its sidecar)
    # @param live [#call] whether the parent's worker is up
    # @return [Thread]
    def start(engine:, question_id:, relay_id:, parent_dir:, interval: INTERVAL,
              live: -> { WorkerSidecar.live(parent_dir, unlink: false) })
      Thread.new do
        loop do
          sleep(interval)
          break unless relayed?(engine.pending_question, question_id, relay_id)
          next if live.call

          Log.info(:bridge, "relay_parent_gone", id: question_id)
          engine.annotate_question(question_id, relayed_to: nil, reason: "parent_gone")
          break
        end
      rescue StandardError => e
        Log.warn(:bridge, "relay_watch_failed", error: e.class.name, message: e.message)
      end.tap { |thread| thread.report_on_exception = false }
    end

    def relayed?(pending, question_id, relay_id)
      relay = pending && pending[:relayed_to]
      return false unless relay.is_a?(Hash) && pending[:id].to_s == question_id.to_s

      (relay[:relay_id] || relay["relay_id"]).to_s == relay_id.to_s
    end
  end
end
