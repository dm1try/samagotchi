# frozen_string_literal: true

require_relative "hooks/registry"
require_relative "hooks/loader"

module Samagotchi
  # Thin wrapper that exposes the Hooks::Registry and Hooks::Loader.
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
  #   :before_tool_call   — before a tool is dispatched (vetoable: set event[:blocked]=true with optional event[:block_reason])
  #   :after_tool_call    — after tool execution, before result injection
  module Hooks
    REGISTRY_CLASS = Registry
    LOADER_CLASS = Loader
  end
end
