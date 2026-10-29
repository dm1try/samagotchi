# frozen_string_literal: true

# The mcp bundle (docs/plugins.md, The mcp bundle): tools from MCP servers.
# Each server in config.yml runs as a child process (stdio only in v1) for
# the session's life. Its tools aren't declared one by one: the bundle
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
require "digest"
require "json"
require "open3"
require "samagotchi/process_group"
require "samagotchi/token_usage"
require "samagotchi/tools/tool_index"
require "samagotchi/tool_declarations"
require "time"
require "shellwords"
require "tmpdir"

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
  IMAGE_EXT = { "image/png" => "png", "image/jpeg" => "jpg", "image/gif" => "gif", "image/webp" => "webp" }.freeze

  # A JSON-RPC client for one MCP server over stdio: newline-delimited JSON
  # on the process's stdin and stdout; stderr goes to the log.
  class Client
    # The request failed: an error answer, a timeout, or the server is gone.
    class Error < StandardError; end
    class Timeout < Error; end
    class Cancelled < Error; end
    # The server's process ended (or never started).
    class Dead < Error; end

    POLL_SECONDS = 0.1
    # How long close waits for the server after closing its stdin, after
    # TERM, and after KILL.
    STOP_GRACE_SECONDS = 1
    # The server's watchdog (#start_watchdog), a shell in its process group
    # whose stdin is a pipe only chi holds. A line on it (#close) lets it
    # go; EOF means chi ended without closing the server (kill -9, a crash
    # past Ruby), whose stdin then hit EOF too: a grace for the server to
    # leave by itself, then TERM and KILL to the group, the way #close stops
    # it. `kill 0` signals the shell's own group: while it runs, that group
    # (and so its id) can't be anyone else's.
    WATCHDOG = "trap '' TERM; read -r _ && exit 0; sleep #{STOP_GRACE_SECONDS}; " \
               "kill -TERM 0; sleep #{STOP_GRACE_SECONDS}; kill -KILL 0".freeze

    attr_reader :pid

    # @param command [Array<String>]
    # @param env [Hash] added to the environment
    # @param cwd [String]
    # @param log [#call] (event, fields) for stderr lines and protocol noise
    # @param on_exit [#call, nil] called once, with the reason, when the
    #   process ends while the client is open
    # @param on_notification [#call, nil] (method, params) for each
    #   notification from the server, on the reader thread: it must not
    #   wait for an answer there
    def initialize(command, env: {}, cwd: Dir.pwd, log: ->(*) {}, on_exit: nil, on_notification: nil)
      @log = log
      @on_exit = on_exit
      @on_notification = on_notification
      @mutex = Mutex.new
      @write_mutex = Mutex.new
      @pending = {}
      @next_id = 0
      @dead = nil
      @closing = false
      @stdin, @stdout, @stderr, @wait = Open3.popen3(env.to_h { |k, v| [k.to_s, v&.to_s] }, *command,
                                                     chdir: cwd, pgroup: true)
      @pid = @wait.pid
      start_watchdog
      @reader = Thread.new { read_loop }
      @err_reader = Thread.new { stderr_loop }
    rescue SystemCallError => e
      raise Dead, "can't start #{command.first}: #{e.message.sub(/ - .*\z/m, "")}"
    end

    # @return [String, nil] why the server is gone, or nil while it runs
    def dead = @mutex.synchronize { @dead }

    # Send a request and wait for its answer.
    # @param cancelled [#call, nil] polled while waiting; true sends
    #   notifications/cancelled and raises Cancelled
    # @return [Hash] the result
    def request(method, params = nil, timeout:, cancelled: nil)
      queue = Queue.new
      id = @mutex.synchronize do
        raise Dead, @dead if @dead

        @next_id += 1
        @pending[@next_id] = queue
        @next_id
      end
      write({ jsonrpc: "2.0", id: id, method: method, params: params }.compact)
      deadline = monotonic + timeout
      loop do
        left = deadline - monotonic
        if left <= 0
          cancel(id, "timed out")
          raise Timeout, "#{method} timed out after #{format("%g", timeout)}s"
        end
        if cancelled&.call
          cancel(id, "cancelled by the user")
          raise Cancelled, "#{method} was cancelled"
        end
        message = queue.pop(timeout: [left, POLL_SECONDS].min)
        next unless message
        raise Dead, message[:dead] if message[:dead]
        if (error = message["error"])
          raise Error, "#{error["message"] || "error"} (#{error["code"]})"
        end

        return message["result"] || {}
      end
    ensure
      @mutex.synchronize { @pending.delete(id) } if id
    end

    def notify(method, params = nil)
      write({ jsonrpc: "2.0", method: method, params: params }.compact)
    end

    # End the process: stdin closed first (most servers leave then), then
    # TERM and KILL to its process group (chi's ProcessGroup), a second's
    # grace each. Then the watchdog is let go.
    def close
      @mutex.synchronize { @closing = true }
      [@stdin].each { |io| io.close unless io.closed? }
      unless @wait.join(STOP_GRACE_SECONDS)
        Samagotchi::ProcessGroup.stop(@pid, grace: STOP_GRACE_SECONDS, poll: STOP_GRACE_SECONDS,
                                            stopped: -> { !@wait.alive? }, wait: ->(seconds) { @wait.join(seconds) })
        @wait.join(STOP_GRACE_SECONDS)
      end
      release_watchdog
      [@stdout, @stderr].each { |io| io.close unless io.closed? }
      [@reader, @err_reader].each { |t| t.join(1) }
      nil
    rescue IOError
      nil
    end

    private

    # A server outlives a chi killed without #close when it ignores its
    # stdin's EOF (a Node server with another live handle does): the
    # watchdog (WATCHDOG) stops its group then. One that can't start (the
    # server already left its group) is logged and skipped.
    def start_watchdog
      reader, @watchdog_pipe = IO.pipe
      watchdog = Process.spawn("/bin/sh", "-c", WATCHDOG, in: reader, out: File::NULL, err: File::NULL, pgroup: @pid)
      @watchdog = Process.detach(watchdog)
    rescue SystemCallError => e
      @log.call("watchdog_failed", error: e.class.name)
      @watchdog_pipe&.close
      @watchdog_pipe = nil
    ensure
      reader&.close
    end

    # A line tells the watchdog chi stopped the server itself.
    def release_watchdog
      return unless @watchdog_pipe

      begin
        @watchdog_pipe.write("\n")
      rescue IOError, SystemCallError # gone already: the group's KILL reached it
        nil
      end
      @watchdog_pipe.close unless @watchdog_pipe.closed?
      @watchdog&.join(STOP_GRACE_SECONDS)
    end

    def write(message)
      line = JSON.generate(message)
      @write_mutex.synchronize do
        @stdin.write(line, "\n")
        @stdin.flush
      end
    rescue IOError, SystemCallError => e
      raise Dead, dead || "the server's stdin is closed (#{e.class})"
    end

    def cancel(id, reason)
      notify("notifications/cancelled", { requestId: id, reason: reason })
    rescue Dead
      nil
    end

    def read_loop
      @stdout.each_line do |line|
        next if line.strip.empty?

        message = begin
          JSON.parse(line)
        rescue JSON::ParserError
          @log.call("bad_line", line: line[0, 200])
          next
        end
        dispatch(message) if message.is_a?(Hash)
      end
    rescue IOError
      nil
    ensure
      ended
    end

    def dispatch(message)
      if message.key?("method")
        # A request from the server (ping, roots/list, …): ping is answered,
        # the rest aren't supported. A notification is logged and handed on.
        unless message.key?("id")
          @log.call("server_notification", method: message["method"])
          return @on_notification&.call(message["method"], message["params"])
        end

        answer = if message["method"] == "ping"
                   { jsonrpc: "2.0", id: message["id"], result: {} }
                 else
                   { jsonrpc: "2.0", id: message["id"], error: { code: -32_601, message: "not supported by chi" } }
                 end
        begin
          write(answer)
        rescue Dead
          nil
        end
      else
        queue = @mutex.synchronize { @pending[message["id"]] }
        queue&.push(message)
      end
    end

    def stderr_loop
      @stderr.each_line { |line| @log.call("stderr", line: line.chomp[0, 500]) }
    rescue IOError
      nil
    end

    def ended
      status = @wait.value
      reason = if status.nil?
                 "the server exited"
               else
                 "the server exited (#{status.exitstatus ? "status #{status.exitstatus}" : "signal #{status.termsig}"})"
               end
      waiting, closing = @mutex.synchronize do
        @dead ||= reason
        [@pending.values, @closing]
      end
      waiting.each { |queue| queue.push({ dead: reason }) }
      @on_exit&.call(reason) unless closing
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

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
  Server = Struct.new(:name, :config, :service, :state, :error, :tools, :listed, :timeout, :cwd, :command, :env,
                      :digest, :cached_at, :relist, :relisting, :client, :restarts, :tokens, :info, keyword_init: true) do
    # Its state and tools, never the env (values often a token) or the
    # command's args (which may carry a token too): a failing spec or a
    # debugger would print those. `command` and `env` are nil before the
    # server is resolved.
    def inspect = "#<Server #{name} state=#{state} command=#{Array(command).first} env=#{(env || {}).keys.join(",")} tools=#{Array(tools).size}>"

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
      server.service = chi.service(name) { |svc| start(server, svc, ctx) }
      server
    end
    # Two startup_timeouts: initialize, then tools/list.
    wait = @startup_timeout * 2
    @servers.each do |server|
      # A failure's card title, short: the card shows "mcp" beside it and
      # the error in its body.
      failed = "#{server.name} didn't start"
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
    chi.command "/mcp", "list the MCP servers, their state and their tools", anytime: true do |_args, command_ctx|
      command_ctx.card(title: "MCP servers", body: listing, id: "mcp-servers")
      nil
    end
  end

  private

  # The command, env and cwd the server runs with, and their digest (the
  # cache's key: command, args, env names and values, and the cwd; the
  # env itself is never stored).
  def resolve(server, ctx)
    command = server.config["command"]
    command = Shellwords.split(command) if command.is_a?(String)
    server.command = Array(command).map(&:to_s)
    env = server.config["env"].is_a?(Hash) ? server.config["env"] : {}
    server.env = env.to_h { |key, value| [key.to_s, value.to_s] }
    server.cwd = server.config["cwd"] ? File.expand_path(server.config["cwd"].to_s) : ctx.cwd
    server.digest = Digest::SHA256.hexdigest(JSON.generate([server.command, server.env.sort, server.cwd]))
  end

  # The service's start: spawn (#spawn). Its stop closes the server's
  # current process, a restarted one too.
  def start(server, svc, ctx)
    raise Client::Error, "no command (bundles: mcp: servers: #{server.name}: command: [...])" if server.command.empty?

    svc.on_stop { server.client&.close }
    spawn(server, ctx)
  end

  # Spawn the server's process (it is server.client from then on),
  # initialize, list the tools (cancelled with the turn that waits for
  # it), then cache the list and its info when either changed, and index
  # the tools.
  # @return [Client]
  def spawn(server, ctx)
    cancelled = -> { ctx.cancelled? }
    client = server.client = Client.new(
      server.command, env: server_env(server), cwd: server.cwd,
                      log: ->(event, **fields) { ctx.log.debug("mcp_#{event}", server: server.name, **fields) },
                      on_exit: ->(reason) { exited(server, reason, ctx) },
                      on_notification: lambda { |method, _params|
                        tools_changed(server, ctx) if method == "notifications/tools/list_changed"
                      }
    )
    initialized = client.request("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {},
                                                 clientInfo: { name: "chi", version: Samagotchi::VERSION } },
                                 timeout: @startup_timeout, cancelled: cancelled)
    client.notify("notifications/initialized")
    listed = list_tools(client, cancelled)
    info = info_of(initialized)
    changed = listed != server.listed || info != server.info
    server.listed = listed
    server.info = info
    save_cache(server, ctx) if changed
    index(server, ctx)
    client
  end

  # A server's env: the session's project env (the worker's mise env, on a
  # chi that has it: Samagotchi::ProjectEnv) under the server's own keys.
  def server_env(server)
    project = defined?(Samagotchi::ProjectEnv) ? Samagotchi::ProjectEnv.current.env : {}
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
  #   the index keeps its tools, marked failed)
  def boot(server, ctx)
    client = server.service.value
    server.state = :running
    publish
    ctx.log.info("mcp_server_started", server: server.name, pid: client.pid, tools: server.listed.size)
    count = server.listed.size
    "#{server.name} ready, #{count} tool#{"s" unless count == 1}"
  rescue StandardError => e
    server.state = :failed
    server.error = e.message
    publish
    ctx.log.warn("mcp_server_failed", server: server.name, error: e.class.name, msg: e.message)
    raise Client::Error, "MCP server #{server.name} didn't start: #{e.message}; its calls fail until chi restarts"
  end

  # The quiet daily refresh of a cached server's list: a server of its own
  # (not the session's: that one still starts on the first call), listed
  # and stopped. The cache is rewritten (its clock too) and a changed list
  # replaces the indexed tools. One worker at a time (a lock file); the
  # others skip.
  def refresh(server, ctx)
    File.open("#{cache_path(server, ctx)}.lock", File::CREAT | File::RDWR) do |lock|
      return nil unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      cancelled = -> { ctx.cancelled? }
      client = Client.new(server.command, env: server_env(server), cwd: server.cwd,
                                          log: ->(event, **fields) { ctx.log.debug("mcp_#{event}", server: server.name, **fields) })
      begin
        initialized = client.request("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {},
                                                     clientInfo: { name: "chi", version: Samagotchi::VERSION } },
                                     timeout: @startup_timeout, cancelled: cancelled)
        client.notify("notifications/initialized")
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

  # ── The tools/list cache ──────────────────────────────────────────────

  # Where the server's cache is: tools-<server>.json, the name sanitized.
  def cache_path(server, ctx)
    File.join(ctx.data_dir, "tools-#{server.name.gsub(/[^A-Za-z0-9_.-]+/, "_")}.json")
  end

  # Take the server's tools from its cache: true when it holds this
  # config's list (the server is then :cached, not started).
  def load_cache(server, ctx)
    data = JSON.parse(File.read(cache_path(server, ctx)))
    return false unless data.is_a?(Hash) && data["digest"] == server.digest && data["tools"].is_a?(Array)

    server.listed = data["tools"].select { |tool| tool.is_a?(Hash) && tool["name"] }
    server.info = data["info"].is_a?(String) ? data["info"] : nil
    server.cached_at = begin
      Time.iso8601(data["saved_at"].to_s)
    rescue ArgumentError
      nil
    end
    server.state = :cached
    true
  rescue SystemCallError, JSON::ParserError
    false
  end

  # Written aside and renamed: workers share the dir.
  def save_cache(server, ctx)
    Samagotchi::AtomicFile.write(cache_path(server, ctx),
                                 JSON.generate({ digest: server.digest, saved_at: Time.now.utc.iso8601, info: server.info,
                                                 tools: server.listed }.compact))
  rescue SystemCallError => e
    ctx.log.warn("mcp_cache_not_written", server: server.name, msg: e.message)
  end

  # ── Tools ─────────────────────────────────────────────────────────────

  # Index the server's tools, the tools: filter applied: each named, its
  # schema checked (a bad one is kept, marked, and said once). The whole
  # list is built, then swapped in: a search on another thread never sees
  # half a list. Their estimated tokens go to the log when they changed.
  def index(server, ctx)
    wanted = server.config["tools"] && Array(server.config["tools"]).map(&:to_s)
    listed = server.listed || []
    listed = listed.select { |tool| wanted.any? { |w| File.fnmatch(w, tool["name"], File::FNM_EXTGLOB) } } if wanted
    tokens = 0
    tools = listed.map do |listed_tool|
      tool = McpTool.new(server: server.name, name: listed_tool["name"].to_s,
                         chi_name: tool_name(server.name, listed_tool["name"]), description: description(listed_tool),
                         schema: listed_tool["inputSchema"] || { "type" => "object", "properties" => {} }, error: nil)
      tokens += definition_tokens(tool.chi_name, tool.description, tool.schema)
      tool
    rescue StandardError => e # a schema chat_schemas can't read raises more than ArgumentError
      error = e.message.sub(/\Atool \S+: /, "")
      left_out("MCP tool #{server.name}/#{tool.name} can't be called: #{error}", ctx)
      tool.with(error: error)
    end
    server.tools = tools.freeze
    say_clashes(ctx)
    publish
    return if tokens == server.tokens

    server.tokens = tokens
    ctx.log.info("mcp_tools_estimated", server: server.name, tools: offered(server).size, tokens: tokens)
  end

  # Said once (a notice and the log), not at each index.
  def left_out(text, ctx)
    first = @left_out_lock.synchronize { @left_out.include?(text) ? false : (@left_out << text) }
    return unless first

    ctx.log.warn("mcp_tool_left_out", msg: text)
    ctx.notify(text, level: :warn)
  end

  # Tools of every server whose mcp_<server>_<tool> another tool has too
  # (two servers, git-hub and git_hub; names alike up to NAME_CHARS):
  # guardrail rules and approvals key on that name, so neither is called.
  # Said once per clash; checked after each server's index, so whichever
  # server comes second says it.
  def say_clashes(ctx)
    @servers.flat_map(&:tools).group_by(&:chi_name).each do |chi_name, same|
      next if same.size < 2

      left_out("MCP tools #{same.map { |t| "#{t.server}/#{t.name}" }.join(" and ")} can't be called: " \
               "both are #{chi_name} to guardrail rules", ctx)
    end
  end

  # The other indexed tools with +tool+'s mcp_<server>_<tool>.
  def clashes(tool)
    @servers.flat_map(&:tools).select { |t| t.chi_name == tool.chi_name && [t.server, t.name] != [tool.server, tool.name] }
  end

  # Why call_tool refuses +tool+, nil when it can call it.
  def refusal(tool)
    return tool.error if tool.error

    others = clashes(tool)
    "name clash with #{others.map { |t| "#{t.server}/#{t.name}" }.join(", ")} (#{tool.chi_name})" unless others.empty?
  end

  # The server's tools call_tool can call (no bad schema, no name clash).
  def offered(server) = server.tools.reject { |tool| refusal(tool) }

  # The marks a search and /mcp give a tool call_tool refuses.
  def mark(tool)
    return "(bad schema)" if tool.error

    others = clashes(tool)
    "(name clash with #{others.map { |t| "#{t.server}/#{t.name}" }.join(", ")})" unless others.empty?
  end

  # A tool's definition as the chat path sends it (LLM::ChatLoop#tool_definitions:
  # the chat schema, wrapped as a function), in estimated tokens
  # (TokenUsage::CHARS_PER_TOKEN). The native prompts (Gemma, Qwen) render a
  # flatter schema, so it is an upper bound there.
  # @raise [ArgumentError] a bad schema
  def definition_tokens(name, description, schema)
    Samagotchi::Tools::ToolIndex.spec_tokens(Samagotchi::Plugin::Api.tool_spec(name, description, schema: schema) { nil })
  end

  # Every server's tools into chi's index, a group each: its state (what a
  # search's notes say), its summary line, and its tools with the marks
  # and refusals of now (a clash with another server's tool too, so all of
  # them each time). After each index and each state change a note reads;
  # one at a time, so the last one published is the newest.
  def publish
    return unless @source

    @publish.synchronize do
      groups = @servers.map do |server|
        state = { starting: :starting, failed: :failed }.fetch(server.state, :ready)
        tools = Array(server.tools).map do |tool|
          Samagotchi::Tools::ToolIndex::Tool.new(group: tool.server, name: tool.name, description: tool.description,
                                                 schema: tool.schema, acts_as: tool.chi_name, refusal: refusal(tool),
                                                 mark: mark(tool))
        end
        Samagotchi::Tools::ToolIndex::Group.new(name: server.name, summary: server_summary(server), state: state,
                                                error: state == :failed ? server.error : nil, tools: tools)
      end
      @source.publish(groups)
    end
  end

  # The server's line in find_tools: its description: from config, else the first
  # sentence of its instructions, else nothing (its line has the tool
  # count). Never its tool names: a model that knows them calls them
  # blind, without a search (a smoke run's Splash did).
  def server_summary(server)
    given = server.config["description"].to_s.strip
    return given unless given.empty?

    server.info
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
    return "Error: MCP server #{server.name} didn't start: #{server.error}" if server.state == :failed

    client = case server.state
             when :cached then lazy_start(server, ctx)
             when :exited then restart(server, ctx)
             else
               server.service.value # raises once stopped
               server.client
             end
    return client if client.is_a?(String)

    result = client.request("tools/call", { name: tool.name, arguments: args }, timeout: server.timeout,
                                                                                cancelled: -> { ctx.cancelled? })
    text, images = content(result, server, tool.name)
    return "Error: #{text.empty? ? "the tool failed" : text}#{Samagotchi::Tools::ToolIndex.schema_note(tool)}" if result["isError"]

    images.empty? ? text : Samagotchi::Plugin::ToolResult.new(text, images: images)
  rescue Client::Dead => e
    "Error: MCP server #{server.name} is not running (#{e.message})"
  rescue Client::Timeout, Client::Cancelled, Samagotchi::Plugin::Service::Stopped => e
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
    publish
    ctx.log.info("mcp_server_started", server: server.name, pid: client.pid, tools: server.listed.size, lazy: true) if started
    client
  rescue Client::Cancelled => e
    "Error: #{e.message}"
  rescue Samagotchi::Plugin::Service::Stopped => e
    "Error: #{e.message}"
  rescue StandardError => e
    raise unless server.state == :cached

    server.state = :failed
    server.error = e.message
    publish
    ctx.log.warn("mcp_server_failed", server: server.name, error: e.class.name, msg: e.message, lazy: true)
    ctx.notify("MCP server #{server.name} didn't start: #{e.message}; its calls fail until chi restarts", level: :warn)
    "Error: MCP server #{server.name} didn't start: #{e.message}"
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

  # The answer's text, and the images to attach: its image blocks, and a
  # text block that is only an image's path (#image_path).
  # @return [Array(String, Array<Hash>)]
  def content(result, server, tool)
    blocks = Array(result["content"])
    return [JSON.generate(result["structuredContent"]), []] if blocks.empty? && result["structuredContent"]

    images = []
    text = blocks.map do |block|
      case block["type"]
      when "text"
        line = block["text"].to_s
        paths = image_paths(line, server).reject { |path| images.any? { |image| image[:path] == path } }
        next line if paths.empty?

        notes = paths.map do |path|
          images << { path: path, name: File.basename(path) }
          "[image #{images.size}: #{File.basename(path)}]"
        end
        [line, *notes].join("\n")
      when "image"
        mime = block["mimeType"] || "unknown type"
        bytes = block["data"].to_s.unpack1("m")
        next "[image: #{mime}, empty]" if bytes.empty?

        images << { bytes: bytes, name: "#{tool}-#{images.size + 1}.#{IMAGE_EXT.fetch(mime, "img")}" }
        "[image #{images.size}: #{mime}]"
      when "audio" then "[audio: #{block["mimeType"] || "unknown type"}]"
      when "resource"
        resource = block["resource"] || {}
        mime = resource["mimeType"].to_s
        blob = resource["blob"].to_s
        if mime.start_with?("image/") && !blob.empty?
          bytes = blob.unpack1("m")
          next "[image: #{mime}, empty]" if bytes.empty?

          images << { bytes: bytes, name: "#{tool}-#{images.size + 1}.#{IMAGE_EXT.fetch(mime, "img")}" }
          "[image #{images.size}: #{mime}]"
        else
          resource["text"] || "[resource: #{resource["uri"]}]"
        end
      when "resource_link" then "[resource link: #{block["uri"]}]"
      else "[#{block["type"] || "unknown"} content]"
      end
    end.join("\n")
    [text, images]
  end

  # An absolute path ending in an image extension, inside a sentence
  # ("Saved screenshot to /tmp/shot.png."): no spaces, quotes or brackets.
  IMAGE_PATH_IN_TEXT = %r{(?<![\w/.~-])/[^\s"'`<>()\[\]{},;]+?\.(?:png|jpe?g|gif|webp)(?![\w/-])}i

  # The images +text+ names, when the server's attach_image_paths isn't
  # off: the whole text when it is one absolute path (any name), else each
  # absolute path in it that ends in an image extension. Each must be an
  # image file (by its bytes) under the system temp dir or the server's
  # cwd: a server's text can't pull in any image on disk.
  # @return [Array<String>] real paths, each once
  def image_paths(text, server)
    return [] if server.config["attach_image_paths"] == false

    whole = text.strip
    candidates = if whole.start_with?("/") && !whole.include?("\n") && File.file?(whole)
                   [whole]
                 else
                   text.scan(IMAGE_PATH_IN_TEXT)
                 end
    candidates.filter_map { |path| image_path(path, server) }.uniq
  end

  # +path+'s real path when it is an image file under a root, else nil.
  def image_path(path, server)
    return nil unless File.file?(path)

    real = File.realpath(path)
    roots = [Dir.tmpdir, server.cwd].compact.map { |dir| File.realpath(dir) rescue nil }.compact
    return nil unless roots.any? { |root| real.start_with?(root.end_with?("/") ? root : "#{root}/") }

    image_magic?(real) ? real : nil
  rescue SystemCallError
    nil
  end

  # png, jpeg, gif or webp by the file's first bytes.
  def image_magic?(path)
    head = File.binread(path, 12).to_s.b
    head.start_with?("\x89PNG\r\n\x1a\n".b, "\xFF\xD8\xFF".b, "GIF87a", "GIF89a") ||
      (head.start_with?("RIFF") && head[8, 4] == "WEBP")
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

  def listing
    return "No servers. Add them in config.yml under `bundles: mcp: servers:` (docs/plugins.md, The mcp bundle)." if @servers.empty?

    servers = @servers.map do |server|
      marker = if @source && !@source.declared_groups.include?(server.name)
                 " (not in toolkit #{@ctx.toolkit})"
               end
      head = "**#{server.name}**: #{state_text(server)}#{marker}"
      # Sorted: a server lists its tools in its own (often grouped) order.
      tools = server.tools.sort_by(&:name).map { |t| ["- `#{t.server}/#{t.name}`", mark(t)].compact.join(" ") }
      tools.empty? ? head : "#{head}\n#{tools.join("\n")}"
    end
    [*servers, totals_text].join("\n\n")
  end

  # /mcp's last line: what every request carries, and the servers' tools'
  # tokens. When another tool took both names (chi's tool index left its
  # tools out: a load warning), that the model can't reach them.
  def totals_text
    if @source.declared_names.empty?
      return "The search and call tools aren't declared in this session (other tools have their names; see the " \
             "load warnings), so the model can't reach the tools above."
    end

    total = @servers.sum { |server| OFFERED.include?(server.state) ? server.tokens : 0 }
    "Every request carries #{@source.declared_names.join(" and ")}: ~#{thousands(@source.declared_tokens)} tokens. " \
      "The tools above, ~#{thousands(total)} tokens, reach the model only in a search's answer " \
      "(estimated: their JSON as the chat API gets it, ÷ #{format("%g", Samagotchi::TokenUsage::CHARS_PER_TOKEN)})."
  end

  def state_text(server)
    count = offered(server).size
    tools = "#{count} tool#{"s" unless count == 1}"
    case server.state
    when :cached then "cached (not started), #{tools}, #{tokens_text(server)}"
    when :running then "running (pid #{server.client.pid}), #{tools}, #{tokens_text(server)}"
    when :starting then "starting"
    when :failed then server.tools.empty? ? "failed: #{server.error}" : "failed (#{tools}): #{server.error}"
    else "stopped: #{server.error}"
    end
  rescue Samagotchi::Plugin::Service::Stopped
    "stopped"
  end

  def tokens_text(server) = "~#{thousands(server.tokens)} tokens"

  def thousands(number) = number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

  def positive(value)
    number = Float(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
