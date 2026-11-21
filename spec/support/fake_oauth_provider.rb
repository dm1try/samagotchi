# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "uri"
require "webrick"

# An OAuth provider for the mcp bundle's sign-in specs (and a smoke run):
# WEBrick on 127.0.0.1, issuer http://127.0.0.1:<port>. It serves a
# protected resource's metadata (/prm, for the MCP server whose url it is
# given), its own metadata, dynamic registration, an authorize endpoint that
# approves at once (a 302 to the redirect_uri with code, state and iss: what
# a browser would follow), a token endpoint that checks the code's PKCE
# verifier, client and resource, and a revocation endpoint. +expires_in+ is
# each token's life; +refresh_answer+, when set, answers the next
# refresh_token grants ({status:, json:}). Tokens are ACCESS-1, ACCESS-2…
# and REFRESH-1… #valid?(token) says whether the MCP server should take
# one. Wrap examples in FakeProviderServer.without_webmock.
class FakeOAuthProvider
  Seen = Data.define(:verb, :path, :params)

  attr_accessor :expires_in, :refresh_answer, :resource

  def self.start(**) = new(**).tap(&:start)

  def initialize(resource: nil, expires_in: 3600)
    @resource = resource
    @expires_in = expires_in
    @mutex = Mutex.new
    @requests = []
    @codes = {}
    @access = []
    @refresh = {}
    @clients = []
    @issued = 0
  end

  def start
    @server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    @server.mount_proc("/") { |req, res| handle(req, res) }
    @thread = Thread.new { @server.start }
    self
  end

  def stop
    @server&.shutdown
    @thread&.join(0.2) || @thread&.kill
  end

  def issuer = "http://127.0.0.1:#{@server.config[:Port]}"
  def challenge = %(Bearer resource_metadata="#{issuer}/prm", scope="read")
  def requests = @mutex.synchronize { @requests.dup }
  def grants = requests.select { |r| r.path == "/token" }.map { |r| r.params["grant_type"] }
  def valid?(token) = @mutex.synchronize { @access.include?(token) }

  private

  def handle(req, res)
    params = req.request_method == "POST" && req.content_type.to_s.include?("json") ? JSON.parse(req.body) : req.query.to_h
    @mutex.synchronize { @requests << Seen.new(verb: req.request_method, path: req.path, params: params) }
    case req.path
    when "/prm" then json(res, resource: @resource, authorization_servers: [issuer])
    when "/.well-known/oauth-authorization-server"
      json(res, issuer: issuer, authorization_endpoint: "#{issuer}/authorize", token_endpoint: "#{issuer}/token",
                registration_endpoint: "#{issuer}/register", revocation_endpoint: "#{issuer}/revoke",
                code_challenge_methods_supported: ["S256"], authorization_response_iss_parameter_supported: true)
    when "/register" then register(params, res)
    when "/authorize" then authorize(params, res)
    when "/token" then token(params, res)
    when "/revoke" then res.status = 200
    else res.status = 404
    end
  end

  def register(params, res)
    id = "client-#{@clients.size + 1}"
    @mutex.synchronize { @clients << [id, params["redirect_uris"]] }
    json(res, { client_id: id }, status: 201)
  end

  def authorize(params, res)
    code = "CODE-#{SecureRandom.hex(4)}"
    @mutex.synchronize { @codes[code] = params }
    res.status = 302
    res["Location"] = "#{params["redirect_uri"]}?#{URI.encode_www_form(code: code, state: params["state"], iss: issuer)}"
  end

  def token(params, res)
    case params["grant_type"]
    when "authorization_code"
      asked = @mutex.synchronize { @codes.delete(params["code"]) }
      challenge = asked && [Digest::SHA256.digest(params["code_verifier"].to_s)].pack("m0").tr("+/", "-_").delete("=")
      ok = asked && challenge == asked["code_challenge"] && asked["client_id"] == params["client_id"] &&
           asked["redirect_uri"] == params["redirect_uri"] && params["resource"] == @resource
      return json(res, { error: "invalid_grant" }, status: 400) unless ok

      issue(res)
    when "refresh_token"
      if (answer = @mutex.synchronize { @refresh_answer })
        return json(res, answer[:json], status: answer[:status])
      end

      known = @mutex.synchronize { @refresh.delete(params["refresh_token"]) } # rotated: each one once
      return json(res, { error: "invalid_grant" }, status: 400) unless known

      issue(res)
    else json(res, { error: "unsupported_grant_type" }, status: 400)
    end
  end

  def issue(res)
    access, refresh = @mutex.synchronize do
      @issued += 1
      pair = ["ACCESS-#{@issued}", "REFRESH-#{@issued}"]
      @access << pair[0]
      @refresh[pair[1]] = true
      pair
    end
    json(res, access_token: access, token_type: "Bearer", refresh_token: refresh, expires_in: @expires_in)
  end

  def json(res, body = nil, status: 200, **fields)
    res.status = status
    res["Content-Type"] = "application/json"
    res.body = JSON.generate(body || fields)
  end
end
