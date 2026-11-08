# frozen_string_literal: true

require_relative "../log"
require_relative "recording"
require_relative "runs"

module Samagotchi
  module SystemOne
    # What a turn stage needs to save its System 1 asks as runs: the
    # Engine's Runs and the session's model as the Engine names it now.
    # Engine#system_one_recorder builds one fresh at each stage call (never
    # kept: an outgoing ask after a before_turn hook's model switch names
    # the new model), on the caller's thread; the stage keeps it only for
    # that call. NONE is what a stage gets when the Engine couldn't build
    # one: no runs, every client as it was.
    #
    # +runs+ [Runs, nil] where the runs go (Runs#on? false: system_one.runs
    #   off); nil: NONE
    # +session_model+ [String, nil] Engine#effective_model_name at the call
    Recorder = Data.define(:runs, :session_model) do
      # +client+ (nil for none) saving its asks as +judgment+'s runs. Anything
      # going wrong here leaves the client as it was: a run is never worth a
      # judgment. A scratch session's asks aren't saved; a participant's
      # turn is never judged, so it never comes here.
      # @param mode [String, nil] the use's mode, for its runs (Recording.wrap)
      def wrap(client, judgment, session, mode: nil)
        return client if client.nil? || runs.nil? || session&.scratch

        context = Recording::Context.of(session, session_model: session && session_model)
        Recording.wrap(client, judgment: judgment, runs: runs, context: context, recorded_mode: mode)
      rescue StandardError => e
        Recorder.failed(e)
        client
      end

      # Whether runs are saved (an ask whose only use is its run is made
      # only then: ObjectivesAudit).
      def saving? = !runs.nil? && runs.on?

      # The one warn for a recording that can't be set up.
      def self.failed(error)
        Samagotchi::Log.warn(:system_one, "system_one_recording_failed", error: error.class.name, msg: error.message.to_s[0, 200])
      end
    end

    # No recording: the plain client, no runs.
    Recorder::NONE = Recorder.new(runs: nil, session_model: nil)
  end
end
