# frozen_string_literal: true

# The mcp bundle's first plugin part (manifest.yml plugin: parts:, loaded
# before http_client.rb and plugin.rb): the stdio JSON-RPC client and the
# error classes HttpClient's subclass. The constants it reads at run time
# (PROTOCOL_VERSION) are plugin.rb's.
require "json"
require "open3"
require "samagotchi/process_group"

class Plugin
  # A JSON-RPC client for one MCP server over stdio: newline-delimited JSON
  # on the process's stdin and stdout; stderr goes to the log.
  class Client
    # The request failed: an error answer, a timeout, or the server is gone.
    class Error < StandardError; end
    class Timeout < Error; end
    class Cancelled < Error; end
    # The server's process ended (or never started); an HTTP server that
    # can't be reached.
    class Dead < Error; end
    # An HTTP server's answer isn't MCP's (a status, a content type).
    class Unavailable < Error; end

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

    # What /mcp's running line shows for it.
    def label = "pid #{pid}"

    # initialize, then notifications/initialized.
    # @return [Hash] initialize's result
    def handshake(timeout:, cancelled:)
      result = request("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {},
                                       clientInfo: { name: "chi", version: Samagotchi::VERSION } },
                       timeout: timeout, cancelled: cancelled)
      notify("notifications/initialized")
      result
    end

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
end
