# frozen_string_literal: true

require "socket"

module Samagotchi
  class BridgeClient
    # The GET that opens an event stream, written by hand over a TCPSocket,
    # and its response headers read up to the body: BridgeClient's stream
    # (the worker's Bridge, `/session/:id/stream`), and any other server that
    # serves the same SSE body at its own path with its own extra headers.
    # TLS would plug in here.
    module StreamRequest
      # A reply's status line; its code is group 1 (BridgeClient::STATUS_LINE).
      STATUS_LINE = %r{\AHTTP/1\.[01] (\d{3})}
      # The connect's bound when no +timeout+ is given (HTTPTransport's
      # OPEN_TIMEOUT): a dead host (no SYN answer) is given up on, so a
      # reconnect loop (RemoteLink's minute of tries) isn't held by the
      # OS's minutes-long SYN timeout on each.
      CONNECT_TIMEOUT = 5.0

      module_function

      # Open the stream and read past the response headers.
      # @param host [String] a name or an address, an IPv6 one bare (::1)
      # @param port [Integer]
      # @param path [String] the request path with its query
      # @param last_event_id [String, nil] the reconnect cursor
      # @param headers [Hash{String => String}] extra request headers, after
      #   Last-Event-ID
      # @param timeout [Float, nil] give up when the connect (CONNECT_TIMEOUT
      #   when nil), then the headers, aren't done by then
      # @return [Array(TCPSocket, Integer, Hash), nil] the socket positioned
      #   at the body, the HTTP status and the response headers (names in
      #   lower case), or nil when the server can't be reached
      def open(host:, port:, path:, last_event_id: nil, headers: {}, timeout: nil)
        sock = TCPSocket.new(host, port, connect_timeout: timeout || CONNECT_TIMEOUT)
        sock.write(request(host: host, port: port, path: path, last_event_id: last_event_id, headers: headers))
        deadline = timeout && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout)
        status = header_line(sock, deadline).to_s[STATUS_LINE, 1].to_i
        received = {}
        while (line = header_line(sock, deadline))
          break if line.strip.empty?

          name, value = line.split(":", 2)
          received[name.strip.downcase] = value.to_s.strip if value
        end
        [sock, status, received]
      rescue SystemCallError, SocketError, IOError
        sock&.close rescue nil
        nil
      end

      # The request's bytes.
      # @return [String]
      def request(host:, port:, path:, last_event_id: nil, headers: {})
        lei = last_event_id.to_s.strip
        last_event_line = lei.empty? ? "" : "Last-Event-ID: #{lei}\r\n"
        extra = headers.map { |name, value| "#{name}: #{value}\r\n" }.join
        host = "[#{host}]" if host.include?(":") && !host.start_with?("[")
        "GET #{path} HTTP/1.1\r\nHost: #{host}:#{port}\r\nAccept: text/event-stream\r\n#{last_event_line}#{extra}" \
          "Connection: keep-alive\r\n\r\n"
      end

      # One line of the response headers, or nil at EOF; raises
      # Errno::ETIMEDOUT once +deadline+ (monotonic, nil: none) has passed. A
      # line read in pieces, so a server that stops mid-line can't hold it.
      def header_line(sock, deadline)
        return sock.gets unless deadline

        line = +""
        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Errno::ETIMEDOUT unless remaining.positive? && sock.wait_readable(remaining)

          char = sock.getc
          return line.empty? ? nil : line if char.nil?

          line << char
          return line if char == "\n"
        end
      end
    end
  end
end
