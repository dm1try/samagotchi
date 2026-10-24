# frozen_string_literal: true

require_relative "link_codes"
require_relative "principal"
require_relative "public_url"
require_relative "../log"
require_relative "../proxy_trace"

module Samagotchi
  module Web
    # chi web behind an auth proxy (web.public_url), mixed into App. With a
    # PublicUrl every request needs a token (this machine's too: a proxy
    # with no trace and a rewritten Host looks local). A request is
    # *proxied* when it carries a proxy trace (ProxyTrace: X-Forwarded-*,
    # Forwarded, X-Real-IP, a known identity header…), the configured
    # identity header, or the public Host. A proxied request:
    # - is the owner with the owner token, and, when web.proxy.identity_header
    #   is set, only if that header is one clean value equal to
    #   web.proxy.owner (D-a: identity AND token);
    # - is a participant with a live grant's token (a grant bound to an
    #   identity only for that identity, and only proxied);
    # - else nil: the gate's 401, its reason in the detail (only the
    #   requester's own identity) and the log.
    # The identity header is refused when repeated, with a comma, empty, or
    # sent under two names or with an underscore: WEBrick folds
    # X_Forwarded_Email into the same Rack key as X-Forwarded-Email, the
    # last one winning, so the gate reads the raw names (RawHeaderNames,
    # installed by Server). See docs/configuration.md "Behind an auth proxy".
    module ProxyGate
      # The header names a request came with, as WEBrick read them
      # (lower-cased, "_" kept), in the Rack env. Prepended to
      # WEBrick::HTTPRequest by Server.
      module RawHeaderNames
        def meta_vars
          super.merge(RAW_NAMES_ENV => header.keys)
        end
      end

      RAW_NAMES_ENV = "samagotchi.raw_header_names"
      # Why the gate refused a proxied request, for the 401's detail.
      REFUSED_ENV = "samagotchi.proxy_refused"
      # The token cookie on a proxied (https) request: host-only, Secure,
      # Path=/ (a sibling port on the same domain can't set or read it).
      SECURE_COOKIE = "__Host-chi_token"

      private

      def init_proxy_gate(public_url, token)
        @public_url = public_url
        @public_token = token
        @link_codes = LinkCodes.for_grants(@grants.path)
        @proxy_hint_mutex = Mutex.new
        @proxy_hint_logged = false
      end

      def proxied?(req)
        return false unless @public_url

        env = req.env
        return true if @public_url.host?(env["HTTP_HOST"])
        return true if @public_url.identity_env && env.key?(@public_url.identity_env)

        names = env[RAW_NAMES_ENV] || env.keys.filter_map { |key| ProxyTrace.env_name(key) }
        names.any? { |name| ProxyTrace.header?(name) }
      end

      # [:ok, email] | [:none, nil] | [:bad, reason]: the configured identity
      # header of a proxied request; :none without one configured.
      def proxy_identity(req)
        env_key = @public_url.identity_env
        return [:none, nil] unless env_key

        raw = req.env[RAW_NAMES_ENV]
        return [:bad, "the server gave no raw header names to check the identity header against"] unless raw

        names = raw.select { |name| PublicUrl.env_key(name) == env_key }.uniq
        return [:bad, "identity header sent under #{names.size} names (#{names.join(", ")})"] if names.size > 1
        return [:bad, "identity header sent with an underscore (#{names.first})"] if names.first&.include?("_")

        value = req.env[env_key]
        return [:none, nil] if value.nil?
        return [:bad, "identity header not among the raw header names"] if names.empty?

        value = value.strip
        return [:bad, "identity header empty"] if value.empty?
        return [:bad, "identity header repeated or with a comma"] if value.include?(",")

        [:ok, value.downcase]
      end

      # The principal of a proxied request, or nil (the reason in the env).
      def proxied_principal(req, given)
        state, identity = proxy_identity(req)
        return proxy_refuse(req, identity) if state == :bad

        notice_identity_headers(req) if state == :none
        shown = identity || "(none)"
        if owner_token?(given)
          return Principal::OWNER if @public_url.identity_env.nil?
          return Principal::OWNER if @public_url.owner && identity == @public_url.owner

          return proxy_refuse(req, "owner token with identity #{shown}#{identity_hint(req)}")
        end
        grant_tokens = given.select { |value| Grants.token?(value) }
        return proxy_refuse(req, "no token (identity #{shown})") if grant_tokens.empty?

        participant_principal(req, grant_tokens, identity: identity, proxied: true)
      end

      # chi's own probe of a chi web behind a proxy (InfoProbe: a second chi
      # web, chi share, chi update) sends no token: GET /api/info from this
      # machine, not through the proxy, with no token at all, gets the
      # fields it checks (nothing secret), so no probe ever hands the token
      # to whatever listens on the port.
      def probe_info?(req)
        return false unless @public_url && req.get? && req.path_info == "/api/info"
        return false unless App::LOOPBACK_PEERS.include?(req.get_header("REMOTE_ADDR").to_s) && !proxied?(req)

        req.get_header("HTTP_AUTHORIZATION").nil? && req.get_header("HTTP_COOKIE").nil?
      end

      def probe_info
        json_response(200, { app: "chi-web", version: Samagotchi::VERSION, pid: Process.pid, features: App::INFO_FEATURES,
                             lan: @lan && @lan[:ip] })
      end

      def proxy_refuse(req, reason)
        req.env[REFUSED_ENV] = reason
        nil
      end

      # The known identity headers (ProxyTrace::IDENTITY_HEADERS) a proxied
      # request carries other than the configured one.
      def other_identity_headers(req)
        ProxyTrace::IDENTITY_HEADERS.select do |name|
          key = PublicUrl.env_key(name)
          key != @public_url.identity_env && req.env.key?(key)
        end
      end

      def identity_hint(req)
        return "" if @public_url.identity_env.nil? || req.env.key?(@public_url.identity_env)

        others = other_identity_headers(req)
        others.empty? ? "" : "; the proxy sends #{others.join(", ")}, not #{@public_url.identity_header}"
      end

      # Once per start: a proxied request without the configured identity
      # header (or with none configured) but with a header a known setup
      # puts the identity in. A wrong header locks the owner out, and one the
      # proxy doesn't replace is a client-chosen string: the line says which.
      def notice_identity_headers(req)
        return if @proxy_hint_logged

        others = other_identity_headers(req)
        return if others.empty?
        return unless @proxy_hint_mutex.synchronize { !@proxy_hint_logged && (@proxy_hint_logged = true) }

        if @public_url.identity_env
          Log.warn(:web, "proxy_identity_header", configured: @public_url.identity_header, sent: others.join(","),
                                                  echo: "Warning: chi web: the proxy sends #{others.join(", ")}, not " \
                                                        "web.proxy.identity_header #{@public_url.identity_header}")
        else
          Log.info(:web, "proxy_identity_header", configured: "none", sent: others.join(","),
                                                  echo: "chi web: the proxy sends #{others.join(", ")}; with " \
                                                        "web.proxy.identity_header and web.proxy.owner it is checked " \
                                                        "next to the token (only a header the proxy replaces)")
        end
      end
    end
  end
end
