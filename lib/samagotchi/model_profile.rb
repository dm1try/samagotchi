# frozen_string_literal: true

module Samagotchi
  # Encapsulates all model-specific token formats and parsing behavior.
  # Each profile maps to a model family and is selected at runtime via
  # the SAMAGOTCHI_MODEL_PROFILE environment variable.
  #
  # Current profiles:
  #   gemma4  — default, original Gemma 4 format
  #   qwen36  — Qwen 3.6 chat template with function calling
  class ModelProfile
    attr_reader :name, :turn_start, :turn_end,
                :tool_call_open, :tool_call_close,
                :tool_response_open, :tool_response_close,
                :string_delim,
                :thought_open, :thought_close,
                :system_prefix, :user_prefix, :assistant_prefix,
                :model_prefix,
                :stop_sequences, :tool_decl_format

    def initialize(config)
      @name = config[:name]
      @turn_start = config[:turn_start]
      @turn_end = config[:turn_end]
      @tool_call_open = config[:tool_call_open]
      @tool_call_close = config[:tool_call_close]
      @tool_response_open = config[:tool_response_open]
      @tool_response_close = config[:tool_response_close]
      @string_delim = config[:string_delim]
      @thought_open = config[:thought_open]
      @thought_close = config[:thought_close]
      @system_prefix = config[:system_prefix]
      @user_prefix = config[:user_prefix]
      @assistant_prefix = config[:assistant_prefix]
      @model_prefix = config[:model_prefix]
      @stop_sequences = config[:stop_sequences]
      @tool_decl_format = config[:tool_decl_format]
    end

    def self.gemma4
      new(
        name: "gemma4",
        turn_start: "<|turn>",
        turn_end: "<end_of_turn>",
        tool_call_open: "<|tool_call>",
        tool_call_close: "<tool_call|>",
        tool_response_open: "<|tool_response>",
        tool_response_close: "<tool_response|>",
        string_delim: '<|"|>',
        thought_open: "<|think|>",
        thought_close: nil,
        system_prefix: "",
        user_prefix: "",
        assistant_prefix: "",
        model_prefix: "",
        stop_sequences: ["<end_of_turn>", "<|tool_response>"],
        tool_decl_format: :gemma4
      )
    end

    def self.qwen36
      new(
        name: "qwen36",
        turn_start: "",
        turn_end: "",
        tool_call_open: "<tool_call>",
        tool_call_close: "</tool_call>",
        tool_response_open: "<tool_response>",
        tool_response_close: "</tool_response>",
        string_delim: nil,
        thought_open: "<think>",
        thought_close: "</think>",
        system_prefix: "<|im_start|>system\n",
        user_prefix: "<|im_start|>user\n",
        assistant_prefix: "<|im_start|>assistant\n",
        model_prefix: "<|im_start|>assistant\n",
        stop_sequences: ["<|im_end|>"],
        tool_decl_format: :qwen36
      )
    end

    def self.default
      gemma4
    end

    def self.from_env
      name = ENV.fetch("SAMAGOTCHI_MODEL_PROFILE", "gemma4").downcase
      case name
      when "qwen", "qwen3", "qwen36", "qwen3.6"
        qwen36
      when "gemma", "gemma4", "gemma4o"
        gemma4
      else
        gemma4
      end
    end

    # ── Thought channel support ──────────────────────────────────────────

    def thought_channel_open
      nil
    end

    def uses_channel_thoughts?
      false
    end

    def uses_role_prefixes?
      !system_prefix.empty? && !user_prefix.empty?
    end
  end
end
