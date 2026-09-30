# frozen_string_literal: true

require_relative "hooks/registry"
require_relative "hooks/loader"
require_relative "hooks/bundle_loader"
require_relative "hooks/stream_watch"

module Samagotchi
  # Thin wrapper that exposes the Hooks::Registry, Hooks::Loader and
  # Hooks::BundleLoader (bundle-owned hook plugins).
  #
  # The Engine holds an instance of Hooks::Registry and provides:
  # - #register_hook(name, &block) — register a turn-scoped hook
  # - #unregister_hook(name)        — remove a hook
  # - #clear_hooks                  — auto-cleaned after each run_turn
  #
  # Hook event vocabulary:
  #   :before_turn        — before the turn starts
  #   :after_turn         — after the turn completes (success or cancel)
  #   :before_generation  — before calling the LLM API
  #   :after_generation   — after LLM returns, before tool parse
  #   :generation_progress — while a response streams, batched (StreamWatch);
  #                         event[:stop_generation] cuts it, the turn goes on
  #   :before_tool_call   — before a tool is dispatched: vote with event[:guardrail].deny!/ask!
  #                         (or the older event[:blocked]=true + event[:block_reason]); the
  #                         event also has context: and targets: (docs/guardrails.md)
  #   :after_tool_call    — after tool execution, before result injection
  module Hooks
    REGISTRY_CLASS = Registry
    LOADER_CLASS = Loader
    BUNDLE_LOADER_CLASS = BundleLoader
  end
end
