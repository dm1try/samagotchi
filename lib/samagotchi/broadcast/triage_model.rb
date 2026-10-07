# frozen_string_literal: true

require_relative "../config"
require_relative "../idle_target"
require_relative "../model_profile"

module Samagotchi
  # Loaded on first use, as the CLI commands do: host_registry pulls in the
  # LLM layer.
  autoload :HostRegistry, File.expand_path("../host_registry", __dir__)

  module Broadcast
    # Which model a broadcast's triage asks: broadcast.triage_model /
    # triage_host_ref / triage_base_url; with none of them set, the recap's
    # (recap.*); with none of those, default.model. Settings that can't be
    # resolved are a problem, not a fallback to the next ones: triage then
    # delivers unchecked and says why.
    module TriageModel
      # @!attribute target [IdleTarget, nil] nil when +problem+ says why
      # @!attribute setting [String] where it came from: "broadcast.triage_model",
      #   "recap.model" or "default.model" (the prefix of the keys read)
      Choice = Data.define(:target, :setting, :problem)

      SETTINGS = [%w[broadcast.triage_model broadcast.triage_host_ref broadcast.triage_base_url],
                  %w[recap.model recap.host_ref recap.base_url]].freeze

      module_function

      # @param get [#call] a Config key → its value
      # @return [Choice]
      def resolve(host_registry: nil, get: ->(key) { Config.get(key) })
        registry = host_registry || HostRegistry.new
        SETTINGS.each do |model, host_ref, base_url|
          target = IdleTarget.resolve(model: get.call(model), host_ref: get.call(host_ref), base_url: get.call(base_url),
                                      host_registry: registry)
          return Choice.new(target: target, setting: model, problem: nil) if target
        rescue IdleTarget::Unresolved => e
          return Choice.new(target: nil, setting: model, problem: problem(e, model, host_ref))
        end
        model = ModelProfile.required_model_name(get.call("default.model"))
        Choice.new(target: IdleTarget.of_model(registry, model), setting: "default.model", problem: nil)
      rescue StandardError => e
        Choice.new(target: nil, setting: "default.model", problem: e.message.to_s.lines.first.to_s.strip[0, 200])
      end

      def problem(error, model_key, host_ref_key)
        case error.reason
        when :host_ref_unknown then "#{host_ref_key} '#{error.host_ref}' is not in hosts:"
        when :model_host_mismatch then "#{model_key} '#{error.model}' names host '#{error.named}', not #{host_ref_key} '#{error.host_ref}'"
        else "#{model_key} is missing (a host or base_url alone names no model)"
        end
      end
      private_class_method :problem
    end
  end
end
