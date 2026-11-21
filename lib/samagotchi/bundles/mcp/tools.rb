# frozen_string_literal: true

# The mcp bundle's fourth plugin part (manifest.yml plugin: parts:, loaded
# before plugin.rb): a server's tools, from its tools/list cache to chi's
# tool index (Plugin#index, #publish), with what makes a tool uncallable (a
# bad schema, a name clash), and /mcp's listing of them.
require "json"
require "time"
require "samagotchi/tools/tool_index"

class Plugin
  private

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
        state = { starting: :starting, failed: :failed, needs_sign_in: :needs_user }.fetch(server.state, :ready)
        tools = Array(server.tools).map do |tool|
          Samagotchi::Tools::ToolIndex::Tool.new(group: tool.server, name: tool.name, description: tool.description,
                                                 schema: tool.schema, acts_as: tool.chi_name, refusal: refusal(tool),
                                                 mark: mark(tool))
        end
        Samagotchi::Tools::ToolIndex::Group.new(name: server.name, summary: server_summary(server), state: state,
                                                error: group_error(server, state), tools: tools)
      end
      @source.publish(groups)
    end
  end

  # What a group's note and a call that misses its tools say: a failed
  # server's error, the sign-in line of one that needs it.
  def group_error(server, state)
    case state
    when :failed then server.error
    when :needs_user then sign_in_line(server)
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

  # ── /mcp's listing ────────────────────────────────────────────────────

  def listing
    return "No servers. Add them in config.yml under `bundles: mcp: servers:` (docs/bundles.md, The mcp bundle)." if @servers.empty?

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
    when :running then "#{server.url ? "connected" : "running"} (#{server.client.label}), #{tools}, #{tokens_text(server)}"
    when :starting then "starting"
    when :failed then server.tools.empty? ? "failed: #{server.error}" : "failed (#{tools}): #{server.error}"
    when :needs_sign_in then "needs sign-in (/mcp login #{server.name})"
    else "stopped: #{server.error}"
    end
  rescue Samagotchi::Plugin::Service::Stopped
    "stopped"
  end

  def tokens_text(server) = "~#{thousands(server.tokens)} tokens"

  def thousands(number) = number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end
