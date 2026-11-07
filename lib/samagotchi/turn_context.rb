# frozen_string_literal: true

require_relative "turn_origin"
require_relative "steer"
require_relative "guardrails/context"
require_relative "llm/turn_settings"

module Samagotchi
  # What one turn's tool path reads of it, as one frozen value: built by
  # Engine#begin_turn before the turn is published (TurnState#begin!),
  # handed explicitly down the loops (ModelBackend#complete's context:,
  # KernelLoop#run, ChatLoop#complete), ToolResponse.run_batch,
  # ToolRunner#run, Guardrails::Gate#evaluate and KernelLoop#dispatch_tool_call
  # (its ToolContext). Lifetime: one turn. The source of truth for the
  # turn's id, session, origin and controller (Engine::Turn keeps only the
  # lifecycle state and reads these from it).
  #
  # +id+         the turn's id (:turn_started's turn_id)
  # +session+    the Session it runs in (live: its working-set pins are read at call time)
  # +origin+     its TurnOrigin (TurnOrigin::NONE for the owner's)
  # +author+     the participant's author ("p:<id>") when one wrote it, else nil
  # +participant_mode+ a participant's turn's mode (ParticipantMode: :review, :pair), nil for the owner's
  # +participant+ that participant's Participants::Entry (participants.json), nil for none
  # +controller+ the turn's CancellationController (live: its cancel state); a thread
  #   off the turn cancels through TurnState#controller, never through this
  # +cwd+        the session's working directory (nil: the process's, Dir.pwd)
  # +session_dir+ the session's folder (a cut tool output is saved there), nil for none
  # +state_dir+  the sessions' state dir
  # +git+        the turn's Guardrails::GitInfo (asked once per directory per turn)
  # +settings+   the turn's LLM::TurnSettings: nil until Engine#generate sets them
  # +model_key+, +fallback_model_key+ the memory overlay keys (memory_read, memory_write,
  #   rules' models:), +model_name+ the bare model name the gate's rules match: frozen at
  #   Engine#generate with the settings (a before_turn hook may switch the model)
  # +surface+    reserved for the turn's ToolSurface (arch P3.4): nil
  #
  # Only the turn thread replaces it (TurnState#replace_context), one frozen
  # value per write; other threads read the published one (Engine#turn_context,
  # Engine#last_turn_context).
  TurnContext = Data.define(:id, :session, :origin, :author, :participant_mode, :participant, :controller, :cwd,
                            :session_dir, :state_dir, :git, :settings, :model_key, :fallback_model_key, :model_name,
                            :surface) do
    # A context outside an Engine turn (a bare kernel, a spec, the bundle
    # test kit's Gate): no session, the owner's, no controller, a fresh
    # GitInfo, the settings given (LLM::TurnSettings.none by default).
    # @return [TurnContext]
    def self.none(**fields)
      new(id: nil, session: nil, origin: TurnOrigin::NONE, author: nil, participant_mode: nil, participant: nil,
          controller: nil, cwd: nil, session_dir: nil, state_dir: nil, git: Guardrails::GitInfo.new,
          settings: LLM::TurnSettings.none, model_key: nil, fallback_model_key: nil, model_name: nil, surface: nil,
          **fields)
    end

    # Whether a participant wrote the turn (Steer.participant_author?).
    def participant? = Steer.participant_author?(author)

    # Whether the turn's controller is cancelled (a Stop, a hook's stop_turn).
    def cancelled? = !!controller&.cancelled?

    # The turn's LLM context layers ([] without settings or a strategy): the
    # tools they add are the turn's to offer and dispatch.
    def llm_context_layers = settings&.llm_context&.active_layers || []

    # The session's working-set pins (Session#working_set_pins), read now.
    def working_set_pins = session.respond_to?(:working_set_pins) ? Array(session.working_set_pins) : []
  end
end
