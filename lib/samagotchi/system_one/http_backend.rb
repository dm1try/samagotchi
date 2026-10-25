# frozen_string_literal: true

require "json"
require "uri"
require_relative "../config"
require_relative "../llm/api_key"
require_relative "../llm/http"
require_relative "answer"
require_relative "question"
require_relative "errors"

module Samagotchi
  module SystemOne
    # The TypeSafe System One judgment API on a host from config.yml's
    # `hosts:`: POST <openai_base_url>/systemone (that base already ends in
    # /v1), one request per #ask, no retries — a judgment that doesn't
    # arrive in time is no judgment, and the ask goes to the user.
    #
    # Works for Splash (a local `api: openai` host serving /v1/systemone)
    # and for the hosted Jev API the same way; a host whose api isn't
    # openai is refused.
    class HttpBackend
      DEFAULT_TIMEOUT_MS = 2000

      # @param host_registry [HostRegistry] where the host is looked up
      # @param host [String] the hosts: entry name
      # @param model [String, nil] the judgment model; nil: the host's first
      #   model (hosts.<name>.models), and no judgment when it has none
      # @param timeout_ms [Integer] the whole request's limit, in ms
      # @param env [Hash] where the host's api_key_env: key is read
      def initialize(host_registry:, host:, model: nil, timeout_ms: DEFAULT_TIMEOUT_MS, env: ENV)
        @host_registry = host_registry
        @host = host.to_s.strip.downcase
        @model = model.nil? ? nil : model.to_s.strip
        @timeout_ms = timeout_ms.to_i
        @env = env
      end

      # @return [Hash{String => Answer}] one Answer per question, nil for a
      #   question the response answered badly
      # @raise [UnsupportedHost] the host is unknown, not an openai host, or
      #   names no model
      # @raise [BackendError] the request failed, the status isn't 200, or
      #   the body isn't a usable response
      def ask(state:, questions:, cancel_controller: nil)
        entry = @host_registry.find_entry(@host)
        raise UnsupportedHost, "host #{@host.inspect} is not in hosts:" unless entry
        unless entry.api&.to_sym == :openai
          raise UnsupportedHost, "host #{@host} has api: #{entry.api || "llama_cpp"}; System One speaks the OpenAI-compatible API"
        end

        model = @model || host_model(entry)
        raise UnsupportedHost, "host #{@host} names no model for System One" if model.nil? || model.empty?

        url = "#{entry.openai_base_url.to_s.chomp("/")}/systemone"
        questions = SystemOne.normalize_questions(questions)
        body = { model: model, state: state, questions: questions.to_h { |question| [question.id, question.to_wire] } }
        request = json_post(url, body)
        response = http(entry).fetch(URI(url), request, retries: false, check_status: false, cancel_controller: cancel_controller,
                                     log_fields: { purpose: "system_one", model: model })

        status = response.code.to_i
        unless status == 200
          raise BackendError, "#{@host}: #{status} #{error_detail(response.body)}"
        end

        answers = answers_of(response.body)
        questions.to_h { |question| [question.id, Answer.from_wire(question.id, answers[question.id])] }
      end

      private

      # The host's first model: whatever hosts.<name>.models holds, in the
      # shape the registry has it in (HostModel by id, or as written).
      def host_model(entry)
        models = entry.models
        return nil if models.nil? || models.empty?

        first = models.is_a?(Hash) ? models.values.first : models.first
        first.respond_to?(:id) ? first.id : first.to_s
      end

      # One attempt, closed on the timeout: a judgment is worth at most
      # timeout_ms, not a retry chain.
      def http(entry)
        seconds = @timeout_ms.positive? ? @timeout_ms / 1000.0 : DEFAULT_TIMEOUT_MS / 1000.0
        open_timeout = [seconds, Config.positive_seconds("server.open_timeout")].min
        LLM::HTTP.new(label: entry.name, open_timeout: open_timeout, read_timeout: seconds,
                      retry_policy: LLM::HTTP::RetryPolicy.none,
                      api_key: LLM::ApiKey.for(entry.api_key_env, host: entry.name, env: @env, scheme: entry.auth_scheme))
      end

      # The POST the adapters build: JSON body, Content-Type, and the host's
      # key on the header its auth: names (LLM::HTTP adds it).
      def json_post(url, body)
        Net::HTTP::Post.new(URI(url)).tap do |request|
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
        end
      end

      def answers_of(body)
        data = JSON.parse(body.to_s)
        raise BackendError, "the response is not JSON: #{body.to_s[0, 200]}" unless data.is_a?(Hash)

        answers = data["answers"]
        raise BackendError, "the response has no answers map" unless answers.is_a?(Hash)

        answers
      rescue JSON::ParserError => e
        raise BackendError, "the response is not JSON: #{e.message[0, 200]}"
      end

      # A 422's detail array, or the body's start, for the log line.
      def error_detail(body)
        data = JSON.parse(body.to_s)
        detail = data["detail"]
        text = if detail.is_a?(Array)
                 detail.map { |item| item.is_a?(Hash) ? item["msg"] || item.to_s : item.to_s }.join("; ")
               else
                 detail.to_s
               end
        text.empty? ? body.to_s[0, 200] : text[0, 200]
      rescue StandardError
        body.to_s[0, 200]
      end
    end
  end
end
