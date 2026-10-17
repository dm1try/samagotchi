# frozen_string_literal: true

require_relative "../log"

module Samagotchi
  module LLM
    # A model a host lists. Unknown fields are nil.
    ModelInfo = Data.define(:id, :context_window, :supports_tools, :raw) do
      # true when the list says the model takes images, false when it says
      # it doesn't, else nil: OpenRouter's architecture.input_modalities,
      # Anthropic's capabilities.image_input.supported, Splash's top-level
      # input_modalities or vision, Fireworks' supports_image_input,
      # llama.cpp's "multimodal" capability.
      def image_input
        return nil unless raw.is_a?(Hash)

        modalities = raw.dig("architecture", "input_modalities")
        return modalities.include?("image") if modalities.is_a?(Array)

        capabilities = raw["capabilities"]
        supported = capabilities.dig("image_input", "supported") if capabilities.is_a?(Hash)
        return supported if [true, false].include?(supported)
        return raw["input_modalities"].include?("image") if raw["input_modalities"].is_a?(Array)
        return raw["vision"] if [true, false].include?(raw["vision"])
        return raw["supports_image_input"] if [true, false].include?(raw["supports_image_input"])
        return true if capabilities.is_a?(Array) && capabilities.include?("multimodal")

        nil
      end
    end

    # A chat adapter's model list, kept per models_ttl: what #context_window
    # and #image_input read. The adapter defines #list_models (its wire's
    # GET) and calls #init_model_listing from its initializer.
    module ModelListing
      # The window (tokens) the host lists for +model+, or nil. The list is
      # read once per models_ttl; a failed listing answers nil.
      def context_window(model:)
        listed_model(model)&.context_window
      rescue StandardError
        nil
      end

      # Whether the host's list says +model+ takes images (ModelInfo#image_input),
      # or nil when it doesn't say or the listing fails.
      def image_input(model:)
        listed_model(model)&.image_input
      rescue StandardError
        nil
      end

      private

      def init_model_listing(models_ttl)
        @models_ttl = models_ttl
        @models_mutex = Mutex.new
        @models_failure_logged_at = nil
      end

      # +model+'s entry in the cached list: its exact id, else any case.
      def listed_model(model)
        cached_models.find { |m| m.id == model.to_s } || cached_models.find { |m| m.id.casecmp?(model.to_s) }
      end

      def model_entries(body)
        return [] unless body.is_a?(Hash)

        entries = body["data"].is_a?(Array) ? body["data"] : body["models"]
        Array(entries).select { |entry| entry.is_a?(Hash) }
      end

      def model_info(raw)
        id = (raw["id"] || raw["model"] || raw["name"]).to_s
        ModelInfo.new(id: id, context_window: window_of(raw), supports_tools: tools_support(raw), raw: raw)
      end

      # The running window when the list says: context_length, context_window,
      # max_model_len, or llama.cpp's meta.n_ctx (not n_ctx_train).
      def window_of(raw)
        [raw["context_length"], raw["context_window"], raw["max_model_len"], raw.dig("meta", "n_ctx")].each do |value|
          return value if value.is_a?(Integer) && value.positive?
        end
        nil
      end

      # Whether the list says the model takes tools: OpenRouter's
      # supported_parameters or llama.cpp's capabilities naming "tools"
      # (true, else nil), or Fireworks' supports_tools (true or false).
      def tools_support(raw)
        return raw["supports_tools"] if [true, false].include?(raw["supports_tools"])

        listed = raw["supported_parameters"] || raw["capabilities"]
        return nil unless listed.is_a?(Array)

        listed.include?("tools") || nil
      end

      def cached_models
        @models_mutex.synchronize do
          fresh = @models_at && (monotonic - @models_at) < @models_ttl
          return @models if fresh
        end
        models = list_models
        @models_mutex.synchronize do
          @models = models
          @models_at = monotonic
        end
        models
      rescue StandardError => e
        log_model_listing_failure(e)
        raise
      end

      def log_model_listing_failure(error)
        now = monotonic
        should_log = @models_mutex.synchronize do
          next false if @models_failure_logged_at && (now - @models_failure_logged_at) < @models_ttl

          @models_failure_logged_at = now
          true
        end
        return unless should_log

        host = @host_name.to_s.empty? ? @base_url : @host_name
        Log.warn(:model, "list_failed", host: host, error: error.class.name, msg: error.message.to_s[0, 500])
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
