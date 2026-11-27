# frozen_string_literal: true

# The mcp bundle's server-config plugin part (manifest.yml plugin: parts:, loaded
# before plugin.rb): a server's config resolved into its command/env/cwd or
# url/headers and digest, and why a config is refused.
require "digest"
require "json"
require "shellwords"
require "uri"

class Plugin
  # The headers chi sets itself on a remote server's requests.
  # The wire's own (host, content-length…) too: one set in config.yml would break every request.
  OWN_HEADERS = %w[accept content-type mcp-protocol-version mcp-method mcp-name mcp-session-id
                   host content-length connection transfer-encoding].freeze

  # The oauth: map's keys (all optional).
  OAUTH_KEYS = %w[client_id issuer client_secret_env scopes redirect_port].freeze

  private

  # The command, env and cwd the server runs with, and their digest (the
  # cache's key: command, args, env names and values, and the cwd; the
  # env itself is never stored).
  def resolve(server, ctx)
    return resolve_url(server) if server.config.key?("url")

    command = server.config["command"]
    command = Shellwords.split(command) if command.is_a?(String)
    server.command = Array(command).map(&:to_s)
    env = server.config["env"].is_a?(Hash) ? server.config["env"] : {}
    server.env = env.to_h { |key, value| [key.to_s, value.to_s] }
    server.cwd = server.config["cwd"] ? File.expand_path(server.config["cwd"].to_s) : ctx.cwd
    server.digest = Digest::SHA256.hexdigest(JSON.generate([server.command, server.env.sort, server.cwd]))
  end

  # A remote server's url, headers, token variable and oauth: map, and
  # their digest (never the token's value: a rotated token isn't a changed
  # config). The oauth: map joins the digest only when it is set: a server
  # without one keeps the digest it had before sign-in came (its cache).
  def resolve_url(server)
    server.command = []
    server.env = server.config["env"].is_a?(Hash) ? server.config["env"].to_h { |k, v| [k.to_s, v.to_s] } : {}
    server.url = server.config["url"].to_s
    server.headers = server.config["headers"].is_a?(Hash) ? server.config["headers"] : {}
    server.token_env = server.config["bearer_token_env"]&.to_s
    server.oauth = server.config["oauth"] if server.config.key?("oauth")
    server.signs_in = server.token_env.nil? && server.headers.keys.none? { |name| name.to_s.casecmp?("authorization") }
    digested = [server.url, server.headers.map { |k, v| [k.to_s, v.to_s] }.sort, server.token_env]
    digested << (server.oauth.is_a?(Hash) ? server.oauth.map { |k, v| [k.to_s, v] }.sort_by(&:first) : server.oauth) if server.config.key?("oauth")
    server.digest = Digest::SHA256.hexdigest(JSON.generate(digested))
  end

  # Why the server's config can't start it, nil when it can.
  def config_error(server)
    where = "bundles: mcp: servers: #{server.name}"
    if server.url && server.config.key?("command")
      return "set command: (a local server) or url: (a remote one), not both (#{where})"
    end
    return url_error(server, where) if server.url

    "no command (#{where}: command: [...] or url: ...)" if server.command.empty?
  end

  def url_error(server, where)
    uri = begin
      URI.parse(server.url)
    rescue URI::Error
      nil
    end
    return "url: must be an http(s) URL (#{where})" unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
    return "bearer_token_env: must name an environment variable (#{where})" if server.token_env&.strip&.empty?
    return "headers: must be a map of names to values (#{where})" unless server.config["headers"].nil? || server.config["headers"].is_a?(Hash)

    server.headers.each do |name, value|
      unless name.is_a?(String) && value.is_a?(String) && name.match?(/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/) &&
             !value.match?(/[\r\n\0]/)
        return "headers: #{name.to_s[0, 40].inspect} must be a name and a one-line text value (#{where})"
      end
      if OWN_HEADERS.include?(name.downcase) || (server.token_env && name.casecmp?("authorization"))
        return "headers: #{name} is chi's to set (#{where})"
      end
    end
    oauth_error(server, where) if server.config.key?("oauth")
  end

  # Why a remote server's oauth: map can't be used, nil when it can: a
  # client registered by hand is bound to its provider (issuer:), and a
  # server signs in or has a static token, never both.
  def oauth_error(server, where)
    oauth = server.oauth
    return "oauth: must be a map (#{where})" unless oauth.is_a?(Hash)
    return "oauth: and bearer_token_env: are one or the other (#{where})" if server.token_env
    if server.headers.keys.any? { |name| name.to_s.casecmp?("authorization") }
      return "oauth: and an Authorization header are one or the other (#{where})"
    end

    unknown = oauth.keys.map(&:to_s) - OAUTH_KEYS
    return "oauth: #{unknown.first[0, 40]} isn't one of #{OAUTH_KEYS.join(", ")} (#{where})" unless unknown.empty?

    id = oauth["client_id"]
    return "oauth: client_id: must be a text (#{where})" if oauth.key?("client_id") && !(id.is_a?(String) && !id.strip.empty?)
    return "oauth: issuer: is required with client_id: (#{where})" if id && !oauth.key?("issuer")
    return "oauth: issuer: goes with client_id: (#{where})" if oauth.key?("issuer") && !id
    return "oauth: issuer: must be an https address (#{where})" if id && !issuer_address?(oauth["issuer"])

    secret_env = oauth["client_secret_env"]
    if oauth.key?("client_secret_env")
      return "oauth: client_secret_env: must name an environment variable (#{where})" unless secret_env.is_a?(String) && !secret_env.strip.empty?
      return "oauth: client_secret_env: goes with client_id: (#{where})" unless id
    end
    scopes = oauth["scopes"]
    if oauth.key?("scopes") && !(scopes.is_a?(Array) && scopes.all? { |scope| scope.is_a?(String) && scope.match?(/\A[!#-\[\]-~]+\z/) })
      return "oauth: scopes: must be a list of scope names (#{where})"
    end

    port = oauth["redirect_port"]
    "oauth: redirect_port: must be a port, 1024 to 65535 (#{where})" if oauth.key?("redirect_port") && !(port.is_a?(Integer) && port.between?(1024, 65_535))
  end

  # An https address with a host (http only on a loopback host: local
  # development), no query or fragment: what an issuer is.
  def issuer_address?(value)
    uri = URI.parse(value.to_s)
    return false unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty? && uri.query.nil? && uri.fragment.nil? && uri.userinfo.nil?

    uri.scheme == "https" || loopback_host?(uri.host)
  rescue URI::Error
    false
  end

  def loopback_host?(host) = %w[127.0.0.1 ::1 [::1] localhost].include?(host.to_s.downcase)

  # A remote server's bearer token (HttpClient's token:), looked up at each
  # request (never kept): the env a stdio server would get (its env:, then
  # the project env: #server_env), then the worker's.
  # @return [HttpClient::StaticToken]
  def token_lookup(server)
    return HttpClient::StaticToken.new { nil } unless server.token_env

    HttpClient::StaticToken.new do
      value = env_value(server, server.token_env).to_s
      raise HttpClient::Refused, "#{server.token_env} is not set" if value.empty?
      # An env file saved with CRLF line ends; a header can't carry it.
      raise HttpClient::Refused, "#{server.token_env} holds a line break: set it on one line" if value.match?(/[\r\n\0]/)

      value
    end
  end

  # +variable+'s value for the server: its env:, the project env, then the
  # worker's; nil when unset or empty.
  def env_value(server, variable)
    value = server_env(server)[variable].to_s
    value = ENV[variable].to_s if value.empty?
    value.empty? ? nil : value
  end
end
