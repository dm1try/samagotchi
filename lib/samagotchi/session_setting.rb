# frozen_string_literal: true

require_relative "effective_model"

module Samagotchi
  # One per-session setting (the session's own value, before its model's):
  # what the UIs show as a chip and the commands set. +key+ is the Session
  # attribute and the chip's key everywhere (the session state, /stats, a
  # :command_ran, the web's session JSON); +changed_by+ the commands'
  # `changed` entries that move the chip; +snapshot_fallback+ how the web
  # treats a worker snapshot's value: :or (a nil value falls back to the
  # session file's) or :key (a key present stands, nil included: a worker
  # says nil on a native host, which ignores reasoning_history; an older
  # worker has no key). +chip+ the chip from an EffectiveModel and the
  # session's own value; nil for the toolkit, which resolves against the
  # worker's kits (Engine#toolkit_summary), not the model. +live+ the
  # chip as an Engine's public readers give it (a :command_ran's).
  SessionSetting = Data.define(:key, :changed_by, :snapshot_fallback, :chip, :live) do
    # The session's own value, nil without a session or one.
    def own(session) = session&.public_send(key)

    # Sets the session's own value (nil unsets it); the caller saves.
    def set(session, value) = session.public_send(:"#{key}=", value)

    # Whether a command that changed +changed+ moves this chip.
    def changed_by?(changed) = changed.intersect?(changed_by)

    # Whether the chip comes from the model (not the toolkit).
    def model? = !chip.nil?

    # The chip for +session+ on +model+ (EffectiveModel, nil when it
    # doesn't resolve: nil then).
    def chip_for(model, session) = model && chip.call(model, own(session))

    # The chip as +engine+ (a worker's) gives it now.
    def summary(engine) = live.call(engine)

    # The chip for a saved session no worker runs (Web::App, the session
    # lists): resolved from its file, config and the registry (no network);
    # nil when it can't be.
    def saved_summary(session, registry:)
      return saved_toolkit(session.toolkit) unless model?

      chip_for(EffectiveModel.of_session(session, registry: registry), session)
    rescue StandardError
      nil
    end

    # The web's chip: a worker's snapshot (string keys) per
    # +snapshot_fallback+, else the block's (the saved one).
    def snapshot_value(snapshot)
      name = key.to_s
      return snapshot[name] if snapshot_fallback == :key && snapshot&.key?(name)
      return snapshot[name] if snapshot_fallback == :or && snapshot && snapshot[name]

      yield
    end

    private

    # A toolkit as its file names it ({name:, label:}), nil on full:
    # without a worker nothing resolves it (a bundle's kits load there).
    def saved_toolkit(toolkit)
      toolkit && !toolkit.full? ? { name: toolkit.name, label: toolkit.label } : nil
    end
  end

  class SessionSetting
    LLM_CONTEXT = new(key: :llm_context, changed_by: %i[llm_context model], snapshot_fallback: :or,
                      chip: ->(model, own) { model.llm_context_explained(own&.resolve_args || {})&.summary(own) },
                      live: lambda(&:llm_context_summary))
    THINKING = new(key: :thinking, changed_by: %i[thinking model], snapshot_fallback: :or,
                   chip: ->(model, own) { model.thinking_explained(own: own)&.summary },
                   live: ->(engine) { engine.thinking_explained&.summary })
    # nil on a native host (its loop ignores the level).
    REASONING_HISTORY = new(key: :reasoning_history, changed_by: %i[reasoning_history model], snapshot_fallback: :key,
                            chip: ->(model, own) { model.reasoning_history_explained(own: own)&.summary },
                            live: ->(engine) { engine.reasoning_history_explained&.summary })
    TOOLKIT = new(key: :toolkit, changed_by: %i[toolkit], snapshot_fallback: :key, chip: nil, live: lambda(&:toolkit_summary))

    # In the order the session state, a :command_ran and the web name them.
    ALL = [LLM_CONTEXT, THINKING, REASONING_HISTORY, TOOLKIT].freeze
    # /stats's (no toolkit: its JSON never had one).
    STATS = [LLM_CONTEXT, THINKING, REASONING_HISTORY].freeze
  end
end
