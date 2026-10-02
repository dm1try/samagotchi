# frozen_string_literal: true

# A tiny MCP server over stdio (newline-delimited JSON-RPC) for the mcp
# bundle's specs. FAKE_MCP_MODE: "hang" never answers initialize, "exit"
# leaves at once, "error" answers initialize with an error, "slow" waits
# FAKE_MCP_DELAY seconds (default 3) before answering it. FAKE_MCP_LOG,
# when set, gets each message it received, one JSON per line.
# FAKE_MCP_MODE_FILE, when set and present, holds the mode instead (the
# mcp bundle's cache is keyed by the env, a file changes without it).
# FAKE_MCP_TOOLS, when set, is a file whose lines name the tools it lists
# (read at each tools/list; the rest of TOOLS is left out). FAKE_MCP_PIDS,
# when set, gets the process's pid at start, one per line.
require "json"

$stdout.sync = true
mode = ENV.fetch("FAKE_MCP_MODE", "")
mode_file = ENV["FAKE_MCP_MODE_FILE"]
mode = File.read(mode_file).strip if mode_file && File.exist?(mode_file)
log = ENV["FAKE_MCP_LOG"]
warn "fake mcp server starting (#{mode.empty? ? "normal" : mode})"
File.open(ENV["FAKE_MCP_PIDS"], "a") { |f| f.puts(Process.pid) } if ENV["FAKE_MCP_PIDS"]
exit(3) if mode == "exit"

TOOLS = [
  { name: "echo", description: "Echo the text back.",
    inputSchema: { type: "object", properties: { text: { type: "string", description: "what to echo" } }, required: ["text"] } },
  { name: "add", description: "Add two numbers.",
    inputSchema: { type: "object", properties: { a: { type: "number" }, b: { type: "number" } }, required: %w[a b] } },
  { name: "fail", description: "Always fails.", inputSchema: { type: "object", properties: {} } },
  { name: "mixed", description: "Text, an image and a resource.", inputSchema: { type: "object", properties: {} } },
  { name: "slow", description: "Takes 30 s.", inputSchema: { type: "object", properties: {} } },
  { name: "crash", description: "Exits mid-call.", inputSchema: { type: "object", properties: {} } },
  { name: "Weird-Name.v2", description: "A name that needs sanitizing.", inputSchema: { type: "object", properties: {} } },
  { name: "changed", description: "Sends notifications/tools/list_changed, then answers.",
    inputSchema: { type: "object", properties: {} } },
  { name: "path", description: "Answers the path it is given (like chrome-devtools-mcp --slim's screenshot).",
    inputSchema: { type: "object", properties: { path: { type: "string" } } } }
].freeze

# spec/fixtures/images/tiny.png (3×2).
TINY_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACAQMAAACnuvRZAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURf8AAP///0EdNBEAAAABYktHRAH/Ai3eAAAAB3RJTUUH6gkXExgsFXZ2gAAAAAxJREFUCNdjYGBgAAAABAABJzQnCgAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wOS0yM1QxOToyNDo0NCswMDowMGbCXVYAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDktMjNUMTk6MjQ6NDQrMDA6MDAXn+XqAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTA5LTIzVDE5OjI0OjQ0KzAwOjAwQIrENQAAAABJRU5ErkJggg=="

def reply(id, result = nil, error: nil)
  message = { jsonrpc: "2.0", id: id }
  error ? message[:error] = error : message[:result] = result
  $stdout.puts(JSON.generate(message))
end

def text(value) = { content: [{ type: "text", text: value }] }

$stdin.each_line do |line|
  message = JSON.parse(line)
  File.open(log, "a") { |f| f.puts(line) } if log
  id = message["id"]
  case message["method"]
  when "initialize"
    next if mode == "hang"

    sleep(Float(ENV.fetch("FAKE_MCP_DELAY", "3"))) if mode == "slow"
    next reply(id, error: { code: -32_000, message: "not today" }) if mode == "error"

    # A request of its own first: the client must answer it and go on.
    $stdout.puts(JSON.generate(jsonrpc: "2.0", id: "srv-1", method: "ping"))
    reply(id, { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "fake", version: "1" } })
  when "tools/list"
    tools = TOOLS
    if (file = ENV["FAKE_MCP_TOOLS"])
      names = File.readlines(file, chomp: true)
      tools = TOOLS.select { |tool| names.include?(tool[:name]) }
    end
    # Two pages.
    if message.dig("params", "cursor")
      reply(id, { tools: tools.drop(4) })
    else
      reply(id, { tools: tools.take(4), nextCursor: "page2" })
    end
  when "tools/call"
    args = message.dig("params", "arguments") || {}
    case message.dig("params", "name")
    when "echo" then reply(id, text("echo: #{args["text"]}"))
    when "add" then reply(id, text((args["a"] + args["b"]).to_s))
    when "fail" then reply(id, { content: [{ type: "text", text: "it broke" }], isError: true })
    when "mixed"
      reply(id, { content: [{ type: "text", text: "first" }, { type: "image", data: TINY_PNG, mimeType: "image/png" },
                            { type: "resource", resource: { uri: "file:///x.txt", text: "inline" } },
                            { type: "resource_link", uri: "file:///y.txt", name: "y" }, { type: "text", text: "last" }] })
    when "slow" then Thread.new { sleep(30) } # never answers in time
    when "crash" then exit(4)
    when "changed"
      $stdout.puts(JSON.generate(jsonrpc: "2.0", method: "notifications/tools/list_changed"))
      reply(id, text("changed"))
    when "path" then reply(id, text(args["path"]))
    else reply(id, error: { code: -32_602, message: "unknown tool" })
    end
  end
end
