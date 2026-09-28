# frozen_string_literal: true

require "json"
require_relative "config"

module Samagotchi
  # The request parameters (temperature, penalties, …) a model's generations
  # go out with: hosts.<name>.sampling merged with models.<key>.sampling, the
  # model's keys winning per key (a host can set a penalty and a model move
  # only the temperature). Recap and side clients keep their own options.
  module SamplingSettings
    EMPTY = {}.freeze

    # @param target [HostRegistry::ModelTarget]
    # @param names [Array<String>, nil] the model as typed, alias-resolved,
    #   bare (the Engine's lookup names); default: the target's model and bare model
    # @param models [Hash, nil] ConfigFile.model_settings (specs)
    # @return [Hash] frozen, symbol keys; may be empty
    def self.for(target, names: nil, models: nil)
      resolve(target, names, models).first
    end

    # "temperature=0.6 presence_penalty=1.5 (hosts.work, models: qwen)" for
    # /model, or nil when nothing is configured.
    def self.summary(target, names: nil, models: nil)
      params, sources = resolve(target, names, models)
      return nil if params.empty?

      pairs = params.map { |key, value| "#{key}=#{value.nil? ? "(not sent)" : value.inspect}" }
      "#{pairs.join(" ")} (#{sources.join(", ")})"
    end

    # Request fields as the http log line shows them:
    # "temperature=0.6 presence_penalty=1.5", nil for none.
    def self.log_text(fields)
      return nil if fields.nil? || fields.empty?

      fields.map { |key, value| "#{key}=#{value.is_a?(String) ? value : JSON.generate(value)}" }.join(" ")
    end

    def self.resolve(target, names, models)
      models ||= begin
        ConfigFile.model_settings
      rescue StandardError
        {}
      end
      names ||= [target.model, target.bare_model]
      host = target.entry.sampling || EMPTY
      key, model = ConfigFile.model_setting(names, :sampling, models: models)
      sources = []
      sources << "hosts.#{target.entry.name}" unless host.empty?
      sources << "models: #{key}" if key
      [host.merge(model || EMPTY).freeze, sources]
    end

    private_class_method :resolve
  end
end
