# frozen_string_literal: true

# The mcp bundle's second plugin part (manifest.yml plugin: parts:, loaded
# after client.rb, whose Client::Error and Client::Unavailable its error
# classes subclass, and before plugin.rb): the HTTP JSON-RPC client.
require "digest"
require "json"
require "uri"
require "samagotchi/cancellation_controller"

class Plugin
  # A JSON-RPC client for one remote MCP server over HTTP (the Streamable
  # HTTP transport), the same surface as Client: each message is one
  # ctx.http.stream POST, answered in JSON or as an SSE stream. The
  # handshake speaks the current revision (2026-07-28, "modern":
  # server/discover, _meta on every request, no session) first, and the
  # older one ("legacy": initialize, an Mcp-Session-Id when the server
  # gives one) on any answer it doesn't recognise. Its messages are bare:
  # the callers name the server. Never a header value or the token in a
  # message, a log field or #inspect.
  class HttpClient
    MODERN = "2026-07-28"
    LEGACY = "2025-11-25"
    ACCEPT = "application/json, text/event-stream"
    # How long #close's DELETE of a legacy session may take.
    CLOSE_TIMEOUT = 2
    # The most of a JSON error answer read for its JSON-RPC error.
    ERROR_BODY_BYTES = 64 * 1024

    # A JSON-RPC error answer: +code+ and +data+ for the handshake.
    class RpcError < Client::Error
      attr_reader :code, :data

      def initialize(error)
        @code = error["code"]
        @data = error["data"]
        super("#{error["message"] || "error"} (#{error["code"]})")
      end
    end

    # No token, or the server refused one (401, 403): the handshake never
    # tries legacy for it. +status+ is the answer's (nil: refused before
    # sending, an unset variable).
    class Refused < Client::Unavailable
      attr_reader :status
      # 16 hex of the SHA-256 of the token a 401 refused (nil: none sent),
      # never the token: whether the kept one is newer (Plugin#newer_sign_in?).
      attr_accessor :sent_digest

      def initialize(message = nil, status: nil)
        @status = status
        super(message)
      end
    end

    # A 404 for a legacy session id: the session expired.
    class Expired < Client::Unavailable; end

    # One call's time, +seconds+ from its start, for every message it sends
    # (connect, headers, body; a re-handshake's too).
    Budget = Data.define(:seconds, :deadline) do
      def self.for(seconds) = new(seconds, Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds)

      def left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # The same budget, +seconds+ later: time it doesn't count (a sign-in
      # renewing, OAuth::Token: its own deadline).
      def later(seconds) = with(deadline: deadline + seconds)
    end

    State = Data.define(:era, :session_id, :protocol)

    # HttpClient's token: for a server with no token (nil) or a static one
    # (bearer_token_env: the block looks it up at each request and raises
    # Refused when its variable is unset): there is nothing to refresh.
    class StaticToken
      def initialize(&lookup)
        @lookup = lookup
      end

      # @return [String, nil] the bearer token
      def call = @lookup.call

      # @return [Boolean] whether there is a new token to try (never)
      def refresh_token!(_sent = nil) = false

      def inspect = "#<#{self.class.name.split("::").last}>"
    end

    # @param url [String] http(s)
    # @param headers [Hash{String=>String}] sent as given
    # @param token [#call, #refresh_token!] #call → the bearer token, or nil
    #   for none (raises Client::Unavailable when its variable is unset);
    #   #refresh_token! → whether a new one is there to try (StaticToken)
    # @param http [#stream, #request] ctx.http
    # @param log [#call] (event, fields)
    def initialize(url, headers:, token:, http:, log:)
      @url = url
      @headers = headers
      @token = token
      @http = http
      @log = log
      @next_id = 0
      @mutex = Mutex.new
      @renewal = Mutex.new
      @state = State.new(nil, nil, nil)
    end

    # scheme://host, and the port when it isn't the scheme's: never the
    # path or query (a URL may carry a key).
    def label = self.class.origin(@url)

    def self.origin(url)
      uri = URI(url.to_s)
      port = uri.port == uri.default_port ? "" : ":#{uri.port}"
      "#{uri.scheme}://#{uri.host}#{port}"
    rescue URI::Error
      "(not a URL)"
    end

    def era = @mutex.synchronize { @state.era }

    def inspect = "#<HttpClient #{label} era=#{era || "none"}>"

    def pretty_print(printer) = printer.text(inspect)

    def dead = nil

    def pid = nil

    # The era, once: server/discover, then initialize on anything it
    # doesn't recognise (not a wire error, a timeout or a refusal).
    # @param cancelled [Samagotchi::CancellationController, nil] ctx.http's
    #   cancel: (Plugin#stop_of; not stdio's poll), for #request too
    # @return [Hash] what Plugin#info_of reads ("instructions")
    def handshake(timeout:, cancelled:)
      # Nothing else runs on a client before its first handshake returns.
      publish(State.new(:discover, nil, nil))
      discover_error = nil
      begin
        result = post("server/discover", {}, Budget.for(timeout), cancelled, state: state)
        offered = Array(result["supportedVersions"])
        return result.tap { publish(State.new(:modern, nil, nil)) } if offered.include?(MODERN)
      rescue Refused, Client::Timeout, Client::Cancelled, Client::Dead
        raise
      rescue RpcError => e
        offered = Array(e.data.is_a?(Hash) ? e.data["supported"] : nil) if e.code == -32_022
        discover_error = e if offered.nil? || offered.empty?
      rescue Client::Error => e
        offered = nil
        discover_error = e
      end
      legacy(Budget.for(timeout), cancelled, offered, initial: true, discover_error: discover_error)
    end

    # @param timeout [Numeric] the whole call's, a re-handshake included
    # @return [Hash] the result
    def request(method, params = nil, timeout:, cancelled: nil)
      budget = Budget.for(timeout)
      if state.era == :expired
        @renewal.synchronize { renew(budget, cancelled) if state.era == :expired }
      end
      sent_state = state
      raise Client::Error, "#{method} before the handshake" unless %i[modern legacy].include?(sent_state.era)

      post(method, params, budget, cancelled, state: sent_state)
    rescue Expired
      raise if @renewal.owned?

      @renewal.synchronize do
        current = state
        if current.era == :legacy && !current.equal?(sent_state)
          sent_state = current
        else
          renew(budget, cancelled)
        end
        post(method, params, budget, cancelled, state: state)
      end
    end

    # A legacy session's best-effort DELETE; nothing for the modern era.
    def close
      snapshot = state
      return nil unless snapshot.era == :legacy && snapshot.session_id

      # A controller of its own: a cancelled turn's (ctx.http's default) would skip it.
      @http.request("DELETE", @url, headers: headers_for("DELETE", nil, snapshot), timeout: CLOSE_TIMEOUT,
                                    cancel: Samagotchi::CancellationController.new)
      nil
    rescue Samagotchi::Plugin::HttpError, Client::Error => e
      @log.call("close_failed", error: e.class.name)
      nil
    ensure
      publish(snapshot.with(session_id: nil)) if snapshot
    end

    private

    # A legacy session's handshake again (its 404). One that fails leaves
    # the era :expired, so the next request tries again; its error is the
    # server's state, never the tool's (Unavailable, no schema note).
    def renew(budget, cancelled)
      legacy(budget, cancelled, nil, initial: false, discover_error: nil)
    rescue Client::Timeout, Client::Cancelled, Client::Dead, Client::Unavailable
      raise
    rescue Client::Error => e
      raise Client::Unavailable, e.message
    ensure
      publish(State.new(:expired, nil, nil)) unless state.era == :legacy
    end

    # initialize, then notifications/initialized, in one +budget+.
    def legacy(budget, cancelled, offered, initial:, discover_error:)
      in_flight = State.new(:initialize, nil, nil)
      publish(in_flight) if initial
      initialized = false
      result, session_id = post("initialize", { protocolVersion: LEGACY, capabilities: {},
                                                clientInfo: { name: "chi", version: Samagotchi::VERSION } },
                                budget, cancelled, state: in_flight, session: true)
      initialized = true
      in_flight = State.new(:legacy, session_id,
                            result["protocolVersion"].is_a?(String) ? result["protocolVersion"] : LEGACY)
      publish(in_flight)
      post("notifications/initialized", nil, budget, cancelled, state: in_flight, notification: true)
      result
    rescue Client::Timeout, Client::Cancelled, Client::Dead, Refused
      raise
    rescue Client::Error => e
      publish(State.new(:expired, nil, nil)) unless initial || initialized
      if offered && !offered.empty?
        raise Client::Unavailable, "speaks MCP #{offered.join(", ")}, not #{MODERN} or #{LEGACY} (#{e.message})"
      end
      raise if discover_error.nil? || discover_error.message == e.message

      message = "#{e.message} (server/discover: #{discover_error.message})"
      raise e.class, message if [Client::Error, Client::Unavailable].include?(e.class)

      raise Client::Unavailable, message
    end

    # One message on the wire, and its answer, in what is left of +budget+.
    # A 401 to a token it sent renews the token once (#refresh_token!) and
    # sends the message again; the time a renew takes, before the message or
    # after its 401, isn't the budget's.
    # @return [Hash, nil] the result (nil for a notification)
    def post(method, params, budget, cancelled, state:, notification: false, session: false, renewed: false)
      id = notification ? nil : @mutex.synchronize { @next_id += 1 }
      message = { jsonrpc: "2.0", id: id, method: method, params: params_for(params, state) }.compact
      asked = monotonic
      headers = headers_for(method, params, state)
      budget = budget.later(monotonic - asked)
      raise Client::Timeout, timed_out(method, budget) if (left = budget.left) <= 0

      timer = Samagotchi::CancellationController.new
      budgeted(cancelled, timer, left) do
        @http.stream("POST", @url, body: JSON.generate(message), headers: headers, timeout: [left, 0.05].max, cancel: timer) do |res|
          refuse(res, headers.keys.any? { |name| name.casecmp?("authorization") }, state) unless res.ok?
          result = answer(res, id)
          session ? [result, res.headers["mcp-session-id"]] : result
        end
      end
    rescue Refused => e
      sent = headers&.fetch("Authorization", nil)&.delete_prefix("Bearer ")
      e.sent_digest ||= Digest::SHA256.hexdigest(sent)[0, 16] if sent
      raise unless e.status == 401 && sent && !renewed

      asked = monotonic
      raise unless @token.refresh_token!(sent)

      @log.call("token_renewed")
      post(method, params, budget.later(monotonic - asked), cancelled, state: state,
           notification: notification, session: session, renewed: true)
    rescue Samagotchi::Plugin::HttpCancelled
      raise Client::Timeout, timed_out(method, budget) if timer&.reason == :budget

      raise Client::Cancelled, "#{method} was cancelled"
    rescue Samagotchi::Plugin::HttpError => e
      raise Client::Timeout, timed_out(method, budget) if e.message.end_with?("timed out")

      raise Client::Dead, e.message
    end

    # +timer+, cancelled with +cancelled+ or once +left+ seconds have
    # passed, whichever comes first: the budget holds by the clock, whatever
    # the server sends (a keep-alive just before the end).
    def budgeted(cancelled, timer, left)
      listener = cancelled&.on_cancel { |reason| timer.cancel!(reason) }
      clock = Thread.new do
        sleep(left)
        timer.cancel!(:budget)
      end
      yield
    ensure
      clock&.kill&.join
      cancelled&.remove_listener(listener)
    end

    # The answer to message +id+ (nil: a notification's) in +res+.
    def answer(res, id)
      type = content_type(res)
      return nil if id.nil?

      case type
      when "application/json"
        result_of(parse(res.body, type))
      when "text/event-stream"
        reader = Samagotchi::Plugin::Http::SseReader.new
        res.each_chunk do |bytes|
          reader.feed(bytes) do |event|
            message = parse_event(event)
            return result_of(message) if message && !message.key?("method") && message["id"] == id
          end
        end
        raise Client::Error, "the server closed the stream without an answer"
      else
        raise Client::Unavailable, "unexpected answer (#{type.empty? ? "no content type" : type})"
      end
    end

    # An SSE event's JSON-RPC message; a notification or a server's
    # request is logged and skipped (nil), as is data that isn't JSON.
    def parse_event(event)
      message = JSON.parse(event.data)
      return nil unless message.is_a?(Hash)

      if message.key?("method")
        @log.call("server_notification", method: message["method"])
        return nil
      end
      message
    rescue JSON::ParserError
      @log.call("bad_line", line: event.data[0, 200])
      nil
    end

    def parse(body, type)
      message = JSON.parse(body)
      raise JSON::ParserError, "not an object" unless message.is_a?(Hash)

      message
    rescue JSON::ParserError, EncodingError
      raise Client::Unavailable, "unexpected answer (#{type}, not JSON-RPC)"
    end

    def result_of(message)
      raise RpcError, message["error"] if message["error"].is_a?(Hash)

      result = message["result"].is_a?(Hash) ? message["result"] : {}
      raise Client::Error, "the server asked for input chi can't give yet" if result["resultType"] == "input_required"

      result
    end

    def state = @mutex.synchronize { @state }

    def publish(value) = @mutex.synchronize { @state = value }

    # A status that isn't 2xx, in words; never its body unless it is a
    # JSON-RPC error.
    def refuse(res, token_sent, state)
      status = res.status
      raise Client::Unavailable, "redirected (#{status})#{redirect_to(res)}: set url: to the new address" if status.between?(300, 399)
      raise Refused.new(token_sent ? "refused the token (401)" : "needs a token or sign-in (401)", status: 401) if status == 401
      raise Refused.new("refused (403)", status: 403) if status == 403
      raise Expired, "the session expired (404)" if status == 404 && state.era == :legacy && state.session_id

      message = error_body(res) if content_type(res) == "application/json"
      raise RpcError, message["error"] if message.is_a?(Hash) && message["error"].is_a?(Hash) && message["error"].key?("code")

      raise Client::Unavailable, "HTTP #{status}"
    end

    # " to <origin>" of a redirect's Location; "" when it has none or it
    # isn't a URL (never the Location itself: it may be a signed URL).
    def redirect_to(res)
      location = res.headers["location"].to_s
      location.empty? ? "" : " to #{self.class.origin(URI.join(@url, location))}"
    rescue URI::Error
      ""
    end

    # A JSON error body, read up to ERROR_BODY_BYTES (nil past them, or
    # when it isn't JSON).
    def error_body(res)
      body = +"".b
      res.each_chunk do |bytes|
        body << bytes
        break if body.bytesize > ERROR_BODY_BYTES
      end
      body.bytesize > ERROR_BODY_BYTES ? nil : JSON.parse(body.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError, EncodingError
      nil
    end

    def params_for(params, state)
      return params unless %i[discover modern].include?(state.era)

      given = (params || {}).transform_keys(&:to_s)
      given.merge("_meta" => meta.merge(given["_meta"].is_a?(Hash) ? given["_meta"] : {}))
    end

    def meta
      { "io.modelcontextprotocol/protocolVersion" => MODERN,
        "io.modelcontextprotocol/clientInfo" => { name: "chi", version: Samagotchi::VERSION },
        "io.modelcontextprotocol/clientCapabilities" => {} }
    end

    # The config's headers, then chi's own (the config can't name them).
    def headers_for(method, params, state)
      headers = @headers.merge("Accept" => ACCEPT, "Content-Type" => "application/json")
      token = @token.call
      headers["Authorization"] = "Bearer #{token}" if token
      case state.era
      when :discover, :modern
        headers["MCP-Protocol-Version"] = MODERN
        headers["Mcp-Method"] = method
        name = params.is_a?(Hash) ? (params[:name] || params["name"]) : nil
        headers["Mcp-Name"] = name.to_s if method == "tools/call" && name
      when :legacy
        headers["MCP-Protocol-Version"] = state.protocol
        headers["Mcp-Session-Id"] = state.session_id if state.session_id
      end
      headers
    end

    def content_type(res) = res.headers["content-type"].to_s.split(";").first.to_s.strip.downcase

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def timed_out(method, budget) = "#{method} timed out after #{format("%g", budget.seconds)}s"
  end
end
