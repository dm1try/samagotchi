# frozen_string_literal: true

# The mcp bundle (docs/bundles.md, The mcp bundle): tools from MCP servers.
# Each server in config.yml runs as a child process (stdio) for the
# session's life, or is a remote one reached over HTTP (url:, HttpClient).
# Its tools aren't declared one by one: the bundle
# publishes them into chi's tool index (chi.tool_source, a group per
# server), and the model has the index's two fixed tools, find_tools (a
# keyword search that answers each match's inputSchema) and call_tool (calls
# one as <server>/<tool>, which the index hands back to #call here). The
# request's tools never change with the servers', so the prompt cache keeps.
#
#   bundles:
#     mcp:
#       timeout: 60            # seconds per tool call (default 60)
#       startup_timeout: 10    # seconds for initialize and tools/list (default 10)
#       servers:
#         everything:
#           command: [npx, -y, "@modelcontextprotocol/server-everything"]
#           env: {DEBUG: "0"}   # added to chi's environment
#           cwd: ~/scratch      # default: where chi runs
#           tools: [echo, add]  # optional: only these (globs work)
#           description: adds and echoes  # optional: its line in find_tools
#           timeout: 120        # optional: this server's per-call timeout
#           attach_image_paths: true  # default: an image path in the text, in the
#                                     # temp dir or cwd, attaches it
#         context7:
#           url: https://mcp.context7.com/mcp  # a remote server: url instead of command
#           bearer_token_env: CONTEXT7_TOKEN   # optional: Authorization: Bearer <its value>
#           headers: {X-Example: "1"}          # optional, sent as given (not for secrets)
#         linear:
#           url: https://mcp.linear.app/mcp    # no static token: a 401 offers sign-in
#           oauth: {client_id: x, issuer: https://id.example}  # optional: a client of yours
#       client_metadata_url: https://…/client.json  # optional: chi's client document (CIMD)
#
# A remote server with no static token that answers 401 needs sign-in:
# /mcp login NAME signs in (OAuth, oauth.rb), /mcp logout NAME forgets it.
#
# Image blocks in a result go to the model as images (the text keeps
# "[image 1: image/png]"); so does an image file named in a text block,
# under the system temp dir or the server's cwd: the block is only its
# absolute path (chrome-devtools-mcp --slim answers a screenshot that way),
# or it says one ending in an image extension ("Saved it to /tmp/a.png."),
# noted as "[image 1: a.png]".
# A server that doesn't start, answer or list its tools is skipped with a
# notice; the rest of chi works. One that exits mid-session starts again on
# its next call, at most MAX_RESTARTS times a session. /mcp lists the
# servers and their tools, with an estimate of the tokens their
# definitions take (only a search's answer carries them) and of what the
# two tools take in every request.
# Its parts (manifest.yml plugin: parts:, loaded first, in this order):
# client.rb (Client, the stdio JSON-RPC client), http_client.rb (HttpClient),
# oauth.rb (sign-in: OAuth::Login, OAuth::Token),
# tools.rb (the tools/list cache and the tool index) and content.rb (a
# tools/call answer's text and images).
require "digest"
require "json"
require "samagotchi/token_usage"
require "samagotchi/tools/tool_index"
require "samagotchi/tool_declarations"
require "time"
require "shellwords"
require "tmpdir"
require "uri"

class Plugin
  PROTOCOL_VERSION = "2025-06-18"
  CALL_TIMEOUT = 60
  STARTUP_TIMEOUT = 10
  DESCRIPTION_CHARS = 1024
  NAME_CHARS = 48
  # A cached tool list older than this is refreshed in the background.
  CACHE_TTL = 24 * 60 * 60
  # Restarts of a server that exited, per session.
  MAX_RESTARTS = 3
  # The states whose server's tools call_tool can reach (a cached or exited
  # server starts on the call).
  OFFERED = %i[running cached exited].freeze

  # One tool of a server in the index (the tools: filter applied): +name+
  # is the server's, +chi_name+ mcp_<server>_<tool> (what guardrail rules
  # match, and a name call_tool takes too), +schema+ its inputSchema (an
  # empty object when it has none). +error+ is why it can't be called (a
  # bad schema), nil when it can.
  McpTool = Data.define(:server, :name, :chi_name, :description, :schema, :error)

  # One configured server: its service, state and tools. +listed+ is its
  # tools/list as the server answers it (what the cache keeps), +info+ the
  # first sentence of its initialize instructions (cached too), +tools+
  # its index (McpTool each; #index swaps in a whole new list), +tokens+
  # their definitions' estimated size (#definition_tokens).
  # +client+ is the running process's (a restart replaces it; the
  # service's stop closes the current one), +restarts+ how many it had.
  # +url+, +headers+ and +token_env+ are a remote server's (nil for stdio),
  # +oauth+ its oauth: map as given (nil without one). +signs_in+: a remote
  # server with no static token (bearer_token_env, an Authorization
  # header), whose 401 offers sign-in; +token+ the token its HttpClient
  # sends (OAuth::Token, else HttpClient::StaticToken); +card_shown+ its
  # "needs sign-in" card was shown in this worker; +refused+ the digest of
  # the kept token it last needed sign-in with (not tried again).
  Server = Struct.new(:name, :config, :service, :state, :error, :tools, :listed, :timeout, :cwd, :command, :env,
                      :digest, :cached_at, :relist, :relisting, :client, :restarts, :tokens, :info, :url, :headers,
                      :token_env, :oauth, :signs_in, :token, :card_shown, :refused, keyword_init: true) do
    # Its state and tools, never the env (values often a token), the
    # command's args (which may carry a token too), a URL's path or query
    # or a header's value: a failing spec or a debugger would print those.
    # `command` and `env` are nil before the server is resolved.
    def inspect
      where = url ? "url=#{HttpClient.origin(url)} headers=#{(headers || {}).keys.join(",")}" : "command=#{Array(command).first}"
      "#<Server #{name} state=#{state} #{where} env=#{(env || {}).keys.join(",")} tools=#{Array(tools).size}>"
    end

    # How a start that failed is said: a remote server didn't connect.
    def failed_word = url ? "didn't connect" : "didn't start"

    def pretty_print(printer) = printer.text(inspect)
  end

  def initialize(settings = {})
    @settings = settings
    @timeout = positive(settings["timeout"]) || CALL_TIMEOUT
    @startup_timeout = positive(settings["startup_timeout"]) || STARTUP_TIMEOUT
    @servers = []
    @relist = Mutex.new
    @restart = Mutex.new
    # The tools that can't be called (a bad schema): said once, not at each
    # index.
    @left_out = []
    @left_out_lock = Mutex.new
    @publish = Mutex.new
    # Sign-ins: each server's waiting /mcp login thread, the "needs sign-in"
    # cards a participant's turn held back, the providers that refused
    # chi's client document (this worker only), and the controller the
    # sign-ins' threads stop on (the plugin's shutdown).
    @sign_ins = {}
    @sign_in_lock = Mutex.new
    @held_cards = []
    @cimd_refused = {}
    @sign_in_cancel = Samagotchi::CancellationController.new
  end

  # The servers' names, never @settings (the raw servers config, env values
  # included): a failing spec prints the plugin.
  def inspect = "#<Plugin mcp servers=#{@servers.map(&:name).join(",")}>"

  def pretty_print(printer) = printer.text(inspect)

  # Each server's tools come from its cache (tools-<server>.json in the
  # bundle's data dir, keyed by a digest of its config) when there is one:
  # the server then starts on the first call of one of its tools (start:
  # lazy, the default), and a cache older than a day is refreshed quietly
  # in the background. Without a cache (the first run, a changed config)
  # the server starts in an init task (chi.init) that every UI shows; a
  # turn sent meanwhile waits for its tools. start: eager starts it with
  # every session. With a server configured the bundle is a tool source:
  # chi declares find_tools and call_tool once, after the plugins load,
  # from what #publish gave by then; nothing the servers do later changes
  # them, only what a search answers.
  def register(chi)
    @chi = chi
    ctx = chi.ctx
    @ctx = ctx
    configs = @settings["servers"]
    configs = {} unless configs.is_a?(Hash)
    unless configs.empty?
      @source = chi.tool_source(label: "mcp", prefix: "mcp_", call: ->(tool, args, call_ctx) { run(tool, args, call_ctx) },
                                acts_as: ->(server, tool) { tool_name(server, tool) },
                                wait: ->(server) { wait_started(@servers.find { |s| s.name == server }) })
    end
    @servers = configs.map do |name, config|
      server = Server.new(name: name.to_s, config: config.is_a?(Hash) ? config : {}, state: :starting, tools: [],
                          restarts: 0, tokens: 0)
      server.timeout = positive(server.config["timeout"]) || @timeout
      resolve(server, ctx)
      server.token = token_of(server, ctx) if server.url
      server.service = chi.service(name) { |svc| start(server, svc, ctx) }
      server
    end
    @servers.each do |server|
      # Two startup_timeouts: initialize, then tools/list; four for a remote
      # server (discover, initialize, initialized, tools/list).
      wait = @startup_timeout * (server.url ? 4 : 2)
      # A failure's card title, short: the card shows "mcp" beside it and
      # the error in its body.
      failed = "#{server.name} #{server.failed_word}"
      if load_cache(server, ctx)
        index(server, ctx)
        if server.config["start"].to_s == "eager"
          chi.init("Starting MCP server #{server.name}", timeout: wait, failed: failed) { boot(server, ctx) }
        elsif server.cached_at.nil? || Time.now - server.cached_at > CACHE_TTL
          chi.init("Refreshing MCP server #{server.name}'s tools", quiet: true, timeout: wait,
                                                                   failed: "#{server.name}'s tools weren't refreshed") do
            refresh(server, ctx)
          end
        end
      else
        why = File.exist?(cache_path(server, ctx)) ? "config changed" : "first run"
        chi.init("Starting MCP server #{server.name} (#{why}, saving its tools)", provides_tools: true, timeout: wait,
                                                                                   failed: failed) do
          boot(server, ctx)
        end
      end
    end
    publish
    # The sign-ins' stop seat: chi stops its services as it leaves.
    chi.service("(sign-ins)", eager: true) { |svc| svc.on_stop { stop_sign_ins } }
    chi.on(:after_turn) { |_event, hook_ctx| show_held_cards(hook_ctx) unless hook_ctx.turn_author }
    chi.command "/mcp", "list the MCP servers (login NAME, logout NAME: sign in to or out of a remote one)",
                anytime: true do |args, command_ctx|
      mcp_command(args, command_ctx)
    end
  end

  # chi's client metadata document (CIMD: its client_id at a provider that
  # takes one), pages/oauth/client.json in chi's repository once GitHub
  # Pages serves it there. Not the default yet: a provider fetches it during
  # the sign-in, so an address that isn't live would fail in the browser.
  # bundles: mcp: client_metadata_url: sets one (this one, or your own).
  CLIENT_METADATA_DOCUMENT = "https://dm1try.github.io/samagotchi/oauth/client.json"
  CLIENT_METADATA_URL = nil

  # /mcp's one line for a word it doesn't know.
  USAGE = "usage: /mcp (lists the servers), /mcp login NAME, /mcp logout NAME"

  private

  # /mcp: no word lists the servers (a card); login / logout NAME sign in
  # to or out of a remote server; another word answers USAGE.
  def mcp_command(args, ctx)
    show_held_cards(ctx)
    word, name, extra = args.to_s.split(/\s+/, 3)
    case word
    when nil
      ctx.card(title: "MCP servers", body: listing, id: "mcp-servers")
      nil
    when "login", "logout"
      return "usage: /mcp #{word} NAME" if name.nil? || extra

      word == "login" ? login(name, ctx) : logout(name, ctx)
    else USAGE
    end
  end

  # ── Sign-in (the OAuth in oauth.rb; here its wiring) ──────────────────

  # Why /mcp login|logout can't act on server +name+, nil when it can.
  def sign_in_refusal(name)
    server = @servers.find { |s| s.name == name }
    return "no MCP server #{name}#{" (#{@servers.map(&:name).join(", ")})" unless @servers.empty?}" unless server
    return "#{name} is a local server: sign-in is for remote ones (url:)" unless server.url
    return "#{name} has a static token (bearer_token_env: or an Authorization header): it doesn't sign in" unless server.signs_in
    return "#{name}'s url: has a query: chi can't sign in to it (it would go out with the sign-in)" if URI.parse(server.url).query

    config_error(server)
  end

  # /mcp login NAME: answers at once; discovery, the client, the flow and
  # the exchange run on a thread of the plugin's (OAuth::Login), whose
  # result or error replaces the flow's card.
  def login(name, ctx)
    refusal = sign_in_refusal(name)
    return refusal if refusal
    return "sign-in needs the web or a terminal: this run is one-shot" if ctx.frontend == :one_shot
    if @settings.key?("client_metadata_url") && client_metadata_url.nil?
      return "bundles: mcp: client_metadata_url: must be an https address with a path (chi's client document)"
    end
    return "this chi can't sign in (it has no ctx.sign_in)" unless ctx.respond_to?(:sign_in) && ctx.respond_to?(:secrets)

    server = @servers.find { |s| s.name == name }
    return "#{name} is signed in already (from another session): connected." if signed_in_elsewhere?(server, ctx)

    started = @sign_in_lock.synchronize do
      next false if @sign_ins[name]&.alive? || @sign_in_cancel.cancelled?

      @sign_ins[name] = Thread.new { sign_in(server, ctx) }
    end
    return "a sign-in to #{name} is already waiting: finish it in the browser, or let it time out" unless started

    "Opening sign-in for #{name}…"
  end

  # The login's thread: every error ends on a card, never raised into nothing.
  def sign_in(server, ctx)
    login = OAuth::Login.new(ctx: ctx, server: server, secret_lookup: ->(name) { env_value(server, name) },
                             client_metadata_url: client_metadata_url, cimd_refused: @cimd_refused, cancel: @sign_in_cancel,
                             log: ->(event, **fields) { ctx.log.info("mcp_#{event}", **fields) })
    card_id = login.run
    signed_in(server, card_id, ctx) if card_id
  rescue OAuth::Refusal => e
    ctx.log.warn("mcp_sign_in_failed", server: server.name, error: e.class.name)
    ctx.card(id: e.card_id, title: "Sign-in to #{server.name} failed", body: e.message, level: :warn, between_turns: true)
  rescue StandardError => e
    ctx.log.warn("mcp_sign_in_failed", server: server.name, error: e.class.name)
    ctx.card(title: "Sign-in to #{server.name} failed", body: "chi's sign-in broke (#{e.class.name}); the debug log has it",
             level: :warn, between_turns: true)
  end

  # Kept: the server connects as a lazy start does (handshake, tools/list,
  # the cache), with spawn directly when its service already runs (a 401
  # met during a call, a sign-out), then the flow's card says so.
  def signed_in(server, card_id, ctx)
    server.token.forget
    begin
      reconnect(server, ctx)
      count = offered(server).size
      ctx.card(id: card_id, title: "Signed in to #{server.name}", body: "#{count} tool#{"s" unless count == 1}, ready to use.",
               between_turns: true)
    rescue StandardError => e
      if needs_sign_in?(server, e)
        signed_out(server, ctx, e)
        return
      end

      ctx.log.warn("mcp_server_failed", server: server.name, error: e.class.name, msg: e.message, signed_in: true)
      ctx.card(id: card_id, title: "Signed in, but #{server.name} didn't connect", body: e.message, level: :warn,
               between_turns: true)
    end
  end

  # Connect a server that has a sign-in now (spawn when its service
  # already runs, else its first start), then it runs; its "needs sign-in"
  # card loses its button (a later refusal shows it again).
  def reconnect(server, ctx)
    @restart.synchronize do
      if server.service.state == :running
        old = server.client
        spawn(server, ctx, cancelled: @sign_in_cancel)
        old.close unless old.equal?(server.client)
      else
        server.service.value
      end
      @sign_in_lock.synchronize do
        server.state = :running
        server.error = nil
      end
    end
    publish
    return unless @sign_in_lock.synchronize { server.card_shown.tap { server.card_shown = false } }

    ctx.card(id: "mcp-sign-in-#{server.name}", title: "#{server.name} needs sign-in", body: "Signed in since.", between_turns: true)
  end

  # A server that needs sign-in, signed in to meanwhile from another
  # session (the kept token, read again): connected now. False when there
  # is no kept token, or it doesn't connect.
  def signed_in_elsewhere?(server, ctx)
    return false unless server.state == :needs_sign_in && server.token.respond_to?(:kept)

    server.token.forget
    kept = kept_digest(server)
    return false if kept.nil? || kept == server.refused

    reconnect(server, ctx)
    ctx.log.info("mcp_signed_in_elsewhere", server: server.name)
    true
  rescue StandardError => e
    server.refused = kept_digest(server) # what it holds after a renew, too: not tried again
    ctx.log.warn("mcp_server_failed", server: server.name, error: e.class.name, msg: e.message, signed_in_elsewhere: true)
    false
  end

  # 16 hex of the SHA-256 of the kept access token, nil without one.
  def kept_digest(server)
    kept = server.token.respond_to?(:kept) && server.token.kept
    kept ? Digest::SHA256.hexdigest(kept["access_token"])[0, 16] : nil
  rescue StandardError
    nil
  end

  # Whether the kept sign-in is newer than the token +error+ refused (or,
  # none sent, whether there is one now): another session or a login
  # signed in after the request went out.
  def newer_sign_in?(server, error)
    kept = server.token.respond_to?(:kept) && server.token.kept
    return false unless kept

    error.sent_digest.nil? || Digest::SHA256.hexdigest(kept["access_token"])[0, 16] != error.sent_digest
  rescue StandardError
    false
  end

  # /mcp logout NAME: the kept token goes (the provider's revocation asked,
  # best effort), the client closes, the server needs sign-in. chi's
  # registration with the provider stays.
  def logout(name, ctx)
    refusal = sign_in_refusal(name)
    return refusal if refusal

    server = @servers.find { |s| s.name == name }
    kept = server.token.kept
    ctx.secrets.delete(server.token.name)
    server.token.forget
    OAuth.revoke(ctx.http, kept, log: ->(event, **fields) { ctx.log.info("mcp_#{event}", server: name, **fields) }) if kept
    server.client&.close
    server.state = :needs_sign_in
    publish
    "Signed out of #{name}."
  rescue Samagotchi::Plugin::Secrets::Unavailable, Samagotchi::Plugin::Secrets::Busy => e
    "#{name}'s sign-in wasn't forgotten: #{e.message}"
  end

  # Whether +error+ means the server wants a sign-in: a 401 from one that signs in.
  def needs_sign_in?(server, error) = server.signs_in && error.is_a?(HttpClient::Refused) && error.status == 401

  # The server needs sign-in: its state (said once), its card, and the
  # line its call answers.
  # Nil when +error+ (the 401) was for an older token than the kept one: the
  # state stays, the next request sends the new token.
  def signed_out(server, ctx, error = nil)
    if error && newer_sign_in?(server, error)
      server.token.forget
      return nil
    end

    first = @sign_in_lock.synchronize { server.state == :needs_sign_in ? false : (server.state = :needs_sign_in) }
    if first
      server.refused = kept_digest(server)
      server.error = nil
      publish
      ctx.log.info("mcp_needs_sign_in", server: server.name)
    end
    offer_sign_in(server, ctx)
    "Error: #{sign_in_line(server, ctx.turn_author)}"
  end

  # What a call of a server that needs sign-in answers: the owner's
  # command, or (a participant's turn) who signs in, no command.
  def sign_in_line(server, author = nil)
    return "#{server.name} needs sign-in: the session's owner signs in" if author

    "#{server.name} needs sign-in: the user runs /mcp login #{server.name}"
  end

  # The "needs sign-in" card, once per server per worker, never a turn's;
  # none on a one-shot; on a participant's turn held for the owner's next
  # turn end or command.
  def offer_sign_in(server, ctx)
    return if ctx.frontend == :one_shot

    if ctx.turn_author
      @sign_in_lock.synchronize { @held_cards << server.name unless @held_cards.include?(server.name) }
      return
    end
    first = @sign_in_lock.synchronize { server.card_shown ? false : (server.card_shown = true) }
    return unless first

    ctx.card(id: "mcp-sign-in-#{server.name}", title: "#{server.name} needs sign-in",
             body: "The server asks chi to sign in. Sign in opens its provider's page in your browser.",
             actions: [{ label: "Sign in", command: "/mcp login #{server.name}" }], between_turns: true)
  end

  def show_held_cards(ctx)
    names = @sign_in_lock.synchronize { @held_cards.slice!(0..) }
    names.each do |name|
      server = @servers.find { |s| s.name == name }
      offer_sign_in(server, ctx) if server&.state == :needs_sign_in
    end
  end

  # chi's client document's address (bundles: mcp: client_metadata_url:,
  # else CLIENT_METADATA_URL): an https address with a path, else nil.
  def client_metadata_url
    value = @settings.fetch("client_metadata_url", CLIENT_METADATA_URL)
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty? && uri.path.to_s.length > 1 && uri.userinfo.nil? ? value.to_s : nil
  rescue URI::Error
    nil
  end

  # The service's stop: the waiting sign-ins end (core stops their flows
  # too), their threads get a moment to put their cards right.
  def stop_sign_ins
    @sign_in_cancel.cancel!
    threads = @sign_in_lock.synchronize { @sign_ins.values }
    threads.each { |thread| thread.join(2) }
  end

  # A remote server's token object: OAuth::Token for one that signs in
  # (with this chi's ctx.secrets), else the static one.
  def token_of(server, ctx)
    return token_lookup(server) unless server.signs_in && ctx.respond_to?(:secrets)

    oauth = server.oauth.is_a?(Hash) ? server.oauth : {}
    variable = oauth["client_secret_env"]
    client = oauth["client_id"] ? { id: oauth["client_id"], issuer: oauth["issuer"] } : nil
    OAuth::Token.new(secrets: ctx.secrets, resource: URI.parse(server.url).query ? nil : OAuth.canonical(server.url),
                     http: ctx.http, client: client, client_secret: -> { variable && env_value(server, variable) },
                     log: ->(event, **fields) { ctx.log.info("mcp_#{event}", server: server.name, **fields) })
  end

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

  # The headers chi sets itself on a remote server's requests.
  # The wire's own (host, content-length…) too: one set in config.yml would break every request.
  OWN_HEADERS = %w[accept content-type mcp-protocol-version mcp-method mcp-name mcp-session-id
                   host content-length connection transfer-encoding].freeze

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

  # The oauth: map's keys (all optional).
  OAUTH_KEYS = %w[client_id issuer client_secret_env scopes redirect_port].freeze

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

  # A client's cancelled:, read on the thread that does the work (an init
  # task's own Stop, else the turn's; a thread of the client's own would
  # read the turn's): a remote server's ctx.http cancel:, a poll for stdio.
  def stop_of(server, ctx) = server.url ? ctx.cancel_controller : -> { ctx.cancelled? }

  # The log fields that say which client: its pid, or a remote one's origin.
  def where(client) = client.is_a?(HttpClient) ? { where: client.label } : { pid: client.pid }

  # The one place a server's client is built (spawn's and refresh's); it
  # is the caller's, never assigned here.
  def connect(server, ctx, **callbacks)
    if server.url
      return HttpClient.new(server.url, headers: server.headers, token: server.token || token_lookup(server), http: ctx.http,
                                        log: ->(event, **fields) { ctx.log.debug("mcp_#{event}", server: server.name, **fields) })
    end

    Client.new(server.command, env: server_env(server), cwd: server.cwd,
                               log: ->(event, **fields) { ctx.log.debug("mcp_#{event}", server: server.name, **fields) },
                               **callbacks)
  end

  # The service's start: spawn (#spawn). Its stop closes the server's
  # current process, a restarted one too.
  def start(server, svc, ctx)
    error = config_error(server)
    raise Client::Error, error if error

    svc.on_stop { server.client&.close }
    spawn(server, ctx)
  end

  # Spawn the server's process (it is server.client from then on),
  # initialize, list the tools (cancelled with the turn that waits for
  # it), then cache the list and its info when either changed, and index
  # the tools.
  # @return [Client]
  def spawn(server, ctx, cancelled: stop_of(server, ctx))
    client = server.client = connect(server, ctx,
                                     on_exit: ->(reason) { exited(server, reason, ctx) },
                                     on_notification: lambda { |method, _params|
                                       tools_changed(server, ctx) if method == "notifications/tools/list_changed"
                                     })
    initialized = client.handshake(timeout: @startup_timeout, cancelled: cancelled)
    listed = list_tools(client, cancelled)
    info = info_of(initialized)
    changed = listed != server.listed || info != server.info
    server.listed = listed
    server.info = info
    save_cache(server, ctx) if changed
    index(server, ctx)
    client
  end

  # A server's env: the session's project env as execute's commands get it
  # (the worker's mise env without chi's own Ruby and Bundler setup, on a
  # chi that has it: Samagotchi::ProjectEnv.spawn_env) under the server's
  # own keys. An older chi has only the overlay, or none.
  def server_env(server)
    project = if !defined?(Samagotchi::ProjectEnv) then {}
              elsif Samagotchi::ProjectEnv.respond_to?(:spawn_env) then Samagotchi::ProjectEnv.spawn_env
              else Samagotchi::ProjectEnv.current.env
              end
    project.merge(server.env)
  end

  # The first sentence of initialize's instructions (at most
  # DESCRIPTION_CHARS), nil when there are none.
  def info_of(result)
    text = result["instructions"].to_s.strip.gsub(/\s+/, " ")
    return nil if text.empty?

    sentence = text[/\A.*?[.!?](?=\s|\z)/] || text
    sentence.length > DESCRIPTION_CHARS ? "#{sentence[0, DESCRIPTION_CHARS - 1]}…" : sentence
  end

  # Start a server in an init task; its tools replace the cached ones in
  # the index (or come for the first time: #spawn indexes them).
  # @return [String] the task's summary
  # @raise [Client::Error] it didn't start (the task's warn card says why;
  #   the index keeps its tools, marked failed; a remote server's from the
  #   cache stay cached, as #not_connected leaves them)
  def boot(server, ctx)
    cached = server.state == :cached
    client = server.service.value
    server.state = :running
    publish
    ctx.log.info("mcp_server_started", server: server.name, **where(client), tools: server.listed.size)
    count = server.listed.size
    "#{server.name} ready, #{count} tool#{"s" unless count == 1}"
  rescue StandardError => e
    if needs_sign_in?(server, e)
      return "#{server.name} was signed in to meanwhile: its next call connects" unless signed_out(server, ctx, e)

      return "#{server.name} needs sign-in (/mcp login #{server.name})"
    end
    if cached && server.url
      ctx.log.warn("mcp_server_failed", server: server.name, error: e.class.name, msg: e.message)
      server.error = e.message # its first call failing the same way says nothing new
      raise Client::Error, "MCP server #{server.name} didn't connect: #{e.message}; its next call tries again"
    end
    server.state = :failed
    server.error = e.message
    publish
    ctx.log.warn("mcp_server_failed", server: server.name, error: e.class.name, msg: e.message)
    raise Client::Error, "MCP server #{server.name} #{server.failed_word}: #{e.message}; its calls fail until chi restarts"
  end

  # The quiet daily refresh of a cached server's list: a server of its own
  # (not the session's: that one still starts on the first call), listed
  # and stopped. The cache is rewritten (its clock too) and a changed list
  # replaces the indexed tools. One worker at a time (a lock file); the
  # others skip.
  def refresh(server, ctx)
    File.open("#{cache_path(server, ctx)}.lock", File::CREAT | File::RDWR) do |lock|
      return nil unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      cancelled = stop_of(server, ctx)
      client = connect(server, ctx)
      begin
        initialized = client.handshake(timeout: @startup_timeout, cancelled: cancelled)
        listed = list_tools(client, cancelled)
      ensure
        client.close
      end
      # Started meanwhile: its own list is the fresh one.
      return nil unless server.state == :cached

      changed = listed != server.listed
      server.listed = listed
      server.info = info_of(initialized)
      save_cache(server, ctx)
      ctx.log.info("mcp_tools_refreshed", server: server.name, tools: listed.size, changed: changed)
      index(server, ctx) if changed
    end
    nil
  rescue HttpClient::Refused => e
    raise unless needs_sign_in?(server, e)

    signed_out(server, ctx, e) if server.state == :cached
    nil
  end

  # notifications/tools/list_changed from a running server: list its tools
  # again (on a thread of its own: the answer comes on the reader thread
  # that told us), save them and index them.
  # Notices that come together list once more after the one running.
  def tools_changed(server, ctx)
    @relist.synchronize do
      server.relist = true
      return if server.relisting

      server.relisting = true
    end
    Thread.new do
      relist(server, ctx) while relist_pending?(server)
    end
  end

  # Takes the server's pending relist: true once per notice; false (and
  # the relisting thread ends) when none is left.
  def relist_pending?(server)
    @relist.synchronize do
      pending = server.relist
      server.relist = false
      server.relisting = false unless pending
      pending
    end
  end

  def relist(server, ctx)
    server.service.value # raises once stopped
    listed = list_tools(server.client, nil)
    return if listed == server.listed

    server.listed = listed
    save_cache(server, ctx)
    ctx.log.info("mcp_tools_changed", server: server.name, tools: listed.size)
    index(server, ctx)
  rescue StandardError => e
    ctx.log.warn("mcp_tools_not_relisted", server: server.name, error: e.class.name, msg: e.message)
  end

  # tools/list, every page.
  def list_tools(client, cancelled)
    tools = []
    cursor = nil
    20.times do
      result = client.request("tools/list", cursor ? { cursor: cursor } : nil, timeout: @startup_timeout,
                                                                             cancelled: cancelled)
      tools.concat(Array(result["tools"]).select { |tool| tool.is_a?(Hash) && tool["name"] })
      cursor = result["nextCursor"]
      break unless cursor
    end
    tools
  end

  # ── Calls ─────────────────────────────────────────────────────────────

  # A call the index looked up and checked (call_tool): +tool+ a
  # ToolIndex::Tool, +args+ typed by its schema.
  def run(tool, args, ctx)
    server = @servers.find { |s| s.name == tool.group }
    return "Error: no MCP server #{tool.group}" unless server

    call(server, tool, args, ctx)
  end

  # Wait for a first-run server's start (its init task's); a failure is
  # its init card's.
  def wait_started(server)
    return signed_in_elsewhere?(server, @ctx) if server&.state == :needs_sign_in

    server&.service&.value
  rescue StandardError
    nil
  end

  # mcp_<server>_<tool> in the tool name rule: a-z, 0-9 and _, at most 48.
  def tool_name(server, tool)
    "mcp_#{server}_#{tool}".downcase.gsub(/[^a-z0-9_]+/, "_").squeeze("_")[0, NAME_CHARS].sub(/_+\z/, "")
  end

  def description(tool)
    text = tool["description"].to_s.strip
    text = tool["title"].to_s if text.empty?
    text.length > DESCRIPTION_CHARS ? "#{text[0, DESCRIPTION_CHARS - 1]}…" : text
  end

  # A tools/call of +tool+ (ToolIndex::Tool), as the model's tool result. A cached
  # server starts here, on its first call. The server's isError and a
  # JSON-RPC error answer the tool's inputSchema too (ToolIndex.schema_note).
  def call(server, tool, args, ctx)
    return "Error: MCP server #{server.name} #{server.failed_word}: #{server.error}" if server.state == :failed
    return signed_out(server, ctx) if server.state == :needs_sign_in && !signed_in_elsewhere?(server, ctx)

    client = case server.state
             when :cached then lazy_start(server, ctx)
             when :exited then restart(server, ctx)
             else
               server.service.value # raises once stopped
               server.client
             end
    return client if client.is_a?(String)

    result = client.request("tools/call", { name: tool.name, arguments: args }, timeout: server.timeout,
                                                                                cancelled: stop_of(server, ctx))
    text, images = content(result, server, tool.name)
    return "Error: #{text.empty? ? "the tool failed" : text}#{Samagotchi::Tools::ToolIndex.schema_note(tool)}" if result["isError"]

    images.empty? ? text : Samagotchi::Plugin::ToolResult.new(text, images: images)
  rescue Client::Dead => e
    "Error: MCP server #{server.name} is #{server.url ? "not reachable" : "not running"} (#{e.message})"
  rescue HttpClient::Refused => e
    return "Error: #{e.message}" unless needs_sign_in?(server, e)

    # A sign-in that came while it was on the wire: the call again, once.
    line = signed_out(server, ctx, e)
    retry if line.nil? && (resent = !resent)
    line || "Error: MCP server #{server.name} refused the call (401)"
  rescue Client::Timeout, Client::Cancelled, Client::Unavailable, Samagotchi::Plugin::Service::Stopped => e
    "Error: #{e.message}"
  rescue Client::Error => e
    "Error: #{e.message}#{Samagotchi::Tools::ToolIndex.schema_note(tool)}"
  end

  # Start a cached server for a call (#spawn indexes the live list). A
  # start that fails marks the server failed (one notice; its calls answer
  # at once); a cancelled one leaves it cached for the next call.
  # @return [Client, String] the client, or the call's error text
  def lazy_start(server, ctx)
    client = server.service.value
    started = server.state == :cached
    server.state = :running
    server.error = nil if server.url # the next failure is said again
    publish
    ctx.log.info("mcp_server_started", server: server.name, **where(client), tools: server.listed.size, lazy: true) if started
    client
  rescue Client::Cancelled => e
    "Error: #{e.message}"
  rescue Samagotchi::Plugin::Service::Stopped => e
    "Error: #{e.message}"
  rescue StandardError => e
    raise unless server.state == :cached
    if needs_sign_in?(server, e)
      return signed_out(server, ctx, e) || "Error: MCP server #{server.name} was signed in to meanwhile: call it again"
    end
    return not_connected(server, e, ctx) if server.url

    server.state = :failed
    server.error = e.message
    publish
    ctx.log.warn("mcp_server_failed", server: server.name, error: e.class.name, msg: e.message, lazy: true)
    ctx.notify("MCP server #{server.name} didn't start: #{e.message}; its calls fail until chi restarts", level: :warn)
    "Error: MCP server #{server.name} didn't start: #{e.message}"
  end

  # A remote server that didn't connect stays cached: a network blip or a
  # token the user is about to fix. One notice per distinct message; the
  # next call tries again (the service's start raised, so its next value
  # starts it again).
  def not_connected(server, error, ctx)
    ctx.log.warn("mcp_server_failed", server: server.name, error: error.class.name, msg: error.message, lazy: true)
    text = "MCP server #{server.name} didn't connect: #{error.message}"
    first = @left_out_lock.synchronize { server.error == error.message ? false : (server.error = error.message) }
    ctx.notify("#{text}; its next call tries again", level: :warn) if first
    "Error: #{text}"
  end

  # Start a server that exited again, for a call: at most MAX_RESTARTS
  # times a session. A start that fails or is cancelled leaves it exited
  # (the next call tries again, while restarts are left).
  # @return [Client, String] the client, or the call's error text
  def restart(server, ctx)
    @restart.synchronize do
      server.service.value # raises once stopped
      return server.client if server.state == :running # another call restarted it

      if server.restarts >= MAX_RESTARTS
        return "Error: MCP server #{server.name} is not running (#{server.error}; restarted #{MAX_RESTARTS} times this session)"
      end

      server.restarts += 1
      server.client&.close
      begin
        client = spawn(server, ctx)
      rescue StandardError => e
        server.client&.close
        ctx.log.warn("mcp_server_not_restarted", server: server.name, error: e.class.name, msg: e.message)
        return "Error: MCP server #{server.name} didn't restart: #{e.message}"
      end
      server.state = :running
      publish
      ctx.log.info("mcp_server_restarted", server: server.name, pid: client.pid, restarts: server.restarts)
      client
    end
  end

  # The process ended while chi runs: one notice; its next call starts it
  # again (#restart) while restarts are left.
  def exited(server, reason, ctx)
    return unless server.state == :running

    server.state = :exited
    server.error = reason
    publish
    ctx.log.warn("mcp_server_exited", server: server.name, msg: reason, restarts: server.restarts)
    after = if server.restarts < MAX_RESTARTS
              "it restarts on its next call"
            else
              "it was restarted #{MAX_RESTARTS} times, its tools fail until chi restarts"
            end
    ctx.notify("MCP server #{server.name} stopped: #{reason}; #{after}", level: :warn)
  end

  def positive(value)
    number = Float(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
