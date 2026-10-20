# frozen_string_literal: true

require_relative "effective_model"
require_relative "log"
require_relative "thinking"

module Samagotchi
  # What the thinking level a turn runs at leads to, said to the user: a
  # level its host can't do (an effort on a native host, or on a llama.cpp
  # chat template that takes none), off that the model didn't honour, and a
  # host refusing the thinking fields or the reasoning sent back. Each
  # notice once per session and host; the log lines each time.
  #
  # Turn thread only (the turn's settings and its stream handler): no lock.
  # What it needs from the Engine comes through lookups, called at use.
  class ThinkingNotices
    # @param session [#call] → Session, nil (its id: once per session)
    # @param profile [#call] → ModelProfile (a native host's)
    # @param notify  [#call] (text, level, source) → a notice
    def initialize(session:, profile:, notify:)
      @session = session
      @profile = profile
      @notify = notify
      @said = Set.new
      @turn = nil
      @generation_thought = nil
    end

    # [level, HostRegistry::ModelTarget] the turn runs at, nil before one.
    attr_reader :turn

    # The turn's thinking level on +target+ (its EffectiveModel's), what
    # the notices after it read; an effort a native host can't do is said
    # now.
    def turn_started(level, target)
      @turn = [level, target]
      announce_level(level, target)
    end

    # A generation starts (or a dropped one streams again from the start).
    def generation_started = @generation_thought = nil

    # Whether this generation's thinking lane said anything: nil while it
    # streamed none, false while only whitespace (Gemma 4's empty thought
    # with thinking off), true once a real thought came.
    def note_thought(thinking)
      return if thinking.empty?

      @generation_thought ||= thinking.match?(/\S/)
    end

    # A generation completed: off that the model didn't honour, an effort
    # its chat template ignores.
    def generation_completed(event)
      check_honoured(event)
      announce_effort_ignored
    end

    # The host refused the level's request fields (gpt-oss can't turn
    # thinking off) and the chat loop sent the request without them: said
    # once per session and host, standing in for the not-honoured notice.
    def thinking_refused(event)
      _level, target = @turn
      return unless target

      Log.warn(:model, "thinking_refused", level: event[:level], host: target.entry.name, model: event[:model],
                                           detail: event[:detail])
      @said << [session_id, target.entry.name, :not_honoured]
      notice_once(:refused, target, :warn,
                  "#{target.entry.name} refused thinking: #{event[:level]} for #{event[:model]} (#{event[:detail]}); " \
                  "sent without it, so thinking stays as the model has it")
    rescue StandardError => e
      failed(:thinking_refused, e)
    end

    # The host refused a sampling field (the empty-answer retry's
    # temperature on a model that takes none) and the chat loop asked again
    # without them, as it will for the model from now on: a log line.
    def sampling_refused(event)
      Log.info(:model, "sampling_refused", model: event[:model], detail: event[:detail])
    rescue StandardError => e
      failed(:sampling_refused, e)
    end

    # The host refused the model's reasoning sent back (reasoning_history)
    # and the chat loop asked the step again without it, as it will from
    # now on: logged, and said once per session and host.
    def reasoning_history_refused(event)
      _level, target = @turn
      return unless target

      Log.warn(:model, "reasoning_history_refused", level: event[:level], host: target.entry.name, model: event[:model],
                                                    detail: event[:detail])
      return unless @said.add?([session_id, target.entry.name, :reasoning_history_refused])

      @notify.call("#{target.entry.name} refused reasoning sent back (reasoning_history: #{event[:level]}) for " \
                   "#{event[:model]} (#{event[:detail]}); sent without it from now on", :warn, "reasoning history")
    rescue StandardError => e
      failed(:reasoning_history_refused, e)
    end

    private

    # An effort on a native host, which has no knob for it: said once per
    # session and host. A qwen36 whose server template opens a thought
    # (Thinking.opens_thought?, from the /props answer the profile probe
    # cached) thinks at every effort, the same.
    def announce_level(level, target)
      return if target.entry.chat?

      profile = @profile.call
      return if Thinking.native(level, profile).honoured

      text = if profile&.name == "qwen36" && Thinking.opens_thought?(target.client&.cached_server_props(model: target.bare_model))
               "#{level} isn't supported by native #{profile.name} on #{target.entry.name}; " \
                 "it thinks, with no effort control (low, medium and high think the same)"
             else
               "#{level} isn't supported by native #{profile.name} on #{target.entry.name}; " \
                 "thinking stays as the model has it"
             end
      notice_once(:unsupported, target, :info, text)
    rescue StandardError => e
      failed(:announce_level, e)
    end

    # An effort on a llama.cpp chat host whose chat template takes none
    # (its /props says so): said once per session and host, as for a native
    # host. Read from the /props answer the turn's window probe left in the
    # cache, so it asks the server nothing.
    def announce_effort_ignored
      level, target = @turn
      return unless target&.entry&.chat? && Thinking::EFFORTS.include?(level)

      props = target.client.cached_server_props(model: target.bare_model)
      return unless Thinking.effort_ignored?(level, props)

      notice_once(:unsupported, target, :info,
                  "#{level} isn't supported by #{target.bare_model}'s chat template on #{target.entry.name} " \
                  "(/props: supports_reasoning_effort false); thinking stays as the model has it")
    rescue StandardError => e
      failed(:effort_ignored, e)
    end

    # Thinking off, and the model thought anyway: logged each time, said
    # once per session and host. A thinking lane of whitespace alone is no
    # thought.
    def check_honoured(event)
      level, target = @turn
      chars = event[:thinking_chars].to_i
      return unless level == :off && chars.positive? && target
      return if @generation_thought == false

      Log.warn(:model, "thinking_not_honoured", level: level, host: target.entry.name, model: target.bare_model, chars: chars)
      notice_once(:not_honoured, target, :warn,
                  "off wasn't honoured by #{target.bare_model} on #{target.entry.name} " \
                  "(#{chars} chars of thinking); a sampling: override on the host or model may turn it off " \
                  "(see Thinking in docs/configuration.md)")
    rescue StandardError => e
      failed(:check_honoured, e)
    end

    def notice_once(kind, target, level, text)
      return unless @said.add?([session_id, target.entry.name, kind])

      @notify.call(text, level, "thinking")
    end

    def session_id = @session.call&.id

    # A notice that failed: none is said, the turn goes on; a log line
    # (once per process for the notice, model and error class).
    def failed(notice, error)
      EffectiveModel::Unresolved.fallback(:thinking_notice_failed, @turn&.last&.model || notice.to_s, error, nil)
    end
  end
end
