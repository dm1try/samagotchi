# frozen_string_literal: true

module Samagotchi
  # A hook's or a plugin's question (event[:ask_user], ctx.ask_user) as one
  # value on its way to the question flow: built at the plugin-facing edge
  # (Hooks::Registry's event helper, Plugin::Context#ask_user), passed
  # through the hook runtime and the plugin host (Hooks::Runtime#ask_user,
  # Plugin::Host#ask_user), Engine#hook_ask_user and HookRoutes#ask_user to
  # QuestionDesk#ask_for_hook. The bundle test kit records it as asked
  # (Testing::Recorder#questions).
  #
  # question, options, header, allow_freeform: as the hook gave them
  # (QuestionDesk checks the options); hook: the asking hook's or plugin's
  # label; effects: what an option does for a parent agent's answer, by its
  # label (label => effect, as the hook gave it; nil for none). QuestionDesk
  # turns it into the pending question's per-option tags
  # (Guardrails::ParentPolicy.option_tags, PendingQuestion#effects).
  HookQuestion = Data.define(:question, :options, :header, :allow_freeform, :hook, :effects) do
    def initialize(effects: nil, **) = super
  end
end
