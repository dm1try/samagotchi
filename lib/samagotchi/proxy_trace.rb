# frozen_string_literal: true

module Samagotchi
  # The request headers a proxy in front of chi adds and chi's own clients
  # never send: chi web takes a request with one as proxied
  # (Web::ProxyGate), a Bridge refuses it (Bridge#browser_request?). Names
  # are compared lower-cased with "_" read as "-", so an underscore twin
  # (X_Forwarded_For) counts too. See docs/configuration.md "Behind an auth
  # proxy".
  module ProxyTrace
    # Any name starting with one of these: X-Forwarded-For/-Host/-Proto/
    # -Email/-User…, oauth2-proxy's X-Auth-Request-*, Cloudflare's Cf-*,
    # Tailscale Serve's Tailscale-User-*, Authentik's X-Authentik-*, Google
    # IAP's X-Goog-*, Azure App Service's X-MS-Client-Principal*, AWS ALB's
    # X-Amzn-Oidc-*, Envoy's X-Envoy-*.
    PREFIXES = %w[x-forwarded- x-auth-request- cf- tailscale- x-authentik- remote- x-goog- x-ms-client-principal
                  x-amzn-oidc- x-envoy- x-original-forwarded-].freeze
    # And these whole names.
    NAMES = %w[forwarded x-real-ip via true-client-ip x-client-ip x-original-url x-original-uri].freeze

    # The identity headers known setups send (docs/configuration.md's
    # table): chi web's hint when the proxy sends one of them but not the
    # one configured.
    IDENTITY_HEADERS = %w[X-Forwarded-Email X-Auth-Request-Email Cf-Access-Authenticated-User-Email Tailscale-User-Login
                          Remote-Email X-Authentik-Email X-Goog-Authenticated-User-Email X-MS-Client-Principal-Name
                          X-Amzn-Oidc-Identity X-Forwarded-User X-Auth-Request-User Remote-User].freeze

    module_function

    # @param name [String] a header's name as sent (any case, - or _)
    def header?(name)
      key = normalize(name)
      NAMES.include?(key) || PREFIXES.any? { |prefix| key.start_with?(prefix) }
    end

    def normalize(name) = name.to_s.downcase.tr("_", "-")

    # The header name of a Rack env key (HTTP_X_FORWARDED_FOR →
    # x-forwarded-for), nil for a key that isn't a header's.
    def env_name(key)
      key = key.to_s
      key.start_with?("HTTP_") ? key.delete_prefix("HTTP_").downcase.tr("_", "-") : nil
    end
  end
end
