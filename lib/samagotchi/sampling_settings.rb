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

    # @param lookup [ModelLookup] the model's layers (EffectiveModel#lookup)
    # @return [Hash] frozen, symbol keys; may be empty
    def self.for(lookup)
      resolve(lookup).first
    end

    # "temperature=0.6 presence_penalty=1.5 (hosts.work, models: qwen)" for
    # /model, or nil when nothing is configured.
    def self.summary(lookup)
      params, sources = resolve(lookup)
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

    def self.resolve(lookup)
      host = lookup.host(:sampling) || EMPTY
      model = lookup.model(:sampling)
      sources = []
      sources << "hosts.#{lookup.host_name}" unless host.empty?
      sources << "models: #{model.key}" if model
      [host.merge(model&.value || EMPTY).freeze, sources]
    end

    private_class_method :resolve
  end
end
