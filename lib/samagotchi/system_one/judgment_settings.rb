# frozen_string_literal: true

require_relative "../config"

module Samagotchi
  module SystemOne
    # A bundle's judgment's settings: its entry in config.yml's
    # system_one.judgments, read at each ask, as Client's are. Off until the
    # user sets a mode. +host+ and +model+ are nil for the shared
    # system_one.host and .model.
    #
    # Core's judgments have none, whatever the file says (Config::
    # RESERVED_JUDGMENTS): Record and Similar are model-blind, so a model
    # swapped for approvals alone would inherit a clean record and could
    # auto-allow.
    JudgmentSettings = Data.define(:mode, :host, :model) do
      def initialize(mode: "off", host: nil, model: nil) = super

      def off? = mode == "off"

      # The model for Client.from_config: its own; else, on a host of its own,
      # that host's first ("": the shared model belongs to the shared host);
      # else nil, the shared one.
      def client_model = model || (host ? "" : nil)

      # @param name [String] the judgment's full name
      # @param section [Hash, nil] config.yml's system_one section
      # @return [JudgmentSettings]
      def self.of(name, section: ConfigFile.section("system_one"))
        return new if Config::RESERVED_JUDGMENTS.include?(name.to_s.split(".").first)

        entry = entries(section)[name.to_s]
        return new unless entry.is_a?(Hash)

        new(mode: Config.judgment_mode(entry["mode"]) || "off", host: text(entry["host"]), model: text(entry["model"]))
      rescue StandardError
        new
      end

      # The names system_one.judgments sets.
      # @return [Array<String>]
      def self.names(section: ConfigFile.section("system_one"))
        entries(section).keys
      rescue StandardError
        []
      end

      def self.entries(section)
        judgments = section["judgments"] if section.is_a?(Hash)
        judgments.is_a?(Hash) ? judgments.transform_keys(&:to_s) : {}
      end
      private_class_method :entries

      def self.text(value)
        word = value.to_s.strip
        word.empty? ? nil : word
      end
      private_class_method :text
    end
  end
end
