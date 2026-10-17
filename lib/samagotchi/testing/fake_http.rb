# frozen_string_literal: true

require "json"
require_relative "../plugin/http"

module Samagotchi
  module Testing
    # A request no stub answered (FakeHttp). Not an HttpError: a plugin's
    # `rescue Plugin::HttpError` doesn't swallow it, and the test fails at
    # teardown even when the plugin rescued it (FakeHttp#unmatched).
    class UnstubbedRequest < StandardError; end

    # ctx.http's wire in a bundle's test (docs/plugins.md, "Testing a
    # bundle"): requests are answered by stubs, never by the network.
    #
    #   bundle.http.stub(:post, "http://127.0.0.1:9000/classify", json: { label: "safe" })
    #   bundle.http.stub(:get, %r{/health\z}, status: 503, body: "down")
    #   bundle.http.stub(:post, "http://127.0.0.1:9000/classify") { |req| { json: { label: req.json["text"] } } }
    #   bundle.http.stub(:get, "http://127.0.0.1:9000/x", error: :refused)   # also :timeout
    #   bundle.http.requests    # what the plugin sent, in order
    #   bundle.http.unmatched   # what no stub answered
    #
    # A String matches the full URL exactly (query included), a Regexp is
    # matched against it; the method too. Later stubs win. A stub answers
    # every matching call: a sequence is a block that counts.
    class FakeHttp
      # One request the plugin made (headers as the plugin gave them).
      # `method` shadows Object#method on purpose: it is the plugin's word (request.method == "POST").
      Request = Data.define(:method, :url, :headers, :body) do # rubocop:disable Lint/DataDefineOverride
        # The body parsed as JSON.
        def json = JSON.parse(body.to_s)
      end

      Stub = Data.define(:verb, :matcher, :answer) do
        def match?(request)
          request.method == verb &&
            (matcher.is_a?(Regexp) ? matcher.match?(request.url) : matcher == request.url)
        end
      end
      private_constant :Stub

      # What error: names, and the words the real transport's message says.
      ERRORS = { refused: "connection refused", timeout: "timed out" }.freeze

      # The failure message for requests no stub answered (the adapters'
      # teardown check).
      # @param requests [Array<Request>] FakeHttp#unmatched, of every bundle
      def self.unmatched_message(requests)
        lines = requests.map { |request| "  #{request.method} #{request.url}" }
        "ctx.http made #{requests.size} request#{"s" unless requests.size == 1} no stub answered " \
          "(bundle.http.stub):\n#{lines.join("\n")}"
      end

      def initialize
        @mutex = Mutex.new
        @stubs = []
        @requests = []
        @unmatched = []
      end

      # Answer +method+ requests to +url+.
      # @param method [Symbol, String] :get, :post, :put, :patch, :delete, :head
      # @param url [String, Regexp]
      # @param status [Integer]
      # @param headers [Hash]
      # @param body [String, nil]
      # @param json [Object, nil] a JSON body (with its Content-Type)
      # @param error [Symbol, nil] :refused or :timeout: the request fails
      #   with the HttpError the real transport raises
      # @yield [Request] to decide per request: returns a Hash with the same
      #   keywords (status:, headers:, body:, json:, error:) or a
      #   Plugin::Http::Response
      # @return [self]
      def stub(method, url, status: 200, headers: {}, body: nil, json: nil, error: nil, &block)
        verb = method.to_s.upcase
        raise ArgumentError, "unknown HTTP method #{method.inspect}" unless Plugin::Http::METHODS.include?(verb)
        raise ArgumentError, "the URL is a String or a Regexp" unless url.is_a?(String) || url.is_a?(Regexp)
        raise ArgumentError, "unknown error #{error.inspect} (#{ERRORS.keys.join(", ")})" if error && !ERRORS.key?(error)

        answer = block || { status: status, headers: headers, body: body, json: json, error: error }
        @mutex.synchronize { @stubs << Stub.new(verb: verb, matcher: url, answer: answer) }
        self
      end

      # @return [Array<Request>] every request the plugin sent, in order
      def requests = @mutex.synchronize { @requests.dup }

      # @return [Array<Request>] the requests no stub answered (the test
      #   fails at teardown when there are any)
      def unmatched = @mutex.synchronize { @unmatched.dup }

      # The transport contract (Plugin::Http): the +cancel+ it is given is
      # the only cancel it checks.
      # @raise [UnstubbedRequest, Plugin::HttpError, Plugin::HttpCancelled]
      def call(method:, uri:, headers:, body:, timeout:, cancel:)
        raise Plugin::HttpCancelled, "#{method} #{where(uri)}: cancelled" if cancel&.cancelled?

        request = Request.new(method: method, url: uri.to_s, headers: headers.dup.freeze, body: body)
        stub = @mutex.synchronize do
          @requests << request
          @stubs.reverse_each.find { |candidate| candidate.match?(request) }.tap { |found| @unmatched << request unless found }
        end
        raise UnstubbedRequest, unstubbed_message(request) unless stub

        respond(request, uri, stub.answer.respond_to?(:call) ? stub.answer.call(request) : stub.answer)
      end

      private

      def respond(request, uri, answer)
        return answer if answer.is_a?(Plugin::Http::Response)
        raise ArgumentError, "a stub's block returns a Hash or a Plugin::Http::Response" unless answer.is_a?(Hash)

        if (error = answer[:error])
          raise Plugin::HttpError, "#{request.method} #{where(uri)}: #{ERRORS.fetch(error) { raise ArgumentError, "unknown error #{error.inspect}" }}"
        end

        headers = (answer[:headers] || {}).to_h { |name, value| [name.to_s.downcase, value.to_s] }
        body = answer[:body].to_s
        unless answer[:json].nil?
          body = JSON.generate(answer[:json])
          headers = { "content-type" => "application/json" }.merge(headers)
        end
        body = "" if request.method == "HEAD"
        Plugin::Http::Response.new(status: Integer(answer[:status] || 200), headers: headers.freeze, body: body.dup)
      end

      def where(uri) = "#{uri.host}:#{uri.port}"

      def unstubbed_message(request)
        stubs = @mutex.synchronize { @stubs.map { |stub| "#{stub.verb} #{stub.matcher.inspect}" } }
        "no stub for #{request.method} #{request.url}; stubbed: #{stubs.empty? ? "none" : stubs.join(", ")} " \
          "(bundle.http.stub(:#{request.method.downcase}, ...))"
      end
    end
  end
end
