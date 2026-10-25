# frozen_string_literal: true

require_relative "../config"
require_relative "../log"
require_relative "answer"
require_relative "errors"
require_relative "http_backend"
require_relative "question"

module Samagotchi
  module SystemOne
    # The one way anything asks System 1 a question: #ask answers a set of
    # questions about a state, or says nothing. A backend that is unreachable,
    # slow, refusing or nonsensical is a nil — no judgment, one log line — and
    # the caller asks the user as it would have anyway.
    #
    #   client = SystemOne::Client.from_config(host_registry: registry)
    #   client&.ask(state: "git push origin main", questions: {"allow" => question})
    class Client
      MODES = %w[off audit on].freeze
      DEFAULT_TIMEOUT_MS = 2000

      attr_reader :mode, :host, :model, :backend

      def initialize(backend:, mode: "off", host: nil, model: nil)
        @backend = backend
        @mode = mode.to_s.strip.downcase
        @host = host
        @model = model
      end

      # nil when judgment is off (the default) or no host is named, so the
      # caller needs no other check. The settings are read every call: a
      # config.yml change takes effect on the next ask.
      # @param model [String, nil] a model for this call only (chi guardrails
      #   replay --model), else the configured one
      def self.from_config(host_registry:, env: ENV, model: nil)
        mode = Config.get("guardrails.system_one.mode").to_s.strip.downcase
        return nil unless MODES.include?(mode) && mode != "off"

        host = Config.get("guardrails.system_one.host").to_s.strip
        return nil if host.empty?

        model = (model.nil? ? Config.get("guardrails.system_one.model") : model).to_s.strip
        timeout_ms = Config.get("guardrails.system_one.timeout_ms").to_i
        timeout_ms = DEFAULT_TIMEOUT_MS unless timeout_ms.positive?

        new(backend: HttpBackend.new(host_registry: host_registry, host: host, model: model.empty? ? nil : model,
                                     timeout_ms: timeout_ms, env: env),
            mode: mode, host: host, model: model.empty? ? nil : model)
      end

      # @param state [String, Hash, Array] what the question is about, as the
      #   contract takes it
      # @param questions [Hash{String => Question|Hash}] the questions, by id
      # @return [Hash{String => Answer}, nil] one Answer per question, or nil
      #   when there is no judgment at all
      def ask(state:, questions:, cancel_controller: nil)
        questions = SystemOne.normalize_questions(questions)
        return nil if questions.empty?

        answers = begin
          @backend.ask(state: state, questions: questions, cancel_controller: cancel_controller)
        rescue StandardError => e
          return no_judgment("#{e.class}: #{e.message}", error: e.class.name)
        end

        unless answers.is_a?(Hash)
          return no_judgment("the backend returned #{answers.inspect}")
        end

        answers = questions.to_h { |question| [question.id, answers[question.id]] }
        missing = questions.reject { |question| answers[question.id].is_a?(Answer) }
        return no_judgment("no answer for #{missing.map(&:id).join(", ")}") unless missing.empty?

        answers
      end

      private

      # One warn, one nil: the ask goes to the user.
      def no_judgment(reason, **fields)
        # Qualified: inside SystemOne, the bare Log is now SystemOne::Log.
        Samagotchi::Log.warn(:guardrails, "system_one_failed", echo: "[samagotchi:guardrails] system one: #{reason}", host: @host, **fields)
        nil
      end
    end
  end
end
