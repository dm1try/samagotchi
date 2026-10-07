# frozen_string_literal: true

require_relative "../config"
require_relative "../model_match"

module Samagotchi
  module Guardrails
    # Whether the effective model is a small one, for rules with
    # `models: small` (guardrails.small_models). Nothing reports a model's
    # size (llama.cpp's /props has no parameter count), so `auto` reads it
    # from the bare model name: Qwen3.6-27B → 27, gemma-4-E4B-it → 4,
    # Ornith-1.5-35B-A3B → 3 (an MoE's active size counts), Mixtral-8x7B
    # → 56. A name without a size, and no model at all, is not small (fail
    # open: the rules for small models are extra asks, not the defaults).
    module ModelSize
      SETTING = "guardrails.small_models"
      # The largest auto-small size, in billions of parameters.
      MAX_SMALL = 32

      # A size starts at the name's start or after a separator, and ends at
      # a separator or the name's end (so 4bit and v4.1 aren't sizes).
      NUM = '(\d+(?:\.\d+)?)'
      BEFORE = '(?:\A|[-_/:\s])'
      AFTER = '(?=[-_:\s]|\z)'
      ACTIVE = /#{BEFORE}a#{NUM}b#{AFTER}/i
      EXPERTS = /#{BEFORE}(\d+)x#{NUM}b#{AFTER}/i
      PLAIN = /#{BEFORE}e?#{NUM}b#{AFTER}/i

      module_function

      # The size the bare model name gives, in billions; nil without one.
      # @return [Numeric, nil]
      def billions(name)
        name = name.to_s
        if (m = name.match(ACTIVE))
          number(m[1])
        elsif (m = name.match(EXPERTS))
          m[1].to_i * number(m[2])
        elsif (m = name.match(PLAIN))
          number(m[1])
        end
      end

      def number(text)
        text.include?(".") ? text.to_f : text.to_i
      end

      # @param name [String, nil] the bare model name (no host prefix)
      # @param key [String, nil] its model key (ModelOverlay.key_for)
      # @param setting [String, nil] guardrails.small_models: "auto", globs
      #   on the name or the key, "|"-separated ("auto" may be one of them),
      #   or "" (never)
      def small?(name, key, setting = self.setting)
        return false if name.nil? || name.to_s.strip.empty?

        ModelMatch.parse(setting.nil? ? "auto" : setting.to_s).any? do |entry|
          if entry.casecmp?("auto")
            (size = billions(name)) ? size <= MAX_SMALL : false
          else
            ModelMatch.glob?(entry, name: name, key: key)
          end
        end
      end

      # How /guardrails says it: "small (auto, 27B)", "not small (auto, no
      # size in the name)", "small (small_models: qwen*)".
      def describe(name, key, setting = self.setting)
        return "not small (no model name)" if name.nil? || name.to_s.strip.empty?

        verdict = small?(name, key, setting) ? "small" : "not small"
        return "#{verdict} (small_models: #{setting.empty? ? "[]" : setting})" unless setting.nil? || setting.strip.casecmp?("auto")

        size = billions(name)
        "#{verdict} (auto, #{size ? "#{size}B" : "no size in the name"})"
      end

      # The setting, live (config.yml is re-read on change); auto when it
      # can't be read.
      def setting
        Config.get(SETTING)
      rescue StandardError
        "auto"
      end
    end
  end
end
