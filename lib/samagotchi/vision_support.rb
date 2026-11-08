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

    # @param lookup [ModelLookup] the model's layers (EffectiveModel#lookup);
    #   its target is the one the probes ask
    # @param profile [ModelProfile, nil] the model's prompt profile (native)
    # @param adapter [LLM::OpenAIChat, nil] the chat host's adapter
    # @return [Answer]
    def self.for(lookup, profile: nil, adapter: nil)
      target = lookup.target
      entry = target.entry
      configured = configured(lookup)
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

    def self.configured(lookup)
      if (setting = lookup.model(:vision))
        return Answer.new(value: setting.value, reason: setting.value ? nil : "models: #{setting.key} sets vision: false")
      end

      vision = lookup.host(:vision)
      return nil if vision.nil?

      Answer.new(value: vision, reason: vision ? nil : "hosts.#{lookup.host_name} sets vision: false")
    end

    def self.native(target, _entry, profile, trust_config:)
      client = target.client
      props = client.server_props(model: target.bare_model)
      return no("can't reach /props for the media marker") unless props&.answered?

      body = props.body.is_a?(Hash) ? props.body : {}
      unless trust_config || body.dig("modalities", "vision") == true
        return no("the server has no vision model loaded (start llama.cpp with --mmproj)")
      end
      return no("the server gives no media marker (update llama.cpp)") unless media_marker(props)
      return no("profile #{profile&.name || "?"} has no image template yet") unless profile&.image_template

      check = profile.image_check_token
      unless check.empty? || body["chat_template"].to_s.include?(check)
        return no("the server's chat template doesn't use #{check} (profile #{profile.name})")
      end

      Answer.new(value: true, reason: nil)
    end

    def self.chat(target, entry, adapter)
      unless entry.remote?
        props = entry.client.server_props(model: target.bare_model)
        if props&.answered? && props.body.is_a?(Hash) && props.body.key?("modalities")
          vision = props.body.dig("modalities", "vision") == true
          return vision ? Answer.new(value: true, reason: nil) : no("the server has no vision model loaded (start llama.cpp with --mmproj)")
        end
      end

      listed = adapter&.image_input(model: target.bare_model)
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
