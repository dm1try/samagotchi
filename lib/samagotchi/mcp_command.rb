# frozen_string_literal: true

require_relative "cli/command"
require_relative "cli/exit"
require_relative "mcp_server/protocol"
require_relative "mcp_server/stdio"

module Samagotchi
  # `chi mcp serve`: chi as an MCP server on stdio, for an MCP host (Claude
  # Code, Codex) to drive this machine's sessions as tools, or another
  # machine's under `chi --remote NAME`. See docs/mcp-server.md. Nothing
  # but the protocol goes to stdout; diagnostics go to stderr.
  class McpCommand
    include CLI::Command

    SUBCOMMANDS = %w[serve].freeze

    USAGE = <<~TEXT
      Usage: chi mcp serve
        chi as an MCP server on stdio (JSON-RPC lines): an MCP host drives
        this machine's chi sessions with four tools (chi_sessions, chi_ask,
        chi_wait, chi_answer); under chi --remote NAME, that machine's.
          claude mcp add chi -- chi mcp serve
          codex: [mcp_servers.chi] command = "chi", args = ["mcp", "serve"]
        chi web serves the same at POST /api/mcp. See docs/mcp-server.md.
    TEXT

    # One load of what the tools' calls autoload (SessionManager, and what
    # a probe of their paths loaded on a first call: SessionContinue,
    # SessionInbox's delivery; about 6 ms) before the first call's thread:
    # two threads must not trigger them at once.
    LOAD_LOCK = Mutex.new

    # @param access [SessionAccess::Local, SessionAccess::Remote, nil]
    #   where the sessions are; default this machine's, in +state_dir+
    # @param env [Hash] where the agent markers are read (ENV; specs pass their own)
    def initialize(argv, access: nil, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil, env: ENV)
      @argv = argv.dup
      @env = env
      @access = access
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir
    end

    # @return [Integer] the exit status
    def run
      first = @argv.first
      if HELP_WORDS.include?(first) || (first == "serve" && @argv.drop(1).any? { |arg| HELP_WORDS.include?(arg) })
        @stdout.puts(USAGE)
        return 0
      end
      return usage_error(first ? "unknown subcommand #{first}" : "give a subcommand: serve") unless first == "serve"
      return usage_error("serve takes no arguments") unless @argv.size == 1

      serve
    end

    private

    def command_name = "chi mcp"

    def serve
      log = ->(line) { @stderr.puts(line) }
      tools = LazyTools.new { build_tools }
      protocol = McpServer::Protocol.new(tools: tools, instructions: instructions)
      McpServer::Stdio.new(protocol, input: @stdin, output: @stdout, before_call: -> { tools.load }, log: log).run
    end

    def instructions
      require_relative "mcp_server/text"
      McpServer::Text::INSTRUCTIONS
    end

    def build_tools
      require_relative "mcp_server/tools"
      access = @access || begin
        require_relative "session_access/local"
        SessionAccess::Local.new(state_dir: @state_dir)
      end
      load_for_calls unless access.remote?
      McpServer::Tools.new(access)
    end

    def load_for_calls
      LOAD_LOCK.synchronize do
        Samagotchi.const_get(:SessionManager)
        Samagotchi.const_get(:SessionContinue)
        SessionInbox.const_get(:Dispatch)
      end
    end

    # The tools, built on the first tools/list or tools/call, so answering
    # server/discover or initialize loads no session code.
    class LazyTools
      def initialize(&build)
        @build = build
        @lock = Mutex.new
      end

      def load = @lock.synchronize { @tools ||= @build.call }

      def list
        require_relative "mcp_server/tools"
        McpServer::Tools::DEFINITIONS
      end

      def call(name, arguments) = load.call(name, arguments)
    end
  end
end
