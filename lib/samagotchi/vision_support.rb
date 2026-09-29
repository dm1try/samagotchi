# frozen_string_literal: true

require_relative "config"

module Samagotchi
  # Whether a model can take images, asked before a turn with images is
  # sent: true (send), false (refuse, with a reason), or nil (unknown: send,
  # and map the provider's error if it says no).
  #
  # First match wins:
  #   1. config: models.<name>.vision, then hosts.<name>.vision
  #   2. a native host: llama.cpp only, and it must give a media marker, have
  #      vision in /props modalities, and use the profile's image template
  #      (the prompt can't carry an image any other way)
  #   3. a chat host: a local llama.cpp's /props modalities, then the host's
  #      model list (input_modalities / "multimodal")
  #   4. unknown
  module VisionSupport
    Answer = Data.define(:value, :reason) do
      def yes? = value == true
      def no? = value == false
    end

    # @param target [HostRegistry::ModelTarget]
    # @param profile [ModelProfile, nil] the model's prompt profile (native)
    # @param adapter [LLM::OpenAIChat, nil] the chat host's adapter
    # @param models [Hash, nil] ConfigFile.model_settings (specs)
    # @param names [Array<String>, nil] the model's lookup names, the typed
    #   alias first (Engine#model_lookup_names); default: the target's names
    # @return [Answer]
    def self.for(target, profile: nil, adapter: nil, models: nil, names: nil)
      entry = target.entry
      configured = configured(target, entry, models, names)
      return configured if configured&.no?

      if entry.chat?
        configured || chat(target, entry, adapter)
      else
        native(target, entry, profile, trust_config: configured&.yes?)
      end
    end

    # The media marker the running llama.cpp wants in the prompt, or nil.
    def self.media_marker(props)
      marker = props&.answered? && props.body.is_a?(Hash) ? props.body["media_marker"] : nil
      marker.is_a?(String) && !marker.empty? ? marker : nil
    end

    def self.configured(target, entry, models, names = nil)
      models ||= begin
        ConfigFile.model_settings
      rescue StandardError
        {}
      end
      key, value = ConfigFile.model_setting(names || [target.model, target.bare_model], :vision, models: models)
      return Answer.new(value: value, reason: value ? nil : "models: #{key} sets vision: false") if key
      return nil if entry.vision.nil?

      Answer.new(value: entry.vision, reason: entry.vision ? nil : "hosts.#{entry.name} sets vision: false")
    end

    def self.native(target, entry, profile, trust_config:)
      client = target.client
      transport = client.respond_to?(:transport) ? client.transport.name : :llama_cpp
      return no("#{transport} hosts take no images (only llama.cpp does)") unless transport == :llama_cpp

      props = client.respond_to?(:server_props) ? client.server_props(model: target.bare_model) : nil
      return no("can't reach /props for the media marker") unless props&.answered?

      body = props.body.is_a?(Hash) ? props.body : {}
      unless trust_config || body.dig("modalities", "vision") == true
        return no("the server has no vision model loaded (start llama.cpp with --mmproj)")
      end
      return no("the server gives no media marker (update llama.cpp)") unless media_marker(props)
      return no("profile #{profile&.name || "?"} has no image template yet") unless profile&.image_template

      open = profile.image_open_token
      unless open.empty? || body["chat_template"].to_s.include?(open)
        return no("the server's chat template doesn't use #{open} (profile #{profile.name})")
      end

      Answer.new(value: true, reason: nil)
    end

    def self.chat(target, entry, adapter)
      unless entry.remote?
        props = entry.client.respond_to?(:server_props) ? entry.client.server_props(model: target.bare_model) : nil
        if props&.answered? && props.body.is_a?(Hash) && props.body.key?("modalities")
          vision = props.body.dig("modalities", "vision") == true
          return vision ? Answer.new(value: true, reason: nil) : no("the server has no vision model loaded (start llama.cpp with --mmproj)")
        end
      end

      listed = adapter.respond_to?(:image_input) ? adapter.image_input(model: target.bare_model) : nil
      return Answer.new(value: true, reason: nil) if listed == true
      return no("host #{entry.name} lists #{target.bare_model} as text-only") if listed == false

      Answer.new(value: nil, reason: nil)
    rescue StandardError
      Answer.new(value: nil, reason: nil)
    end

    def self.no(reason) = Answer.new(value: false, reason: reason)

    private_class_method :configured, :native, :chat, :no
  end
end
