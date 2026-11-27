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
#       client_metadata_url: https://…/client.json  # default: chi's own client document (CIMD); false: none
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
# oauth.rb (sign-in: OAuth::Login, OAuth::Token), sign_in.rb (the sign-in
# wiring: /mcp login|logout and a 401's sign-in card), server_config.rb (a
# server's config: command/env/cwd or url/headers and digest, and why a
# config is refused), tools.rb (the tools/list cache and the tool index) and
# content.rb (a tools/call answer's text and images).
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
  # Read by the bundle's specs (the test kit's bundle.plugin, McpPluginOf); chi itself never calls them.
  attr_reader :servers, :ctx

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
  # takes one), pages/oauth/client.json in chi's repository as GitHub Pages
  # serves it, at the owner's custom domain (github.io redirects there, and
  # a client_id must equal the fetched address exactly). The default:
  # bundles: mcp: client_metadata_url: sets another (your own), false none
  # (a provider that takes one gets a registration instead).
  CLIENT_METADATA_DOCUMENT = "https://dmitry.it/samagotchi/oauth/client.json"
  CLIENT_METADATA_URL = CLIENT_METADATA_DOCUMENT

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
