# The mcp bundle (docs/plugins.md, The mcp bundle): tools from MCP servers.
# Each server in config.yml runs as a child process (stdio only in v1) for
# the session's life; its tools are the model's as mcp_<server>_<tool>.
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
#           timeout: 120        # optional: this server's per-call timeout
#           attach_image_paths: true  # default: a result that is only the path of an
#                                     # image in the temp dir or cwd attaches it
#
# Image blocks in a result go to the model as images (text: "[image 1:
# image/png, attached]"); so does a text block that is only the absolute
# path of an image file under the system temp dir or the server's cwd
# (chrome-devtools-mcp --slim answers a screenshot that way).
# A server that doesn't start, answer or list its tools is skipped with a
# notice; the rest of chi works. /mcp lists the servers and their tools.
require "digest"
require "json"
require "open3"
require "time"
require "shellwords"
require "tmpdir"

class Plugin
  PROTOCOL_VERSION = "2025-06-18"
  CALL_TIMEOUT = 60
  STARTUP_TIMEOUT = 10
  DESCRIPTION_CHARS = 1024
  PREVIEW_CHARS = 60
  NAME_CHARS = 48
  # A cached tool list older than this is refreshed in the background.
  CACHE_TTL = 24 * 60 * 60
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

    attr_reader :pid

    # @param command [Array<String>]
    # @param env [Hash] added to the environment
    # @param cwd [String]
    # @param log [#call] (event, fields) for stderr lines and protocol noise
    # @param on_exit [#call, nil] called once, with the reason, when the
    #   process ends while the client is open
    def initialize(command, env: {}, cwd: Dir.pwd, log: ->(*) {}, on_exit: nil)
      @log = log
      @on_exit = on_exit
      @mutex = Mutex.new
      @write_mutex = Mutex.new
      @pending = {}
      @next_id = 0
      @dead = nil
      @closing = false
      @stdin, @stdout, @stderr, @wait = Open3.popen3(env.to_h { |k, v| [k.to_s, v.to_s] }, *command,
                                                     chdir: cwd, pgroup: true)
      @pid = @wait.pid
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
    # TERM and KILL to its process group.
    def close
      @mutex.synchronize { @closing = true }
      [@stdin].each { |io| io.close unless io.closed? }
      unless @wait.join(1)
        signal("TERM")
        signal("KILL") unless @wait.join(1)
        @wait.join(1)
      end
      [@stdout, @stderr].each { |io| io.close unless io.closed? }
      [@reader, @err_reader].each { |t| t.join(1) }
      nil
    rescue IOError
      nil
    end

    private

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
        # the rest aren't supported. A notification is logged.
        return @log.call("server_notification", method: message["method"]) unless message.key?("id")

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
      reason = "the server exited (#{status.exitstatus ? "status #{status.exitstatus}" : "signal #{status.termsig}"})"
      waiting, closing = @mutex.synchronize do
        @dead ||= reason
        [@pending.values, @closing]
      end
      waiting.each { |queue| queue.push({ dead: reason }) }
      @on_exit&.call(reason) unless closing
    end

    def signal(name)
      Process.kill(name, -@pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # One configured server: its service, state and tools. +listed+ is its
  # tools/list as the server answers it (what the cache keeps), +tools+
  # the ones chi offers (the tools: filter applied, each with chi_name).
  Server = Struct.new(:name, :config, :service, :state, :error, :tools, :listed, :timeout, :cwd, :command, :env,
                      :digest, :cached_at, keyword_init: true)

  def initialize(settings = {})
    @settings = settings
    @timeout = positive(settings["timeout"]) || CALL_TIMEOUT
    @startup_timeout = positive(settings["startup_timeout"]) || STARTUP_TIMEOUT
    @servers = []
    @publish = Mutex.new
    # The tools left out so far (a name clash): said once, not at each
    # publish.
    @left_out = []
  end

  # Each server's tools come from its cache (tools-<server>.json in the
  # bundle's data dir, keyed by a digest of its config) when there is one:
  # the server then starts on the first call of one of its tools (start:
  # lazy, the default), and a cache older than a day is refreshed quietly
  # in the background. Without a cache (the first run, a changed config)
  # the server starts in an init task (chi.init) that every UI shows; a
  # turn sent meanwhile waits for its tools. start: eager starts it with
  # every session.
  def register(chi)
    @chi = chi
    ctx = chi.ctx
    configs = @settings["servers"]
    configs = {} unless configs.is_a?(Hash)
    @servers = configs.map do |name, config|
      server = Server.new(name: name.to_s, config: config.is_a?(Hash) ? config : {}, state: :starting, tools: [])
      server.timeout = positive(server.config["timeout"]) || @timeout
      resolve(server, ctx)
      server.service = chi.service(name) { |svc| start(server, svc, ctx) }
      server
    end
    # Two startup_timeouts: initialize, then tools/list.
    wait = @startup_timeout * 2
    @servers.each do |server|
      if load_cache(server, ctx)
        declare(chi, server, ctx)
        if server.config["start"].to_s == "eager"
          chi.init("Starting MCP server #{server.name}", timeout: wait) { boot(server, ctx) }
        elsif server.cached_at.nil? || Time.now - server.cached_at > CACHE_TTL
          chi.init("Refreshing MCP server #{server.name}'s tools", quiet: true, timeout: wait) { refresh(server, ctx) }
        end
      else
        why = File.exist?(cache_path(server, ctx)) ? "config changed" : "first run"
        chi.init("Starting MCP server #{server.name} (#{why}, saving its tools)", provides_tools: true, timeout: wait) do
          boot(server, ctx)
        end
      end
    end
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

  # The service's start: spawn, initialize, list the tools (cancelled with
  # the turn that waits for it), then cache the list.
  def start(server, svc, ctx)
    raise Client::Error, "no command (bundles: mcp: servers: #{server.name}: command: [...])" if server.command.empty?

    cancelled = -> { ctx.cancelled? }
    client = Client.new(server.command, env: server.env, cwd: server.cwd,
                                        log: ->(event, **fields) { ctx.log.debug("mcp_#{event}", server: server.name, **fields) },
                                        on_exit: ->(reason) { exited(server, reason, ctx) })
    svc.on_stop { client.close }
    client.request("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {},
                                   clientInfo: { name: "chi", version: Samagotchi::VERSION } },
                   timeout: @startup_timeout, cancelled: cancelled)
    client.notify("notifications/initialized")
    listed = list_tools(client, cancelled)
    changed = listed != server.listed
    server.listed = listed
    save_cache(server, ctx) if changed
    client
  end

  # Start a server in an init task; its tools replace the cached ones (or
  # come for the first time) when they differ.
  # @return [String] the task's summary
  # @raise [Client::Error] it didn't start (the task's warn card says why)
  def boot(server, ctx)
    before = server.listed
    client = server.service.value
    server.state = :running
    ctx.log.info("mcp_server_started", server: server.name, pid: client.pid, tools: server.listed.size)
    publish(ctx) if server.listed != before
    count = server.listed.size
    "#{server.name} ready, #{count} tool#{"s" unless count == 1}"
  rescue StandardError => e
    had_tools = server.state == :cached
    server.state = :failed
    server.error = e.message
    ctx.log.warn("mcp_server_failed", server: server.name, error: e.class.name, msg: e.message)
    publish(ctx) if had_tools
    raise Client::Error, "MCP server #{server.name} didn't start: #{e.message}; its tools are left out"
  end

  # The quiet daily refresh of a cached server's list: a server of its own
  # (not the session's: that one still starts on the first call), listed
  # and stopped. The cache is rewritten (its clock too) and a changed list
  # replaces the tools. One worker at a time (a lock file); the others skip.
  def refresh(server, ctx)
    File.open("#{cache_path(server, ctx)}.lock", File::CREAT | File::RDWR) do |lock|
      return nil unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      cancelled = -> { ctx.cancelled? }
      client = Client.new(server.command, env: server.env, cwd: server.cwd,
                                          log: ->(event, **fields) { ctx.log.debug("mcp_#{event}", server: server.name, **fields) })
      begin
        client.request("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {},
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
      save_cache(server, ctx)
      ctx.log.info("mcp_tools_refreshed", server: server.name, tools: listed.size, changed: changed)
      publish(ctx) if changed
    end
    nil
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
    path = cache_path(server, ctx)
    tmp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
    File.write(tmp, JSON.generate({ digest: server.digest, saved_at: Time.now.utc.iso8601, tools: server.listed }))
    File.rename(tmp, path)
  rescue SystemCallError => e
    ctx.log.warn("mcp_cache_not_written", server: server.name, msg: e.message)
  end

  # ── Tools ─────────────────────────────────────────────────────────────

  # Declare the server's tools on +target+ (chi at load, or the set of
  # chi.replace_tools later), the tools: filter applied.
  def declare(target, server, ctx)
    wanted = server.config["tools"] && Array(server.config["tools"]).map(&:to_s)
    tools = server.listed.map(&:dup)
    tools = tools.select { |tool| wanted.any? { |w| File.fnmatch(w, tool["name"], File::FNM_EXTGLOB) } } if wanted
    server.tools = tools
    tools.each do |tool|
      name = tool_name(server.name, tool["name"])
      target.tool(name, description(tool), schema: tool["inputSchema"] || { "type" => "object", "properties" => {} },
                                           label: "#{server.name}: #{tool["name"]}", preview: ->(args) { preview(args) }) do |args, call_ctx|
        call(server, tool["name"], args, call_ctx)
      end
      tool["chi_name"] = name
    rescue ArgumentError => e
      text = "MCP tool #{server.name}/#{tool["name"]} left out: #{e.message}"
      ctx.notify(text, level: :warn) unless @left_out.include?(text)
      @left_out << text
    end
  end

  # The servers' tools changed after load (a live list that differs from
  # the cache, a server that didn't start): the whole set again, for the
  # next turn.
  def publish(ctx)
    @publish.synchronize do
      @chi.replace_tools do |set|
        @servers.each { |server| declare(set, server, ctx) if %i[running cached].include?(server.state) }
      end
    end
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

  def preview(args)
    line = args.map { |key, value| "#{key}=#{value.is_a?(String) ? value : JSON.generate(value)}" }.join(" ")
    line = line.gsub(/\s+/, " ")
    line.length > PREVIEW_CHARS ? "#{line[0, PREVIEW_CHARS - 1]}…" : line
  end

  # A tools/call, as the model's tool result. A cached server starts
  # here, on its first call.
  def call(server, tool, args, ctx)
    return "Error: MCP server #{server.name} didn't start: #{server.error}" if server.state == :failed

    client = server.state == :cached ? lazy_start(server, ctx) : server.service.value
    return client if client.is_a?(String)

    result = client.request("tools/call", { name: tool, arguments: args }, timeout: server.timeout,
                                                                           cancelled: -> { ctx.cancelled? })
    text, images = content(result, server, tool)
    return "Error: #{text.empty? ? "the tool failed" : text}" if result["isError"]

    images.empty? ? text : Samagotchi::Plugin::ToolResult.new(text, images: images)
  rescue Client::Dead => e
    "Error: MCP server #{server.name} is not running (#{e.message})"
  rescue Client::Error, Samagotchi::Plugin::Service::Stopped => e
    "Error: #{e.message}"
  end

  # Start a cached server for a call. The live list replaces the cached
  # one for the next turn when it differs. A start that fails marks the
  # server failed (one notice; its calls answer at once, and its tools go
  # next turn); a cancelled one leaves it cached for the next call.
  # @return [Client, String] the client, or the call's error text
  def lazy_start(server, ctx)
    cached = server.listed
    client = server.service.value
    started = server.state == :cached
    server.state = :running
    if started
      ctx.log.info("mcp_server_started", server: server.name, pid: client.pid, tools: server.listed.size, lazy: true)
      publish(ctx) if server.listed != cached
    end
    client
  rescue Client::Cancelled => e
    "Error: #{e.message}"
  rescue Samagotchi::Plugin::Service::Stopped => e
    "Error: #{e.message}"
  rescue StandardError => e
    raise unless server.state == :cached

    server.state = :failed
    server.error = e.message
    ctx.log.warn("mcp_server_failed", server: server.name, error: e.class.name, msg: e.message, lazy: true)
    ctx.notify("MCP server #{server.name} didn't start: #{e.message}; its tools are left out from the next turn",
               level: :warn)
    publish(ctx)
    "Error: MCP server #{server.name} didn't start: #{e.message}"
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
        path = image_path(line, server)
        next line unless path

        images << { path: path, name: File.basename(path) }
        "#{line}\n[image #{images.size}: #{File.basename(path)}, attached]"
      when "image"
        mime = block["mimeType"] || "unknown type"
        bytes = block["data"].to_s.unpack1("m")
        next "[image: #{mime}, empty]" if bytes.empty?

        images << { bytes: bytes, name: "#{tool}-#{images.size + 1}.#{IMAGE_EXT.fetch(mime, "img")}" }
        "[image #{images.size}: #{mime}, attached]"
      when "audio" then "[audio: #{block["mimeType"] || "unknown type"}]"
      when "resource"
        resource = block["resource"] || {}
        resource["text"] || "[resource: #{resource["uri"]}]"
      when "resource_link" then "[resource link: #{block["uri"]}]"
      else "[#{block["type"] || "unknown"} content]"
      end
    end.join("\n")
    [text, images]
  end

  # The path when +text+ is only the absolute path of an image file under
  # the system temp dir or the server's cwd (a server's text can't pull
  # in any image on disk), and the server's attach_image_paths isn't off.
  def image_path(text, server)
    return nil if server.config["attach_image_paths"] == false

    path = text.strip
    return nil unless path.start_with?("/") && !path.include?("\n") && File.file?(path)

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

  # The process ended while chi runs: one notice; the calls say so.
  def exited(server, reason, ctx)
    return unless server.state == :running

    server.state = :exited
    server.error = reason
    ctx.log.warn("mcp_server_exited", server: server.name, msg: reason)
    ctx.notify("MCP server #{server.name} stopped: #{reason}; its tools fail until chi restarts", level: :warn)
  end

  def listing
    return "No servers. Add them in config.yml under `bundles: mcp: servers:` (docs/plugins.md, The mcp bundle)." if @servers.empty?

    @servers.map do |server|
      head = "**#{server.name}**: #{state_text(server)}"
      tools = server.tools.map { |tool| tool["chi_name"] }.compact
      tools.empty? ? head : "#{head}\n#{tools.map { |t| "- `#{t}`" }.join("\n")}"
    end.join("\n\n")
  end

  def state_text(server)
    case server.state
    when :cached then "cached (not started), #{server.tools.size} tool#{"s" unless server.tools.size == 1}"
    when :running
      count = server.tools.count { |tool| tool["chi_name"] }
      "running (pid #{server.service.value.pid}), #{count} tool#{"s" unless count == 1}"
    when :starting then "starting"
    else "#{server.state == :failed ? "failed" : "stopped"}: #{server.error}"
    end
  rescue Samagotchi::Plugin::Service::Stopped
    "stopped"
  end

  def positive(value)
    number = Float(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
