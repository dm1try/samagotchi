# frozen_string_literal: true

require_relative "session_setting"
require_relative "token_usage"

module Samagotchi
  # The read model an Engine gives its UIs: #session_state_snapshot (cheap,
  # never probes and never raises: the Bridge's /state and reset frames call
  # it under the event lock) and #stats_snapshot (/stats, which may make one
  # short /props GET), with their helpers.
  #
  # What it needs from the Engine comes through lookups, read at call time;
  # the Engine forwards each method here. It takes no lock of its own: under
  # the Bridge's event lock a snapshot takes the question desk's monitor and
  # the metrics mutex, as before.
  class EngineSnapshots
    # State lookups, each [#call] → the Engine's object:
    # @param session, metrics, observer, question_desk, used_memories, muted,
    #   prompt_builder, participants, participants_watch, recap,
    #   last_context_status, model_settings
    # Engine calls (the Engine keeps these; specs stub some on it):
    # @param effective_model, effective_model_name, effective_model_ref,
    #   bare_model_name (ref), served_model (probe:), prompt_notes, preloaded,
    #   saved_context_status (context, **opts), context_window (model),
    #   profile_resolution, toolkit_summary, toolkit_explained
    def initialize(session:, metrics:, observer:, question_desk:, used_memories:, muted:, prompt_builder:,
                   participants:, participants_watch:, recap:, last_context_status:, model_settings:,
                   effective_model:, effective_model_name:, effective_model_ref:, bare_model_name:, served_model:,
                   prompt_notes:, preloaded:, saved_context_status:, context_window:, profile_resolution:,
                   toolkit_summary:, toolkit_explained:)
      @session = session
      @metrics = metrics
      @observer = observer
      @question_desk = question_desk
      @used_memories = used_memories
      @muted = muted
      @prompt_builder = prompt_builder
      @participants = participants
      @participants_watch = participants_watch
      @recap = recap
      @last_context_status = last_context_status
      @model_settings = model_settings
      @effective_model = effective_model
      @effective_model_name = effective_model_name
      @effective_model_ref = effective_model_ref
      @bare_model_name = bare_model_name
      @served_model = served_model
      @prompt_notes = prompt_notes
      @preloaded = preloaded
      @saved_context_status = saved_context_status
      @context_window = context_window
      @profile_resolution = profile_resolution
      @toolkit_summary = toolkit_summary
      @toolkit_explained = toolkit_explained
    end
    # rubocop:enable Metrics/ParameterLists

    # The metrics for /stats. Before the first generation reports them, the
    # context window, the served model and (on a native host) the prompt
    # profile come from the effective model's server, so this may make one
    # short /props GET; the cheap #session_state_snapshot never does.
    # price_host: the effective model's host, whose hosts.<name>.models
    # prices the cost estimate names. kit_prompt: the next turn's kit
    # prompt text ({kit:, tokens:}), only when its toolkit has one.
    # prompt_sections: the plugins' sections the built prompt holds, only
    # when it holds some.
    # settings: the session's own settings ({"recap.enabled" => false}),
    # only when it has some.
    # @return [Hash] @metrics.snapshot, filled in
    def stats_snapshot
      snapshot = metrics.snapshot
      # One resolve for the whole snapshot (its readers' rescues stay theirs);
      # a model that doesn't resolve raises here, as it always has.
      model = effective_model
      served, served_for = served_model_for(snapshot, model: model)
      snapshot = snapshot.merge(served_model: served, served_model_for: served_for,
                                served_expected_by: model.served_expected_by(served),
                                **setting_chips(SessionSetting::STATS, model),
                                prompt_notes: prompt_notes.map(&:to_h), prompt_files: prompt_builder.prompt_files,
                                price_host: model.host_name)
      kit_prompt = kit_prompt_stats
      snapshot = snapshot.merge(kit_prompt: kit_prompt) if kit_prompt
      # The plugins' prompt sections the built prompt holds ({bundle:, name:}).
      sections = prompt_builder.prompt_sections.map(&:to_stats)
      snapshot = snapshot.merge(prompt_sections: sections) unless sections.empty?
      # Each participant's spend under their name (participants.json's).
      if (spend = snapshot[:spend_by_author])
        named = spend.to_h { |author, row| [author, row.merge(name: participants.name_for(author, session: session))] }
        snapshot = snapshot.merge(spend_by_author: named)
      end
      # The session's own settings (chi --set), as --set names them.
      settings = session&.settings&.flat || {}
      snapshot = snapshot.merge(settings: settings) unless settings.empty?
      unless snapshot.dig(:context, :window_tokens)
        window = current_context_window(model)
        if window
          snapshot = snapshot.merge(context: snapshot[:context].merge(window_tokens: window.tokens,
                                                                      window_source: window.source.to_s))
        end
      end
      # The chat loop uses no prompt profile: drop one a native turn reported.
      return snapshot.except(:profile, :profile_source) if model.chat?

      unless snapshot[:profile]
        resolution = profile_resolution
        snapshot = snapshot.merge(profile: resolution.profile.name, profile_source: resolution.label)
      end
      snapshot
    end

    # Read-only snapshot of the engine's view of the current session plus the
    # live event sequence. Cheap primitive used by the bridge's reconnect-too-
    # old reset marker and the GET /session/:id/state read surface. Orthogonal
    # to the transport — safe to call before the first turn (nil session).
    #
    # @return [Hash] with keys:
    #   :status        [String, nil] current session status
    #   :message_count [Integer]   number of messages in the session
    #   :last_prompt   [String, nil] the last user prompt (empty string if none)
    #   :event_seq     [Integer]   @session_observer.event_count
    #   :metrics       [Hash]      @metrics.snapshot (per-session analytics)
    #   :pending_question [Hash, nil] the pending question (PendingQuestion#to_h)
    #   :used_memory_names [Array<String>] deduped memory names active this session
    #   :prompt_notes  [Array<Hash>] the model notes the prompt carried
    #     ({name:, scope:, chars:, digest:}; #prompt_notes)
    #   :parent_id     [String, nil] the session that delegated this one
    #   :model_name    [String]    the model turns run on now (after /model)
    #   :served_model, :served_model_for [String, nil] what a generation of
    #     that model reported serving, and the name asked (#served_model
    #     without the probe)
    #   :served_expected_by [String, nil] the host whose models: entry names
    #     that served model under served: (#served_expected_by)
    #   :recap_enabled [Boolean]   whether an idle recap is configured, with
    #     :recap_min_user_turns and :recap_inactivity_seconds (nil when not)
    #   :participants  [Array<Hash>] who is in the review now ({id:, name:,
    #     kind:}; ParticipantsWatch#active), [] for nobody
    def session_state_snapshot
      served_pair = served_model(probe: false)
      metrics = self.metrics.snapshot
      # One resolve for the model's fields; nil when it doesn't resolve (the
      # Bridge's /state and reset frames rely on this never raising): those
      # fields are nil then, as their own rescues always gave.
      model = model_settings.model_setting(nil) { |resolved| resolved }
      {
        status: session&.status,
        message_count: (session&.messages || []).size,
        last_prompt: session&.last_prompt,
        event_seq: observer&.event_count,
        metrics: metrics,
        pending_question: question_desk.pending&.to_h,
        used_memory_names: used_memories.names,
        preloaded_memory_names: preloaded_memory_names,
        muted_memory_names: muted.dup,
        prompt_notes: prompt_notes.map(&:to_h),
        parent_id: session&.parent_id,
        title: session&.title,
        model_name: effective_model_ref,
        served_model: served_pair[0],
        served_model_for: served_pair[1],
        served_expected_by: model&.served_expected_by(served_pair[0]),
        context_status: last_context_status&.dup || saved_context_status(metrics[:context], model: model),
        **setting_chips(SessionSetting::ALL, model),
        recap_enabled: !recap.nil?,
        recap_min_user_turns: recap&.min_user_turns,
        recap_inactivity_seconds: recap&.inactivity&.to_i,
        participants: participants_watch.active
      }
    end

    # See Engine#served_model. A report for another name (before a /model switch)
    # doesn't count. Without a model (EffectiveModel), no probe. A remote
    # chat host has no /props: nil until a turn. The name asked is never
    # resolved (HostRegistry#bare_name), so it holds on a broken resolve.
    def served_model_for(snapshot, model: nil)
      asked = bare_model_name(model ? model.name : effective_model_name)
      return [snapshot[:served_model], asked] if snapshot[:served_model] && snapshot[:served_model_for] == asked
      return [nil, nil] unless model

      model.served_from_props(asked)
    # Only bare_model_name and the snapshot lookup are left to fail here:
    # the probe's failure is EffectiveModel#served_from_props's.
    rescue StandardError
      [nil, nil]
    end

    # The next turn's kit prompt text for /stats: its kit and its estimated
    # tokens (chars / 4), nil when its toolkit has none.
    def kit_prompt_stats
      resolved = toolkit_explained.resolved
      return nil unless resolved.prompt

      { kit: resolved.name, tokens: (resolved.prompt.length / TokenUsage::CHARS_PER_TOKEN).ceil }
    end

    # +settings+' chips (SessionSetting), the model's from +model+ (nil
    # when it doesn't resolve): /stats, the session state, a :command_ran.
    def setting_chips(settings, model)
      settings.to_h { |setting| [setting.key, setting.model? ? setting.chip_for(model, session) : toolkit_summary] }
    end

    private

    def session = @session.call
    def metrics = @metrics.call
    def observer = @observer.call
    def question_desk = @question_desk.call
    def used_memories = @used_memories.call
    def muted = @muted.call
    def prompt_builder = @prompt_builder.call
    def participants = @participants.call
    def participants_watch = @participants_watch.call
    def recap = @recap.call
    def last_context_status = @last_context_status.call
    def model_settings = @model_settings.call
    def effective_model = @effective_model.call
    def effective_model_name = @effective_model_name.call
    def effective_model_ref = @effective_model_ref.call
    def bare_model_name(ref) = @bare_model_name.call(ref)
    def served_model(probe:) = @served_model.call(probe: probe)
    def prompt_notes = @prompt_notes.call
    def preloaded_memory_names = @preloaded.call
    def saved_context_status(context, **) = @saved_context_status.call(context, **)
    def current_context_window(model) = @context_window.call(model)
    def profile_resolution = @profile_resolution.call
    def toolkit_summary = @toolkit_summary.call
    def toolkit_explained = @toolkit_explained.call
  end
end
