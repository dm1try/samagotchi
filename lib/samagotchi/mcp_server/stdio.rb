# frozen_string_literal: true

require "json"
require_relative "protocol"

module Samagotchi
  module McpServer
    # MCP over stdio: one JSON-RPC message per line on +input+, each answer
    # one line on +output+. The first request locks the connection's era
    # (server/discover modern, initialize legacy), as the official SDK
    # does. A tools/call runs on its own thread (a 25 s slice must not
    # block a tools/list); every write goes through one mutex and is
    # flushed. EOF on +input+: running calls finish (each bounded by its
    # slice), then #run returns. Nothing else may write to +output+.
    class Stdio
      # @param protocol [Protocol]
      # @param before_call [#call, nil] run once, before the first
      #   tools/call's thread starts (a load two threads must not race)
      # @param log [#call, nil] (line) a diagnostic for stderr
      def initialize(protocol, input: $stdin, output: $stdout, before_call: nil, log: nil)
        @protocol = protocol
        @input = input
        @output = output
        @before_call = before_call
        @log = log
        @write_lock = Mutex.new
        @calls = []
        @era = nil
        @closed = false
      end

      # @return [Integer] 0
      def run
        @input.each_line do |line|
          # Bytes: a line that isn't valid UTF-8 is a -32700, never a raise.
          next if line.b.strip.empty?

          dispatch(line)
        end
        @calls.each(&:join)
        0
      end

      private

      def dispatch(line)
        message = Protocol.parse(line)
      rescue Protocol::Unparseable
        write(@protocol.handle_text(line, era: @era))
      else
        lock_era(message)
        if message.is_a?(Hash) && message["method"] == "tools/call" && message.key?("id")
          prepare
          @calls << Thread.new { write(@protocol.handle(message, era: @era)) }
        else
          write(@protocol.handle(message, era: @era))
        end
      end

      def lock_era(message)
        return if @era || !message.is_a?(Hash) || !message.key?("id") || !message["method"].is_a?(String)

        @era = Protocol.era_of(message)
        @log&.call("mcp: #{@era} era (#{message["method"]})")
      end

      def prepare
        return unless @before_call

        @before_call.call
        @before_call = nil
      end

      def write(answer)
        return unless answer

        @write_lock.synchronize do
          return if @closed

          @output.write("#{JSON.generate(answer.body)}\n")
          @output.flush
        rescue Errno::EPIPE, IOError
          # The host left: later answers go nowhere.
          @closed = true
          @log&.call("mcp: the host closed its end; answers dropped")
        end
      end
    end
  end
end
