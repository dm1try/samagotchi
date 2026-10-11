# frozen_string_literal: true

module Samagotchi
  # A session setting's level and where it came from (Thinking.explain,
  # ReasoningHistory.explain): +source+ is "session",
  # "SAMAGOTCHI_THINKING_LEVEL", "models: qwen", "hosts.work" and the like,
  # nil for the default; +own+ is the session's own level, nil without one.
  # What the commands, /model, /stats, the snapshots and the web read.
  # (LLMContextStrategy::Explained is a different shape: three values,
  # each with its own origin.)
  SettingExplained = Data.define(:level, :source, :own) do
    # "low (session)", "default" with no source.
    def label = source ? "#{level} (#{source})" : level.to_s

    # The plain form the snapshots, the worker's command_ran event and
    # the web read.
    # @return [Hash] symbol keys
    def summary = { level: level.to_s, source: source, own: own&.to_s }
  end
end
