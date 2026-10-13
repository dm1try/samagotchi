# frozen_string_literal: true

module Samagotchi
  module LLM
    # A model a host lists. Unknown fields are nil.
    ModelInfo = Data.define(:id, :context_window, :supports_tools, :raw) do
      # true when the list says the model takes images (OpenRouter's
      # architecture.input_modalities, llama.cpp's "multimodal" capability),
      # false when it lists input modalities without "image", else nil.
      def image_input
        return nil unless raw.is_a?(Hash)

        modalities = raw.dig("architecture", "input_modalities")
        return modalities.include?("image") if modalities.is_a?(Array)
        return true if Array(raw["capabilities"]).include?("multimodal")

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

      def tools_support(raw)
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
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
