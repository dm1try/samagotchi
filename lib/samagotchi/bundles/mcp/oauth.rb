# frozen_string_literal: true

# The mcp bundle's OAuth part (manifest.yml plugin: parts:, loaded after
# http_client.rb, whose Refused NeedsSignIn subclasses, and before plugin.rb):
# signing in to a remote MCP server that answers 401 (the MCP spec's
# authorization, revision 2026-07-28). Discovery (the server's protected
# resource metadata, then its provider's metadata), the client chi signs in
# as (one configured by hand, else a registration of its own), PKCE, the
# code's exchange, and the token object HttpClient sends (OAuth::Token).
# plugin.rb keeps the wiring: /mcp login|logout, the server's state, the
# cards. What it shows or logs never holds a token, a code, a verifier, a
# client secret or a whole authorize address: an error here is one plain
# line (Refusal) naming at most an origin.
require "digest"
require "ipaddr"
require "json"
require "openssl"
require "securerandom"
require "socket"
require "strscan"
require "uri"
require "samagotchi/cancellation_controller"

class Plugin
  module OAuth
    # A sign-in step that can't go on, its message the card's line.
    class Refusal < StandardError
      # The flow's card to replace with it (nil before the flow started).
      attr_accessor :card_id
    end

    # The provider doesn't know the client chi signed in as (invalid_client):
    # one fresh registration, once.
    class InvalidClient < Refusal; end

    # The server's sign-in is gone (none kept, renewing refused): the user
    # signs in again. A 401, as HttpClient's own.
    class NeedsSignIn < HttpClient::Refused
      def initialize(message = "needs sign-in (401)")
        super(message, status: 401)
      end
    end

    # Each fetch of sign-in data: its timeout and the most of a body read.
    FETCH_TIMEOUT = 10
    BODY_BYTES = 256 * 1024
    # The token exchange and the revocation.
    EXCHANGE_TIMEOUT = 15
    REVOKE_TIMEOUT = 5
    # How long a sign-in waits for the browser (ctx.sign_in's default).
    SIGN_IN_TIMEOUT = 300
    # The redirect address a registration names besides the exact one.
    LOOPBACK_REDIRECT = "http://127.0.0.1/callback"

    # Where a sign-in's data may not come from unless the server itself is
    # on a loopback host (RFC 9728 §7.7): loopback, private, link-local,
    # shared (100.64/10, a tailnet's) and unique-local addresses.
    INTERNAL = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16
                  ::/128 ::1/128 fc00::/7 fe80::/10].map { |range| IPAddr.new(range) }.freeze

    # 16 hex of a SHA-256: a secret's name for an address.
    def self.key(text) = Digest::SHA256.hexdigest(text.to_s)[0, 16]

    # The secret holding the sign-in for +resource+ (a canonical url).
    def self.token_name(resource) = "oauth-#{key(resource)}"

    # The secret holding chi's registration with the provider +issuer+.
    def self.client_name(issuer) = "client-#{key(issuer)}"

    # The url as a resource indicator (RFC 8707, the MCP spec's canonical
    # form): scheme and host lower-cased, no default port, no fragment, no
    # trailing slash. Nil for an address that isn't one.
    def self.canonical(url)
      uri = URI.parse(url.to_s)
      return nil unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?

      port = uri.port == uri.default_port ? "" : ":#{uri.port}"
      query = uri.query ? "?#{uri.query}" : ""
      "#{uri.scheme.downcase}://#{uri.host.downcase}#{port}#{uri.path.to_s.sub(%r{/+\z}, "")}#{query}"
    rescue URI::Error
      nil
    end

    def self.origin(url) = HttpClient.origin(url)

    def self.loopback_host?(host) = %w[127.0.0.1 ::1 [::1] localhost].include?(host.to_s.downcase)

    # Printable ASCII only, at most +max+: a provider's error code or
    # description on a card (never a control character).
    def self.plain(text, max)
      text.to_s.gsub(/[^\x20-\x7e]/, "")[0, max]
    end

    # A sign-out's best-effort revocation (RFC 7009) of the kept sign-in:
    # its refresh token, else its access token, at the kept endpoint. A
    # failure is only logged (its class).
    def self.revoke(http, kept, log:)
      endpoint = kept["revocation_endpoint"]
      return unless endpoint.is_a?(String)

      hint = kept["refresh_token"] ? "refresh_token" : "access_token"
      form = { token: kept[hint], token_type_hint: hint, client_id: kept["client_id"],
               client_secret: kept["client_secret"] }.compact
      res = http.request("POST", endpoint, body: URI.encode_www_form(form), timeout: REVOKE_TIMEOUT,
                                           headers: { "Content-Type" => "application/x-www-form-urlencoded" },
                                           cancel: Samagotchi::CancellationController.new)
      log.call("oauth_revoked", status: res.status)
    rescue Samagotchi::Plugin::HttpError, ArgumentError => e
      log.call("oauth_not_revoked", error: e.class.name)
    end

    # The Bearer challenge's parameters in a WWW-Authenticate value, which
    # may hold several challenges (Net::HTTP joins repeated headers with
    # ", "): {"resource_metadata" => …, "scope" => …}, {} without one.
    def self.challenge(header)
      challenges = []
      scanner = StringScanner.new(header.to_s)
      token = /[!#$%&'*+\-.^_`|~0-9A-Za-z]+/
      until scanner.eos?
        scanner.skip(/[\s,]+/)
        break if scanner.eos?

        if scanner.scan(/(#{token})\s*=\s*/o)
          name = scanner[1].downcase
          value = scanner.scan(/"((?:[^"\\]|\\.)*)"/) ? scanner[1].gsub(/\\(.)/, '\1') : scanner.scan(/[^\s,]*/)
          challenges.last[1][name] ||= value if challenges.last
        elsif scanner.scan(token)
          challenges << [scanner.matched.downcase, {}]
          scanner.skip(%r{[ \t]+[A-Za-z0-9\-._~+/]+=*(?=[ \t]*(?:,|\z))}) # a token68
        else
          scanner.getch
        end
      end
      challenges.find { |scheme, _| scheme == "bearer" }&.last || {}
    end

    # A provider, as its metadata says (validated): +iss_required+ whether a
    # callback must carry iss (authorization_response_iss_parameter_supported),
    # +cimd+ whether it takes a client id metadata document, +scope+ the one
    # to ask for (nil: none).
    Provider = Data.define(:issuer, :authorization_endpoint, :token_endpoint, :registration_endpoint,
                           :revocation_endpoint, :iss_required, :cimd, :scope)

    # The client chi signs in as: +kind+ :config, :cimd or :dcr; +port+ the
    # redirect port it needs (nil: any); +fresh+ a registration made by this
    # login (an invalid_client then isn't a stale one).
    Registration = Data.define(:kind, :client_id, :client_secret, :port, :fresh) do
      def inspect = "#<Registration #{kind} port=#{port.inspect}>"

      alias_method :to_s, :inspect
    end

    # The sign-in data fetches: https only (http on a loopback host when the
    # server's url is on one), never to an internal address (unless the
    # server is on a loopback host), no redirect followed, a body of at most
    # BODY_BYTES, JSON objects only. Each fetch is ctx.http's one log line
    # (no query, no body); its failure a Refusal naming the origin.
    class Wire
      # @param http [#stream] ctx.http
      # @param local [Boolean] the server's url is on a loopback host
      # @param cancel [Samagotchi::CancellationController]
      # @param resolve [#call] (host) → its addresses, for the internal check
      # @param trusted [Array<String>] hosts the user configured (the
      #   server's url, oauth: issuer:): an internal address is theirs to
      #   choose; the guard is for what discovery names (https still)
      def initialize(http:, local:, cancel:, resolve: nil, trusted: [])
        @http = http
        @local = local
        @cancel = cancel
        @trusted = trusted.compact.map { |host| host.to_s.downcase }
        @resolve = resolve || ->(host) { Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address).uniq }
      end

      # @raise [Refusal] +url+ can't be asked for sign-in data
      def check!(url, what)
        uri = URI.parse(url.to_s)
        raise Refusal, "#{what} isn't an address" unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty? && uri.userinfo.nil?
        raise Refusal, "#{what} isn't https (#{OAuth.origin(url)})" unless uri.scheme == "https" || (@local && OAuth.loopback_host?(uri.host))
        return if @local || @trusted.include?(uri.host.to_s.downcase)

        raise Refusal, "#{what} is an internal address (#{OAuth.origin(url)})" if internal?(uri.host)
      rescue URI::Error
        raise Refusal, "#{what} isn't an address"
      end

      # GET a JSON object.
      # @return [Hash, nil] nil for a status that isn't 2xx (a 3xx too)
      # @raise [Refusal] unreachable, too large, not a JSON object
      def get_json(url, what)
        check!(url, what)
        status, body = fetch("GET", url, nil, { "Accept" => "application/json" }, FETCH_TIMEOUT, what)
        return nil unless status.between?(200, 299)

        object(body, what)
      end

      # POST a body; the answer's status and its JSON object (nil when it
      # isn't one: an error page).
      # @return [Array(Integer, Hash, nil)]
      def post(url, body, content_type, what, timeout: FETCH_TIMEOUT)
        check!(url, what)
        headers = { "Accept" => "application/json", "Content-Type" => content_type }
        status, text = fetch("POST", url, body, headers, timeout, what)
        json = begin
          object(text, what)
        rescue Refusal
          nil
        end
        [status, json]
      end

      # The status, and the body read up to BODY_BYTES (nil for a 3xx: not
      # followed, not read).
      def fetch(method, url, body, headers, timeout, what)
        @http.stream(method, url, body: body, headers: headers, timeout: timeout, cancel: @cancel) do |res|
          next [res.status, nil] if res.status.between?(300, 399)

          text = +"".b
          res.each_chunk do |bytes|
            text << bytes
            raise Refusal, "#{what} is larger than #{BODY_BYTES / 1024} KB" if text.bytesize > BODY_BYTES
          end
          [res.status, text]
        end
      rescue Samagotchi::Plugin::HttpCancelled
        raise Refusal, "the sign-in was cancelled"
      rescue Samagotchi::Plugin::HttpError
        raise Refusal, "#{what} can't be reached (#{OAuth.origin(url)})"
      end

      private

      def object(text, what)
        value = JSON.parse(text.to_s.dup.force_encoding(Encoding::UTF_8))
        raise Refusal, "#{what} isn't a JSON object" unless value.is_a?(Hash)

        value
      rescue JSON::ParserError, EncodingError
        raise Refusal, "#{what} isn't a JSON object"
      end

      def internal?(host)
        bare = host.delete_prefix("[").delete_suffix("]")
        addresses = begin
          [IPAddr.new(bare)]
        rescue IPAddr::InvalidAddressError
          Array(@resolve.call(bare)).filter_map { |ip| IPAddr.new(ip.to_s.sub(/%.*\z/, "")) rescue nil } # degrade-ok: a scoped address
        end
        addresses.any? { |ip| INTERNAL.any? { |range| range.include?(ip.ipv4_mapped? ? ip.native : ip) } }
      rescue SocketError
        false # a name that doesn't resolve: the fetch fails on its own
      end
    end

    # The protected resource metadata, then its provider's (the spec's
    # discovery), checked. +name+ is the server's (each refusal names it).
    class Discovery
      def initialize(wire:, name:, resource:)
        @wire = wire
        @name = name
        @resource = resource
      end

      # @param challenge [Hash] the 401's Bearer parameters (OAuth.challenge)
      # @param scopes [Array<String>, nil] oauth: scopes: from config
      # @param bound [String, nil] the issuer a client registered by hand is
      #   for: another one is refused before it is asked anything (it would
      #   get the client's secret)
      # @return [Provider]
      # @raise [Refusal]
      def run(challenge, scopes: nil, bound: nil)
        resource = resource_metadata(challenge["resource_metadata"])
        issuer = Array(resource["authorization_servers"]).first
        raise Refusal, "#{@name}'s sign-in data names no sign-in provider" unless issuer.is_a?(String) && !issuer.empty?
        if bound && issuer != bound
          raise Refusal, "#{@name} now points at another sign-in provider (#{OAuth.plain(issuer, 200)}); your client is " \
                         "registered with #{bound}"
        end

        meta = provider_metadata(issuer)
        scope = if scopes && !scopes.empty? then scopes.join(" ")
                elsif challenge["scope"].to_s.strip != "" then challenge["scope"].strip
                elsif resource["scopes_supported"].is_a?(Array) && !resource["scopes_supported"].empty?
                  resource["scopes_supported"].grep(String).join(" ")
                end
        Provider.new(issuer: issuer, authorization_endpoint: meta["authorization_endpoint"], token_endpoint: meta["token_endpoint"],
                     registration_endpoint: meta["registration_endpoint"], revocation_endpoint: meta["revocation_endpoint"],
                     iss_required: meta["authorization_response_iss_parameter_supported"] == true,
                     cimd: meta["client_id_metadata_document_supported"] == true, scope: scope)
      end

      # The well-known addresses of +url+'s protected resource metadata: the
      # path inserted (its query and a trailing slash dropped), then the
      # root (RFC 9728 §3.1).
      def self.resource_addresses(url)
        uri = URI.parse(url)
        port = uri.port == uri.default_port ? "" : ":#{uri.port}"
        origin = "#{uri.scheme}://#{uri.host}#{port}"
        path = uri.path.to_s.sub(%r{/+\z}, "")
        root = "#{origin}/.well-known/oauth-protected-resource"
        path.empty? ? [root] : ["#{root}#{path}", root]
      end

      # The provider metadata addresses for +issuer+, in the spec's order.
      def self.provider_addresses(issuer)
        uri = URI.parse(issuer)
        port = uri.port == uri.default_port ? "" : ":#{uri.port}"
        origin = "#{uri.scheme}://#{uri.host}#{port}"
        path = uri.path.to_s.sub(%r{/+\z}, "")
        return ["#{origin}/.well-known/oauth-authorization-server", "#{origin}/.well-known/openid-configuration"] if path.empty?

        ["#{origin}/.well-known/oauth-authorization-server#{path}", "#{origin}/.well-known/openid-configuration#{path}",
         "#{origin}#{path}/.well-known/openid-configuration"]
      end

      private

      # The header's address (the spec: use it when there is one), else the
      # well-known ones in order; its resource must be this server's.
      def resource_metadata(given)
        addresses = given ? [given] : self.class.resource_addresses(@resource)
        found = addresses.lazy.filter_map { |address| @wire.get_json(address, "#{@name}'s sign-in data") }.first
        raise Refusal, "#{@name} asks for sign-in but gives no sign-in data (#{OAuth.origin(@resource)})" unless found
        raise Refusal, "#{@name}'s sign-in data is for another address" unless OAuth.canonical(found["resource"]) == @resource

        found
      end

      def provider_metadata(issuer)
        @wire.check!(issuer, "#{@name}'s sign-in provider")
        addresses = self.class.provider_addresses(issuer)
        meta = addresses.lazy.filter_map { |address| @wire.get_json(address, "#{@name}'s provider metadata") }.first
        raise Refusal, "#{@name}'s sign-in provider gives no metadata (#{OAuth.origin(issuer)})" unless meta
        raise Refusal, "#{@name}'s provider metadata is for another provider" unless meta["issuer"] == issuer
        unless Array(meta["code_challenge_methods_supported"]).include?("S256")
          raise Refusal, "#{@name}'s sign-in provider doesn't offer PKCE (S256): chi can't sign in there"
        end
        unless meta["authorization_endpoint"].is_a?(String) && meta["token_endpoint"].is_a?(String)
          raise Refusal, "#{@name}'s provider metadata has no authorization or token endpoint"
        end

        { "authorization_endpoint" => "authorization endpoint", "token_endpoint" => "token endpoint",
          "registration_endpoint" => "registration endpoint", "revocation_endpoint" => "revocation endpoint" }.each do |key, what|
          @wire.check!(meta[key], "#{@name}'s #{what}") if meta.key?(key)
        end
        meta
      end
    end

    # One /mcp login's work, on the plugin's thread: discovery, the client,
    # the flow (ctx.sign_in), the callback's checks and the exchange. Its
    # #run keeps the token and returns the flow's card id.
    class Login
      # @param ctx [Plugin::Context] the plugin's (sign_in, http, secrets)
      # @param server [Plugin::Server] a url server that signs in
      # @param secret_lookup [#call] (variable) → its value, nil when unset
      # @param client_metadata_url [String, nil] chi's CIMD address
      # @param cimd_refused [Hash] issuer => true: the worker's providers
      #   that refused it (DCR from then on, never saved)
      # @param cancel [Samagotchi::CancellationController] the plugin's
      #   sign-ins' (its shutdown)
      # @param resolve [#call, nil] Wire's resolver (a spec's)
      def initialize(ctx:, server:, secret_lookup:, client_metadata_url:, cimd_refused:, cancel:, log:, resolve: nil)
        @ctx = ctx
        @name = server.name
        @url = server.url
        @headers = server.headers || {}
        @oauth = server.oauth.is_a?(Hash) ? server.oauth : {}
        @resource = OAuth.canonical(@url)
        @secret_lookup = secret_lookup
        @client_metadata_url = client_metadata_url
        @cimd_refused = cimd_refused
        @cancel = cancel
        @log = log
        local = OAuth.loopback_host?(URI.parse(@url).host)
        issuer_host = @oauth["client_id"] && URI.parse(@oauth["issuer"].to_s).host
        @wire = Wire.new(http: ctx.http, local: local, cancel: cancel, resolve: resolve, trusted: [URI.parse(@url).host, issuer_host])
      end

      def inspect = "#<Login #{@name}>"

      # @return [String, nil] the flow's card id once signed in; nil when the
      #   flow ended without a callback (core replaced its card)
      # @raise [Refusal] (its card_id the flow's when there was one)
      def run
        provider = Discovery.new(wire: @wire, name: @name, resource: @resource)
                            .run(probe, scopes: Array(@oauth["scopes"]).grep(String), bound: @oauth["client_id"] && @oauth["issuer"])
        registration = client_for(provider)
        begin
          attempt(provider, registration)
        rescue InvalidClient => e
          raise if registration.fresh || registration.kind == :config

          @cimd_refused[provider.issuer] = true if registration.kind == :cimd
          @ctx.card(id: e.card_id, title: "Signing in to #{@name} again", body: "The provider didn't know chi's client: " \
                                                                           "chi registers again; open the new sign-in.", between_turns: true)
          attempt(provider, client_for(provider, fresh: true))
        end
      end

      private

      # One request with no token, for the 401's challenge (the plugin's
      # client threw it away): {} when it has none.
      def probe
        @wire.check!(@url, "#{@name}'s address") unless OAuth.loopback_host?(URI.parse(@url).host)
        body = JSON.generate({ jsonrpc: "2.0", id: 0, method: "server/discover", params: {} })
        headers = @headers.merge("Accept" => HttpClient::ACCEPT, "Content-Type" => "application/json",
                                 "MCP-Protocol-Version" => HttpClient::MODERN, "Mcp-Method" => "server/discover")
        @ctx.http.stream("POST", @url, body: body, headers: headers, timeout: FETCH_TIMEOUT, cancel: @cancel) do |res|
          res.status == 401 ? OAuth.challenge(res.headers["www-authenticate"]) : {}
        end
      rescue Samagotchi::Plugin::HttpCancelled
        raise Refusal, "the sign-in was cancelled"
      rescue Samagotchi::Plugin::HttpError
        raise Refusal, "#{@name} can't be reached (#{OAuth.origin(@url)})"
      end

      # The client, in the spec's order: configured, chi's document (CIMD),
      # a registration of chi's own (DCR, kept per provider), else none.
      def client_for(provider, fresh: false)
        port = @oauth["redirect_port"]
        if (id = @oauth["client_id"])
          return configured(provider, id, port)
        end
        if !fresh && provider.cimd && @client_metadata_url && !@cimd_refused[provider.issuer]
          return Registration.new(kind: :cimd, client_id: @client_metadata_url, client_secret: nil, port: port, fresh: false)
        end
        return registered(provider, port, fresh) if provider.registration_endpoint

        raise Refusal, "#{@name}'s sign-in provider needs a client you register yourself: set oauth: client_id: and issuer: " \
                       "(and redirect_port: when it wants one exact redirect address)"
      end

      # A client registered by hand (bound to its provider: Discovery#run).
      def configured(_provider, id, port)
        secret = nil
        if (variable = @oauth["client_secret_env"])
          secret = @secret_lookup.call(variable)
          raise Refusal, "#{variable} is not set (oauth: client_secret_env:)" if secret.nil? || secret.empty?
        end
        Registration.new(kind: :config, client_id: id, client_secret: secret, port: port, fresh: false)
      end

      # chi's registration with the provider: the kept one for the redirect
      # port it was made for, else a new one (RFC 7591), kept.
      def registered(provider, port, fresh)
        name = OAuth.client_name(provider.issuer)
        kept = fresh ? nil : parse(@ctx.secrets.get(name))
        kept = nil if kept && (kept["issuer"] != provider.issuer || (port && kept["port"] != port))
        if kept
          return Registration.new(kind: :dcr, client_id: kept["client_id"], client_secret: kept["client_secret"],
                                  port: kept["port"], fresh: false)
        end

        port ||= free_port
        redirect = "http://127.0.0.1:#{port}/callback"
        body = { client_name: "chi", redirect_uris: [LOOPBACK_REDIRECT, redirect], application_type: "native",
                 grant_types: %w[authorization_code refresh_token], response_types: ["code"], token_endpoint_auth_method: "none" }
        status, answer = @wire.post(provider.registration_endpoint, JSON.generate(body), "application/json",
                                    "#{@name}'s provider's registration")
        unless status.between?(200, 299) && answer && answer["client_id"].is_a?(String) && !answer["client_id"].empty?
          raise Refusal, "#{@name}'s sign-in provider didn't register chi (#{error_of(status, answer)})"
        end

        secret = answer["client_secret"].is_a?(String) ? answer["client_secret"] : nil
        @ctx.secrets.set(name, JSON.generate({ client_id: answer["client_id"], client_secret: secret, port: port,
                                               redirect_uri: redirect, issuer: provider.issuer }.compact))
        @log.call("oauth_registered", server: @name, provider: OAuth.origin(provider.issuer))
        Registration.new(kind: :dcr, client_id: answer["client_id"], client_secret: secret, port: port, fresh: true)
      end

      # The flow: the authorize address built inside ctx.sign_in's block, the
      # callback checked, the code exchanged, the token kept.
      def attempt(provider, registration)
        verifier = [SecureRandom.random_bytes(64)].pack("m0").tr("+/", "-_").delete("=")
        state = [SecureRandom.random_bytes(32)].pack("m0").tr("+/", "-_").delete("=")
        flow = begin
          @ctx.sign_in(title: "Sign in to #{@name}", button: "Open sign-in page", timeout: SIGN_IN_TIMEOUT,
                       port: registration.port, cancel: @cancel) do |redirect_uri|
            authorize_address(provider, registration, redirect_uri, verifier, state)
          end
        rescue ArgumentError => e
          raise unless e.message.match?(/port \d+ is taken/)

          raise Refusal, "port #{registration.port} is in use: try again, or set oauth: redirect_port:"
        end
        return nil if flow.outcome == :stopped

        result = flow.wait
        return nil unless result

        with_card(flow.card_id) do
          code = callback_code(result, provider, state)
          record = exchange(provider, registration, code, verifier, flow.redirect_uri)
          @ctx.secrets.set(OAuth.token_name(@resource), JSON.generate(record))
          @log.call("oauth_signed_in", server: @name, provider: OAuth.origin(provider.issuer), expires: !record[:expires_at].nil?)
        end
        flow.card_id
      end

      def with_card(card_id)
        yield
      rescue Refusal => e
        e.card_id ||= card_id
        raise
      end

      def authorize_address(provider, registration, redirect_uri, verifier, state)
        params = { response_type: "code", client_id: registration.client_id, redirect_uri: redirect_uri, state: state,
                   code_challenge: [Digest::SHA256.digest(verifier)].pack("m0").tr("+/", "-_").delete("="),
                   code_challenge_method: "S256", resource: @resource, scope: provider.scope }.compact
        uri = URI.parse(provider.authorization_endpoint)
        uri.query = [uri.query, URI.encode_www_form(params)].compact.join("&")
        uri.to_s
      end

      # The callback's code, after its checks (RFC 9207's iss first: on a
      # mismatch the error isn't shown).
      def callback_code(result, provider, state)
        iss = result["iss"]
        raise Refusal, "the sign-in answer came from another provider" if iss && iss != provider.issuer
        raise Refusal, "the sign-in answer doesn't name its provider (iss)" if iss.nil? && provider.iss_required

        # Core checked it too (ctx.sign_in): again here, in constant time.
        raise Refusal, "the sign-in answer's state doesn't match" unless OpenSSL.secure_compare(result["state"].to_s, state)

        if result["error"]
          error = OAuth.plain(result["error"], 64)
          raise InvalidClient, "#{@name}'s provider refused chi's client (invalid_client)" if error == "invalid_client"

          detail = OAuth.plain(result["error_description"], 200)
          raise Refusal, "the provider refused: #{error}#{": #{detail}" unless detail.empty?}"
        end
        code = result["code"].to_s
        raise Refusal, "the sign-in answer has no code" if code.empty?

        code
      end

      # The code for a token (RFC 6749 §4.1.3, PKCE's verifier, RFC 8707's
      # resource), kept as one JSON value bound to this url.
      def exchange(provider, registration, code, verifier, redirect_uri)
        form = { grant_type: "authorization_code", code: code, redirect_uri: redirect_uri, client_id: registration.client_id,
                 code_verifier: verifier, resource: @resource, client_secret: registration.client_secret }.compact
        status, answer = @wire.post(provider.token_endpoint, URI.encode_www_form(form), "application/x-www-form-urlencoded",
                                    "#{@name}'s token endpoint", timeout: EXCHANGE_TIMEOUT)
        unless status.between?(200, 299)
          error = error_of(status, answer)
          raise InvalidClient, "#{@name}'s provider refused chi's client (invalid_client)" if error == "invalid_client"

          raise Refusal, "#{@name}'s sign-in provider gave no token (#{error})"
        end
        token = answer && answer["access_token"]
        unless token.is_a?(String) && !token.empty? && answer["token_type"].to_s.casecmp?("bearer")
          raise Refusal, "#{@name}'s sign-in provider's answer has no bearer token"
        end

        Token.record(answer, provider: provider, registration: registration, resource: @resource)
      end

      # A provider's OAuth error code, or the status.
      def error_of(status, answer)
        code = answer.is_a?(Hash) ? OAuth.plain(answer["error"], 64) : ""
        code.empty? ? "HTTP #{status}" : code
      end

      def parse(text)
        value = text && JSON.parse(text)
        value.is_a?(Hash) ? value : nil
      rescue JSON::ParserError
        nil
      end

      # A port free now on 127.0.0.1, for a registration's exact redirect.
      def free_port
        server = TCPServer.new("127.0.0.1", 0)
        server.addr[1]
      ensure
        server&.close
      end
    end

    # The token HttpClient sends for a server that signs in (its token:,
    # beside StaticToken): the kept sign-in for this url (ctx.secrets,
    # OAuth.token_name), read once per worker into memory and again while
    # there is none. A kept token whose resource isn't this url is never
    # sent. It renews itself when it runs out within AHEAD seconds, and on
    # HttpClient's 401 (#refresh_token!). Safe from several threads: one
    # Mutex over what it holds, one more so a worker renews once at a time;
    # across workers, the secret's lock.
    class Token
      # Renewed when it runs out within this many seconds (or half its life,
      # if that is shorter: a token for a minute isn't renewed at each request).
      AHEAD = 60
      # The renew request's whole time (by the clock, its own controller:
      # never the turn's, a Stop would lose a rotated refresh token) and the
      # wait for another worker's renew: above that request's, and at most
      # 30 s together, outside the call's own timeout.
      RENEW_SECONDS = 12
      RENEW_LOCK = 18

      # The JSON value kept for a sign-in.
      def self.record(answer, provider:, registration:, resource:, now: Time.now.to_i)
        expires_in = Integer(answer["expires_in"], exception: false) if answer.key?("expires_in")
        { access_token: answer["access_token"],
          refresh_token: answer["refresh_token"].is_a?(String) ? answer["refresh_token"] : nil,
          expires_at: expires_in&.positive? ? now + expires_in : nil, issued_at: now,
          scope: answer["scope"].is_a?(String) ? answer["scope"] : provider.scope,
          issuer: provider.issuer, token_endpoint: provider.token_endpoint, revocation_endpoint: provider.revocation_endpoint,
          client_id: registration.client_id, client_secret: registration.kind == :dcr ? registration.client_secret : nil,
          resource: resource }.compact
      end

      # @param secrets [#get, #update, #delete] ctx.secrets
      # @param resource [String, nil] the server's canonical url (nil: one
      #   that can't sign in, a url with a query: never a token)
      # @param http [#stream, nil] ctx.http, for renewing (nil: never renews)
      # @param client [Hash, nil] the configured client ({id:, issuer:}):
      #   its secret goes only with a kept sign-in made as that client at that
      #   provider, never to another one's token endpoint
      # @param client_secret [#call] → the configured client's secret, nil
      # @param log [#call] (event, fields)
      # @param clock [#call] → now, epoch seconds
      def initialize(secrets:, resource:, http: nil, client: nil, client_secret: -> {}, log: ->(*) {}, clock: -> { Time.now.to_i })
        @secrets = secrets
        @resource = resource
        @client = client
        @name = resource && OAuth.token_name(resource)
        @http = http
        @client_secret = client_secret
        @log = log
        @clock = clock
        @mutex = Mutex.new
        @renewing = Mutex.new
        @held = nil
      end

      def inspect = "#<OAuth::Token #{@resource ? OAuth.origin(@resource) : "none"} held=#{!@held.nil?}>"

      def pretty_print(printer) = printer.text(inspect)

      # The access token, renewed first when it runs out within AHEAD
      # seconds (one that can't be renewed now is still sent while it holds).
      # @return [String, nil] nil when there is no sign-in
      # @raise [NeedsSignIn] renewing was refused; [Client::Dead] it failed
      #   and the token ran out; [Client::Unavailable] the store failed
      def call
        current = held
        return nil unless current

        expires_at = current["expires_at"]
        if expires_at.is_a?(Integer) && expires_at - @clock.call < ahead(current) && current["refresh_token"] && @http
          begin
            refresh_token!(current["access_token"])
          rescue NeedsSignIn
            raise
          rescue Client::Error
            raise if expires_at <= @clock.call
          end
          current = held
        end
        current&.fetch("access_token")
      end

      # Renew the token +sent+ (the one a 401 refused; nil: the one held),
      # under the secret's lock: another worker that renewed it already
      # gave the store a newer token, taken with no request; else a
      # refresh_token grant at the kept token endpoint, the new token kept
      # (and the new refresh token, else the old).
      # @return [Boolean] true: a new token to try
      # @raise [NeedsSignIn] no refresh token, or the provider refused it
      #   (invalid_grant): the kept sign-in is deleted; [Client::Dead] the
      #   provider can't be reached or failed: the token is kept
      def refresh_token!(sent = nil)
        return false unless @name && @http

        @renewing.synchronize do
          known = @mutex.synchronize { @held }
          return true if sent && known && known["access_token"] != sent # this worker renewed it meanwhile

          stale = sent || known&.fetch("access_token")
          outcome = nil
          @secrets.update(@name, timeout: RENEW_LOCK) do |old|
            stored = parse(old)
            if stored.nil? || stored["resource"] != @resource
              outcome = :gone
              next old
            end
            if stored["access_token"] != stale
              outcome = :taken
              @mutex.synchronize { @held = stored }
              next old
            end
            outcome, value = renewed(stored)
            next value
          end
          settle(outcome)
        end
      rescue Samagotchi::Plugin::Secrets::Unavailable, Samagotchi::Plugin::Secrets::Busy => e
        raise Client::Unavailable, "the sign-in can't be renewed: #{e.message}"
      rescue ArgumentError => e # a renewed sign-in the store refuses (over 16 KB): nothing kept, the old one stays
        raise Client::Unavailable, "the sign-in can't be renewed: #{e.message[/\A[^(]{0,120}/].strip}"
      end

      # Forget what it holds: the next #call reads the store (a new sign-in,
      # a sign-out).
      def forget = @mutex.synchronize { @held = nil }

      # The kept sign-in (for a sign-out's revocation), read now.
      # @return [Hash, nil]
      def kept = read

      # The store's name for it (nil when it can't sign in).
      attr_reader :name

      private

      def held
        @mutex.synchronize { @held ||= read }
      end

      def ahead(record)
        life = record["expires_at"] - record["issued_at"] if record["issued_at"].is_a?(Integer)
        life ? [AHEAD, life / 2].min : AHEAD
      end

      def read
        return nil unless @name

        value = parse(@secrets.get(@name))
        return nil unless value && value["resource"] == @resource

        value
      rescue Samagotchi::Plugin::Secrets::Unavailable, Samagotchi::Plugin::Secrets::Busy => e
        raise Client::Unavailable, "the sign-in can't be read: #{e.message}"
      end

      def parse(text)
        value = text && JSON.parse(text)
        value.is_a?(Hash) && value["access_token"].is_a?(String) ? value : nil
      rescue JSON::ParserError
        nil
      end

      # Inside the secret's lock: the refresh_token grant.
      # @return [Array(Symbol, String|nil)] the outcome and what the store keeps
      def renewed(stored)
        return [:refused, nil] unless stored["refresh_token"].is_a?(String)

        status, answer = grant(stored)
        if status.between?(200, 299) && answer && answer["access_token"].is_a?(String) &&
           answer["token_type"].to_s.casecmp?("bearer")
          expires_in = Integer(answer["expires_in"], exception: false)
          fresh = stored.merge("access_token" => answer["access_token"],
                               "refresh_token" => answer["refresh_token"].is_a?(String) ? answer["refresh_token"] : stored["refresh_token"],
                               "expires_at" => expires_in&.positive? ? @clock.call + expires_in : nil, "issued_at" => @clock.call)
          fresh["scope"] = answer["scope"] if answer["scope"].is_a?(String)
          @mutex.synchronize { @held = fresh }
          @log.call("oauth_renewed", where: OAuth.origin(stored["token_endpoint"]))
          return [:renewed, JSON.generate(fresh)]
        end
        error = answer.is_a?(Hash) ? OAuth.plain(answer["error"], 64) : ""
        @log.call("oauth_not_renewed", where: OAuth.origin(stored["token_endpoint"]), status: status, error: error)
        return [:refused, nil] if error == "invalid_grant"

        @failure = error.empty? ? "HTTP #{status}" : error
        [:failed, JSON.generate(stored)]
      rescue Refusal => e
        @log.call("oauth_not_renewed", where: OAuth.origin(stored["token_endpoint"]), error: "unreachable")
        @failure = e.message
        [:failed, JSON.generate(stored)]
      end

      # The grant, on a controller of its own cancelled after RENEW_SECONDS.
      def grant(stored)
        form = { grant_type: "refresh_token", refresh_token: stored["refresh_token"], client_id: stored["client_id"],
                 resource: @resource, client_secret: stored["client_secret"] || configured_secret(stored) }.compact
        cancel = Samagotchi::CancellationController.new
        timer = Thread.new do
          sleep(RENEW_SECONDS)
          cancel.cancel!(:budget)
        end
        # The kept endpoint is checked again (an address can resolve elsewhere
        # by now); the hosts the user configured are trusted, as at the sign-in.
        local = OAuth.loopback_host?(URI.parse(@resource).host)
        trusted = [URI.parse(@resource).host, @client && URI.parse(@client[:issuer].to_s).host]
        Wire.new(http: @http, local: local, cancel: cancel, trusted: trusted)
            .post(stored["token_endpoint"], URI.encode_www_form(form), "application/x-www-form-urlencoded",
                  "the token endpoint", timeout: RENEW_SECONDS)
      ensure
        timer&.kill&.join
      end

      # The configured client's secret, for a sign-in made as that client
      # (its id and provider both): nil for any other.
      def configured_secret(stored)
        return nil unless @client && stored["client_id"] == @client[:id] && stored["issuer"] == @client[:issuer]

        @client_secret.call
      end

      def settle(outcome)
        case outcome
        when :taken, :renewed then true
        when :failed then raise Client::Dead, "its sign-in couldn't be renewed (#{@failure})"
        else
          forget
          raise NeedsSignIn
        end
      end
    end
  end
end
