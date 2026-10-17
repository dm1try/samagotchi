# frozen_string_literal: true

require "net/http"
require "openssl"
require "json"
require "uri"
require "ipaddr"
require_relative "../version"
require_relative "../llm/openai_chat"
require_relative "../llm/anthropic_messages"
require_relative "../llm/dialect"
require_relative "../llm/http"
require_relative "../llm/api_key"
require_relative "../host_keys"
require_relative "../redacted_inspect"

module Samagotchi
  module Bootstrap
    # What `chi bootstrap TARGET` finds at a model server: llama.cpp's native
    # API (/props), an OpenAI-compatible one (/v1/models), Anthropic's
    # Messages API (its /v1/models, asked only after the OpenAI list was
    # refused with 400/401/403: the Anthropic list reads an OpenAI-shaped
    # one too), one that wants an API key, or nothing. One attempt per
    # request, no retries: a refused port answers at once instead of after
    # chi's usual backoff.
    class Probe
      include RedactedInspect

      # The ports `chi bootstrap` with no target tries on localhost.
      LOCAL_PORTS = { 8080 => "llama.cpp", 11_434 => "Ollama", 1234 => "LM Studio", 8000 => "vLLM" }.freeze
      DEFAULT_PORT = 8080
      # Connect and read seconds for /props and /v1/models: a remote https
      # handshake needs more than Client#server_props' 1 s / 2 s.
      TIMEOUT = 5
      # Seconds a local-port scan waits per port.
      SCAN_TIMEOUT = 1
      TEST_TIMEOUT = 60
      TEST_PROMPT = "Reply with the word ok."
      # The OpenAI list's statuses after which the Anthropic list is asked:
      # Anthropic answers a Bearer request 400 (no anthropic-version) or
      # 401/403. Not 404/405: a typed URL path sends the two lists to
      # different paths, so a 404 there says nothing about Anthropic.
      ANTHROPIC_AFTER = [400, 401, 403].freeze
      AUTH_STATUSES = [401, 403].freeze
      FIREWORKS_HOST = "fireworks.ai"
      FIREWORKS_MODEL_PREFIX = "accounts/fireworks/"

      # One place a server may be: root is scheme://host:port (llama.cpp's
      # /props), base the OpenAI API base (<root>/v1, or a URL's own path).
      # url is true when the user gave a URL with a path, which the config
      # then keeps as written.
      Candidate = Data.define(:root, :base, :url) do
        def uri = URI(root)
        def host = uri.host
        def port = uri.port
        def scheme = uri.scheme
        def label = "#{host}:#{port}"
      end

      # kind: :native, :openai, :anthropic, :needs_key, :unreachable or
      # :unknown. props: the /props JSON (native); models: [LLM::ModelInfo];
      # status: the HTTP status that decided (:unknown, :needs_key);
      # reason: why it's unreachable; dialect: an :anthropic result's
      # LLM::Dialect name when not the standard one ("fireworks"), else nil;
      # auth: :bearer when an :anthropic list took the key only as Bearer
      # (a Symbol, LLM::ApiKey::SCHEMES), else nil.
      Result = Data.define(:kind, :candidate, :props, :models, :status, :reason, :dialect, :auth) do
        def self.of(kind, candidate, props: nil, models: [], status: nil, reason: nil, dialect: nil, auth: nil)
          new(kind: kind, candidate: candidate, props: props, models: models, status: status, reason: reason,
              dialect: dialect, auth: auth)
        end

        def native? = kind == :native
        def anthropic? = kind == :anthropic
        def reached? = %i[native openai anthropic].include?(kind)
      end

      # A failed test turn: the message, and the HTTP status and request path
      # when the server answered (BootstrapCommand's --api anthropic hint).
      class TestFailed < RuntimeError
        attr_reader :status, :path

        def initialize(message = nil, status: nil, path: nil)
          @status = status
          @path = path
          super(message)
        end
      end

      # The target the user typed, as the candidates to try in order.
      #   host, host:port, an IP  → http://host:port (port 8080 when none)
      #   a domain without a scheme → https first, then http
      #   a URL → as given; a path is the OpenAI base
      # Raises ArgumentError for something that isn't a host or URL.
      def self.candidates(target)
        text = target.to_s.strip
        raise ArgumentError, "no target" if text.empty?

        if text.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
          uri = parse_uri(text)
          raise ArgumentError, "not an http(s) URL: #{text}" unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?

          root = root_url(uri.scheme, uri.host, uri.port)
          path = uri.path.to_s.chomp("/")
          return [Candidate.new(root: root, base: path.empty? ? "#{root}/v1" : "#{root}#{path}", url: !path.empty?)]
        end

        uri = parse_uri("http://#{text}")
        raise ArgumentError, "not a host or URL: #{text}" unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?

        path = uri.path.to_s.chomp("/")
        port = text.match?(%r{:\d+(/|\z)}) ? uri.port : nil
        schemes = domain?(uri.host) ? { "https" => 443, "http" => 80 } : { "http" => DEFAULT_PORT }
        schemes.map do |scheme, default_port|
          root = root_url(scheme, uri.host, port || default_port)
          Candidate.new(root: root, base: path.empty? ? "#{root}/v1" : "#{root}#{path}", url: !path.empty?)
        end
      end

      # scheme://host:port, without the port when it is the scheme's own
      # (https://openrouter.ai, not https://openrouter.ai:443): it is written
      # into config.yml as typed.
      def self.root_url(scheme, host, port)
        default = { "http" => 80, "https" => 443 }[scheme]
        port == default ? "#{scheme}://#{host}" : "#{scheme}://#{host}:#{port}"
      end

      # A name with a dot that isn't an IP or localhost: reached over https
      # on 443 first, like a browser would.
      def self.domain?(host)
        return false if host.nil? || host.casecmp?("localhost") || ip?(host)

        host.include?(".")
      end

      def self.ip?(host)
        IPAddr.new(host.to_s.delete_prefix("[").delete_suffix("]"))
        true
      rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
        false
      end

      # The Messages API root: the OpenAI base without its trailing /v1
      # (HostEntry#api_base_url's rule), e.g. https://api.anthropic.com.
      def self.api_root(candidate) = candidate.base.chomp("/").delete_suffix("/v1")

      # Fireworks by its host (fireworks.ai or a subdomain), or by a model id
      # in its accounts/fireworks/ namespace.
      def self.fireworks?(candidate, models = [])
        fireworks_host?(candidate.host) || models.any? { |m| m.id.to_s.start_with?(FIREWORKS_MODEL_PREFIX) }
      end

      def self.fireworks_host?(host)
        name = host.to_s.downcase
        name == FIREWORKS_HOST || name.end_with?(".#{FIREWORKS_HOST}")
      end

      def self.parse_uri(text)
        URI.parse(text)
      rescue URI::InvalidURIError
        nil
      end
      private_class_method :parse_uri

      # @param env [Hash] where the API key variable is read
      # @param timeout [Numeric] connect and read seconds per request
      def initialize(env: ENV, timeout: TIMEOUT)
        @env = env
        @timeout = timeout
      end

      # Probe the target's candidates in order; the next one is tried only
      # when this one refused the connection or failed its TLS handshake
      # (https → http), not on a timeout.
      # @param key_env [String, nil] the API key's environment variable
      # @param api [Symbol, nil] :openai or :anthropic to skip the detection
      #   (--api); nil detects
      # @param dialect [String, nil] the Messages dialect (--dialect); nil
      #   detects Fireworks
      # @return [Result]
      def classify_target(candidates, key_env: nil, api: nil, dialect: nil)
        result = nil
        candidates.each do |candidate|
          result = classify(candidate, key_env: key_env, api: api, dialect: dialect)
          break unless result.kind == :unreachable && result.reason.to_s.match?(/refused|SSL|TLS|certificate/i)
        end
        result
      end

      # /props (llama.cpp), then the OpenAI list, then (only after the OpenAI
      # list's 400/401/403) the Anthropic one. api: :anthropic asks only the
      # Anthropic list; api: :openai never asks it.
      # @return [Result]
      def classify(candidate, key_env: nil, api: nil, dialect: nil)
        return classify_anthropic(candidate, key_env, dialect, nil) if api&.to_sym == :anthropic

        props = begin
          status, body = get(URI("#{candidate.root}/props"), key_env)
          status == 200 ? parse_object(body) : nil
        rescue *network_errors => e
          return Result.of(:unreachable, candidate, reason: reason(e))
        end
        return Result.of(:native, candidate, props: props, models: native_models(candidate, props, key_env)) if native_props?(props)

        begin
          Result.of(:openai, candidate, models: list_models(candidate.base, key_env))
        rescue LLM::ProviderError => e
          return failure(candidate, e) if api || !ANTHROPIC_AFTER.include?(e.status)

          classify_anthropic(candidate, key_env, dialect, e)
        rescue *network_errors => e
          Result.of(:unreachable, candidate, reason: reason(e))
        end
      end

      # The ports in LOCAL_PORTS that answer as a model server, probed in
      # parallel. @return [Array<Result>] the reached ones, in LOCAL_PORTS order
      def scan_local(ports: LOCAL_PORTS.keys)
        scanner = self.class.new(env: @env, timeout: SCAN_TIMEOUT)
        ports.map do |port|
          Thread.new { scanner.classify(Candidate.new(root: "http://localhost:#{port}", base: "http://localhost:#{port}/v1", url: false)) }
        end.map(&:value).select(&:reached?)
      end

      # /props for one model (a llama.cpp router loads it on demand), or nil
      # when the server doesn't answer it.
      def model_props(candidate, model, key_env: nil)
        status, body = get(URI("#{candidate.root}/props?#{URI.encode_www_form(model: model)}"), key_env)
        status == 200 ? parse_object(body) : nil
      rescue StandardError
        nil
      end

      # One short chat request: does the server generate for +model+? Any 200
      # with a choice counts (a thinking model may spend its 16 tokens
      # reasoning). api: :anthropic posts {root}/v1/messages instead, and any
      # 200 with a content array counts (stop_reason max_tokens too).
      # @param auth [Symbol, nil] the key's header on :anthropic (nil: the
      #   dialect's)
      # @return [Float] seconds taken
      # @raise [TestFailed] with what went wrong
      def test_turn(candidate, model, key_env: nil, api: :openai, dialect: nil, auth: nil, read_timeout: TEST_TIMEOUT)
        anthropic = api&.to_sym == :anthropic
        uri, request, scheme = anthropic ? messages_request(candidate, model, dialect, auth) : chat_request(candidate, model)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = send_request(uri, request, key_env, read_timeout: read_timeout, scheme: scheme)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        body = parse_object(response.body)
        unless response.code.to_i == 200 && answered?(body, anthropic ? "content" : "choices")
          raise TestFailed.new("HTTP #{response.code}: #{error_text(body, response.body)}", status: response.code.to_i,
                                                                                          path: uri.path)
        end

        elapsed
      rescue *network_errors => e
        raise TestFailed, "#{reason(e)} (#{candidate.label})"
      end

      private

      def native_props?(props)
        props.is_a?(Hash) && (props.key?("chat_template") || props.key?("build_info"))
      end

      # llama.cpp serves /v1/models too; a server that doesn't gets its
      # model_alias.
      def native_models(candidate, props, key_env)
        models = begin
          list_models(candidate.base, key_env)
        rescue StandardError
          []
        end
        return models unless models.empty?

        name = props["model_alias"].to_s.strip
        name.empty? ? [] : [LLM::ModelInfo.new(id: name, context_window: nil, supports_tools: nil, raw: {})]
      end

      def list_models(base, key_env)
        LLM::OpenAIChat.new(base_url: base, host_name: URI(base).host, api_key_env: key_env, retries: false,
                            timeout: @timeout, env: @env).list_models
      end

      # The Anthropic list at the candidate's API root, the key in the
      # dialect's header (Bearer on Fireworks, detected by its host before
      # listing); a 401/403 with the standard dialect's x-api-key is asked
      # once more with Bearer (a gateway that wants it). Ids in Fireworks'
      # namespace make the result's dialect fireworks. +openai_error+ is the
      # OpenAI list's refusal, the result again when the Anthropic list fails
      # other than 401/403 (nil when --api anthropic skipped it).
      def classify_anthropic(candidate, key_env, dialect, openai_error)
        forced = dialect
        dialect ||= LLM::Dialect::FIREWORKS.name if self.class.fireworks_host?(candidate.host)
        auth = nil
        models = begin
          anthropic_models(candidate, key_env, dialect: dialect, auth: nil)
        rescue LLM::ProviderError => e
          raise unless AUTH_STATUSES.include?(e.status) && key_env && LLM::Dialect.for(dialect).auth != :bearer

          auth = :bearer
          anthropic_models(candidate, key_env, dialect: dialect, auth: auth)
        end
        dialect ||= LLM::Dialect::FIREWORKS.name if forced.nil? && self.class.fireworks?(candidate, models)
        dialect = nil if dialect == LLM::Dialect::STANDARD.name
        Result.of(:anthropic, candidate, models: models, dialect: dialect, auth: auth)
      rescue LLM::ProviderError => e
        return Result.of(:needs_key, candidate, status: e.status) if AUTH_STATUSES.include?(e.status)

        failure(candidate, openai_error || e)
      rescue *network_errors => e
        Result.of(:unreachable, candidate, reason: reason(e))
      end

      def anthropic_models(candidate, key_env, dialect:, auth:)
        LLM::AnthropicMessages.new(base_url: self.class.api_root(candidate), host_name: candidate.host, api_key_env: key_env,
                                   auth: auth, dialect: dialect, stream: false, retries: false, timeout: @timeout,
                                   env: @env).list_models
      end

      # A list's refusal as a Result: :needs_key on 401/403, else :unknown.
      def failure(candidate, error)
        kind = AUTH_STATUSES.include?(error.status) ? :needs_key : :unknown
        Result.of(kind, candidate, status: error.status, reason: error.status ? nil : error.message)
      end

      def chat_request(candidate, model)
        uri = URI("#{candidate.base}/chat/completions")
        request = json_post(uri, model: model, messages: [{ role: "user", content: TEST_PROMPT }], max_tokens: 16, stream: false)
        [uri, request, :bearer]
      end

      # No stream and no thinking field: the model's own defaults.
      def messages_request(candidate, model, dialect, auth)
        uri = URI("#{self.class.api_root(candidate)}/v1/messages")
        request = json_post(uri, model: model, max_tokens: 16, messages: [{ role: "user", content: TEST_PROMPT }])
        request["anthropic-version"] = LLM::AnthropicMessages::API_VERSION
        [uri, request, auth || LLM::Dialect.for(dialect).auth]
      end

      def json_post(uri, body)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
        request
      end

      def answered?(body, key) = body.is_a?(Hash) && body[key].is_a?(Array) && !body[key].empty?

      def get(uri, key_env)
        response = send_request(uri, Net::HTTP::Get.new(uri), key_env, read_timeout: @timeout)
        [response.code.to_i, response.body]
      end

      # One attempt through LLM::HTTP (User-Agent, the key in +scheme+'s
      # header), any status returned as is. A key neither its variable nor the
      # Keychain holds sends no header: the server's 401 then says one is needed.
      def send_request(uri, request, key_env, read_timeout:, scheme: :bearer)
        key = key_env && HostKeys.fetch(key_env, env: @env) ? LLM::ApiKey.for(key_env, host: uri.host, env: @env, scheme: scheme) : nil
        LLM::HTTP.new(label: uri.host, open_timeout: @timeout, read_timeout: read_timeout, api_key: key,
                      retry_policy: LLM::HTTP::RetryPolicy.none)
                 .fetch(uri, request, retries: false, check_status: false, log_fields: { purpose: "probe" })
      end

      def network_errors = LLM::HTTP::NETWORK_ERRORS

      def reason(error)
        case error
        when Errno::ECONNREFUSED then "connection refused"
        when Net::OpenTimeout then "no answer in #{@timeout} s"
        when Timeout::Error, IO::TimeoutError then "timed out"
        when SocketError then "unknown host"
        when OpenSSL::SSL::SSLError then "TLS: #{error.message}"
        else error.message
        end
      end

      def parse_object(text)
        parsed = JSON.parse(text.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def error_text(body, raw)
        message = body.is_a?(Hash) && (body.dig("error", "message") || body["error"] || body["message"])
        (message || raw.to_s)[0, 200].to_s.strip
      end
    end
  end
end
