# frozen_string_literal: true

require "net/http"
require "openssl"
require "json"
require "uri"
require "ipaddr"
require_relative "../version"
require_relative "../llm/openai_chat"
require_relative "../llm/http"
require_relative "../llm/api_key"

module Samagotchi
  module Bootstrap
    # What `chi bootstrap TARGET` finds at a model server: llama.cpp's native
    # API (/props), an OpenAI-compatible one (/v1/models), one that wants an
    # API key, or nothing. One attempt per request, no retries: a refused
    # port answers at once instead of after chi's usual backoff.
    class Probe
      # The ports `chi bootstrap` with no target tries on localhost.
      LOCAL_PORTS = { 8080 => "llama.cpp", 11434 => "Ollama", 1234 => "LM Studio", 8000 => "vLLM" }.freeze
      DEFAULT_PORT = 8080
      # Connect and read seconds for /props and /v1/models: a remote https
      # handshake needs more than Client#server_props' 1 s / 2 s.
      TIMEOUT = 5
      # Seconds a local-port scan waits per port.
      SCAN_TIMEOUT = 1
      TEST_TIMEOUT = 60
      TEST_PROMPT = "Reply with the word ok."

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

      # kind: :native, :openai, :needs_key, :unreachable or :unknown.
      # props: the /props JSON (native); models: [LLM::ModelInfo];
      # status: the HTTP status that decided (:unknown, :needs_key);
      # reason: why it's unreachable.
      Result = Data.define(:kind, :candidate, :props, :models, :status, :reason) do
        def self.of(kind, candidate, props: nil, models: [], status: nil, reason: nil)
          new(kind: kind, candidate: candidate, props: props, models: models, status: status, reason: reason)
        end

        def native? = kind == :native
        def reached? = %i[native openai].include?(kind)
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
      # @return [Result]
      def classify_target(candidates, key_env: nil)
        result = nil
        candidates.each do |candidate|
          result = classify(candidate, key_env: key_env)
          break unless result.kind == :unreachable && result.reason.to_s.match?(/refused|SSL|TLS|certificate/i)
        end
        result
      end

      # @return [Result]
      def classify(candidate, key_env: nil)
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
          kind = [401, 403].include?(e.status) ? :needs_key : :unknown
          Result.of(kind, candidate, status: e.status, reason: e.status ? nil : e.message)
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
      # reasoning). @return [Float] seconds taken
      # @raise [RuntimeError] with what went wrong
      def test_turn(candidate, model, key_env: nil, read_timeout: TEST_TIMEOUT)
        uri = URI("#{candidate.base}/chat/completions")
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(model: model, messages: [{ role: "user", content: TEST_PROMPT }], max_tokens: 16,
                                     stream: false)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = send_request(uri, request, key_env, read_timeout: read_timeout)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        body = parse_object(response.body)
        unless response.code.to_i == 200 && body && body["choices"].is_a?(Array) && !body["choices"].empty?
          raise "HTTP #{response.code}: #{error_text(body, response.body)}"
        end

        elapsed
      rescue *network_errors => e
        raise "#{reason(e)} (#{candidate.label})"
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

      def get(uri, key_env)
        response = send_request(uri, Net::HTTP::Get.new(uri), key_env, read_timeout: @timeout)
        [response.code.to_i, response.body]
      end

      # One attempt through LLM::HTTP (User-Agent, the key's Bearer header),
      # any status returned as is. A key whose variable is not set sends no
      # header: the server's 401 then says one is needed.
      def send_request(uri, request, key_env, read_timeout:)
        key = key_env && !@env[key_env].to_s.strip.empty? ? LLM::ApiKey.for(key_env, host: uri.host, env: @env) : nil
        LLM::HTTP.new(label: uri.host, open_timeout: @timeout, read_timeout: read_timeout, api_key: key,
                      retry_policy: LLM::HTTP::RetryPolicy.none)
                 .fetch(uri, request, retries: false, check_status: false, log_fields: { purpose: "probe" })
      end

      def network_errors
        [*LLM::HTTP::NETWORK_ERRORS, OpenSSL::SSL::SSLError, Errno::EADDRNOTAVAIL, Errno::ENETDOWN, Errno::EPIPE]
      end

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
